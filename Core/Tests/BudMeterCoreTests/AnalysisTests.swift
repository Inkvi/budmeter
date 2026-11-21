import Foundation
import Testing
@testable import BudMeterCore

/// Simulates a headset: true charge drains continuously, reported value is quantized to `step`.
struct Simulator {
    var time = Date(timeIntervalSince1970: 1_750_000_000)
    var level = 100.0
    var step = 1
    var samples: [Sample] = []
    let address = "aa-bb"

    var reported: Int { max(1, Int((level / Double(step)).rounded(.up)) * step) }

    mutating func run(hours: Double, ratePerHour: Double, state: UsageState, every minutes: Double = 2) {
        let n = Int(hours * 60 / minutes)
        for _ in 0..<n {
            samples.append(Sample(time: time, address: address, main: reported, state: state))
            time += minutes * 60
            level = max(level - ratePerHour * minutes / 60, 1)
        }
    }

    mutating func charge(hours: Double, ratePerHour: Double = 60) {
        let n = Int(hours * 30)
        for _ in 0..<n {
            samples.append(Sample(time: time, address: address, main: reported, state: .idle))
            time += 120
            level = min(level + ratePerHour / 30, 100)
        }
    }

    mutating func disconnect(hours: Double) { time += hours * 3600 }
}

@Test func constantListeningWithCoarseSteps() {
    var sim = Simulator()
    sim.step = 10
    sim.run(hours: 4, ratePerHour: 20, state: .listening)
    let d = Analysis.drain(Analysis.intervals(sim.samples, channel: .main))
    let rate = try! #require(d[.listening]?.ratePerHour)
    #expect(abs(rate - 20) < 1.5)
}

@Test func separatesListeningFromIdle() {
    var sim = Simulator()
    sim.run(hours: 2, ratePerHour: 20, state: .listening)
    sim.run(hours: 6, ratePerHour: 3, state: .idle)
    sim.run(hours: 1, ratePerHour: 30, state: .call)
    let d = Analysis.drain(Analysis.intervals(sim.samples, channel: .main))
    #expect(abs(d[.listening]!.ratePerHour! - 20) < 1.5)
    #expect(abs(d[.idle]!.ratePerHour! - 3) < 0.5)
    #expect(abs(d[.call]!.ratePerHour! - 30) < 3)
}

@Test func chargingAndDisconnectsAreExcluded() {
    var sim = Simulator()
    sim.step = 10
    sim.run(hours: 2, ratePerHour: 20, state: .listening)
    sim.charge(hours: 0.5)            // in the case, still connected
    sim.run(hours: 2, ratePerHour: 20, state: .listening)
    sim.disconnect(hours: 3)           // used on the phone: big drop we must not count
    sim.level -= 40
    sim.run(hours: 2, ratePerHour: 20, state: .listening)
    let d = Analysis.drain(Analysis.intervals(sim.samples, channel: .main))
    #expect(d[.idle] == nil)
    #expect(abs(d[.listening]!.ratePerHour! - 20) < 2)
}

@Test func connectedHoursIgnoresGaps() {
    var sim = Simulator()
    sim.run(hours: 1, ratePerHour: 10, state: .idle)
    sim.disconnect(hours: 5)
    sim.run(hours: 1, ratePerHour: 10, state: .listening)
    let h = Analysis.connectedHours(sim.samples)
    #expect(abs(h[.idle]! - 1) < 0.1)
    #expect(abs(h[.listening]! - 1) < 0.1)
}

private func device(_ name: String = "Galaxy Buds2 Pro") -> Device {
    Device(address: "aa-bb", name: name, firstSeen: .distantPast, lastSeen: .distantPast)
}

@Test func healthVerdicts() {
    // Rated 5h. Draining 22%/h -> 4.5h -> 90% health.
    var sim = Simulator()
    sim.run(hours: 3.5, ratePerHour: 22, state: .listening)
    let good = DeviceReport.build(device: device(), samples: sim.samples, now: sim.time)
    #expect(good.verdict == .good)
    #expect(abs(good.drain[.listening]!.fullChargeHours! - 4.55) < 0.2)
    #expect(good.isConnected)
    #expect(good.remainingHours != nil)

    var worse = Simulator()
    worse.run(hours: 2.5, ratePerHour: 40, state: .listening)
    let r = DeviceReport.build(device: device(), samples: worse.samples, now: worse.time)
    #expect(r.verdict == .replace)   // 2.5h of 5h = 50%

    let unknown = DeviceReport.build(device: device("Some Headset"), samples: sim.samples, now: sim.time)
    #expect(unknown.verdict == .unknownRating)

    let empty = DeviceReport.build(device: device(), samples: [], now: sim.time)
    if case .collecting = empty.verdict {} else { Issue.record("expected collecting") }
}

@Test func idleShareAndCycles() {
    var sim = Simulator()
    sim.run(hours: 2, ratePerHour: 20, state: .listening)   // ~40 points
    sim.run(hours: 10, ratePerHour: 4, state: .idle)         // ~40 points
    let r = DeviceReport.build(device: device(), samples: sim.samples, now: sim.time)
    #expect(abs(r.idleShareOfDrain! - 0.5) < 0.08)
    #expect(abs(r.trackedCycles - 0.8) < 0.05)
}

@Test func leftRightImbalance() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    var l = 100.0, r = 100.0
    for _ in 0..<90 {
        samples.append(Sample(time: t, address: "x", left: Int(l.rounded(.up)), right: Int(r.rounded(.up)), state: .listening))
        t += 120; l -= 20.0 / 30; r -= 25.0 / 30
    }
    let rep = DeviceReport.build(device: device("AirPods Pro"), samples: samples, now: t)
    #expect(rep.channels == [.left, .right])
    #expect(abs(rep.rightVsLeft! - 0.25) < 0.05)
    // Headline uses the right bud, which dies first.
    #expect(abs(rep.drain[.listening]!.ratePerHour! - 25) < 1.5)
}

@Test func degradationTrend() {
    var sim = Simulator()
    // Six weeks, battery getting worse each week: 20%/h -> 30%/h.
    for week in 0..<6 {
        sim.level = 100
        sim.run(hours: 2, ratePerHour: 20 + Double(week) * 2, state: .listening)
        sim.disconnect(hours: 24 * 7 - 2)
    }
    let r = DeviceReport.build(device: device(), samples: sim.samples, now: sim.time)
    #expect(r.trend.filter { $0.listeningHours != nil }.count >= 5)
    #expect(r.listeningMinutesPerMonth! < -20)
}

@Test func storeRoundTrip() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    try store.upsertDevice(address: "aa", name: "Galaxy Buds2 Pro", productID: nil, seen: now)
    try store.upsertDevice(address: "aa", name: "Renamed", productID: 5, seen: now + 60)
    try store.setRatedHours(address: "aa", hours: 7)
    let s = Sample(time: now, address: "aa", main: 80, left: nil, right: nil, caseLevel: 50, state: .call)
    try store.insert(s)
    let devices = try store.devices()
    #expect(devices.count == 1)
    #expect(devices[0].name == "Renamed")
    #expect(devices[0].ratedHours == 7)
    #expect(devices[0].firstSeen == now)
    #expect(try store.samples(address: "aa") == [s])
}

@Test func idleSplitByWearing() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    var level = 100.0
    for (wearing, rate) in [(true, 6.0), (false, 2.0)] {
        for _ in 0..<(6 * 30) {
            samples.append(Sample(time: t, address: "x", left: Int(level.rounded(.up)), right: Int(level.rounded(.up)),
                                  state: .idle, wearing: wearing))
            t += 120
            level -= rate / 30
        }
    }
    let r = DeviceReport.build(device: device("Galaxy Buds3 Pro"), samples: samples, now: t)
    #expect(abs(r.idleWorn!.ratePerHour! - 6) < 0.5)
    #expect(abs(r.idleNotWorn!.ratePerHour! - 2) < 0.5)
}

@Test func storeKeepsWearing() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let s = Sample(time: Date(timeIntervalSince1970: 1), address: "a", left: 50, right: 60, state: .idle, wearing: false)
    try store.insert(s)
    #expect(try store.samples(address: "a") == [s])
    _ = try Store(path: path) // reopening runs the migration again without failing
}

private func bytes(_ hex: String) -> Data {
    Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
}

@Test func galaxyFramesFromRealBuds() {
    // Captured from Galaxy Buds2 Pro: extended status, an unrelated message split across reads, then a status update.
    var buffer = bytes("fd 31 00 61 0d 04 56 59 01 00 11 00 00 00 bf 22 02 00 48 01 48 01 00 00 03 35 00 01 00 10 00 01 00 00 11 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 23 f8 dd fd 06 50 c2 26 00")
    var messages = GalaxyProtocol.extractMessages(&buffer)
    #expect(messages.count == 1)
    #expect(buffer.count == 6)  // partial message kept for the next read
    let extended = GalaxyProtocol.parse(id: messages[0].id, payload: messages[0].payload)
    #expect(extended == .init(left: 86, right: 89, caseLevel: nil, placementLeft: 1, placementRight: 1))

    buffer.append(bytes("01 8b 7a dd fd 0b 40 60 01 55 58 01 00 11 2e 00 fb aa dd"))
    messages = GalaxyProtocol.extractMessages(&buffer)
    #expect(messages.map(\.id) == [0xc2, 0x60])
    #expect(buffer.isEmpty)
    let status = GalaxyProtocol.parse(id: 0x60, payload: messages[1].payload)
    #expect(status == .init(left: 85, right: 88, caseLevel: 46, placementLeft: 1, placementRight: 1))
    #expect(status?.wearing == true)
    #expect(GalaxyProtocol.parse(id: 0xc2, payload: messages[0].payload) == nil)
}

// Regression tests from code review.

private func lrSamples(_ segments: [(hours: Double, state: UsageState, leftRate: Double, rightRate: Double)],
                       start: Date = Date(timeIntervalSince1970: 1_750_000_000), left: Double = 100, right: Double = 100,
                       main: Bool = false) -> [Sample] {
    var out: [Sample] = []
    var t = start, l = left, r = right
    for seg in segments {
        for _ in 0..<Int(seg.hours * 30) {
            let li = Int(l.rounded(.up)), ri = Int(r.rounded(.up))
            out.append(main ? Sample(time: t, address: "x", main: (li + ri) / 2, state: seg.state)
                            : Sample(time: t, address: "x", left: li, right: ri, state: seg.state))
            t += 120; l -= seg.leftRate / 30; r -= seg.rightRate / 30
        }
    }
    return out
}

@Test func singleLevelFallbackStillCounts() {
    // An hour with per-bud data, then four hours where only the pair level is known.
    var samples = lrSamples([(1, .listening, 10, 10)])
    for i in samples.indices { samples[i].main = samples[i].left }
    let tail = lrSamples([(4, .listening, 10, 10)], start: samples.last!.time + 120, left: 90, right: 90, main: true)
    samples += tail
    let r = DeviceReport.build(device: device(), samples: samples, now: samples.last!.time)
    #expect(r.drain[.listening]!.hours > 4)
    #expect(r.remainingHours != nil)
    #expect(r.levels.map(\.channel) == [.main])
}

@Test func timeLeftUsesBudThatDiesFirst() {
    // Left at 50% draining slowly, right at 60% draining fast.
    let samples = lrSamples([(3, .listening, 5, 20)], left: 65, right: 120)
    let r = DeviceReport.build(device: device("AirPods Pro"), samples: samples, now: samples.last!.time)
    let right = Double(samples.last!.right!) / 20
    #expect(abs(r.remainingHours! - right) < 0.5)
}

@Test func briefDataDoesNotOverrideLongHistory() {
    // Left: ~10h at 10%/h across several charges. Right: one short burst at a high rate.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<3 {
        let run = lrSamples([(3.3, .listening, 10, 10)], start: t)
        samples += run.map { var s = $0; s.right = nil; return s }
        t = run.last!.time + 6 * 3600
    }
    let burst = lrSamples([(0.6, .listening, 19, 19)], start: t)
    samples += burst.map { var s = $0; s.left = nil; return s }
    let r = DeviceReport.build(device: device("AirPods Pro"), samples: samples, now: samples.last!.time)
    #expect(abs(r.drain[.listening]!.ratePerHour! - 10) < 1)
}

@Test func oldIdleDataStillShownWhenRecentListeningExists() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    var samples = lrSamples([(20, .idle, 3, 3)], start: now - 40 * 86400, main: true)
    samples += lrSamples([(3, .listening, 20, 20)], start: now - 3 * 3600, main: true)
    let r = DeviceReport.build(device: device(), samples: samples, now: now)
    #expect(r.basisDays == 30)
    #expect(abs(r.drain[.idle]!.ratePerHour! - 3) < 0.5)
}

@Test func cyclesCountPartialSteps() {
    // 1.5h sessions with 10% steps: each shows 100 -> 80, but step-to-step only spans 90 -> 80.
    var sim = Simulator()
    sim.step = 10
    for _ in 0..<5 {
        sim.level = 100
        sim.run(hours: 1.5, ratePerHour: 20, state: .listening)
        sim.disconnect(hours: 2)
    }
    let r = DeviceReport.build(device: device(), samples: sim.samples, now: sim.time)
    #expect(abs(r.trackedCycles - 1.0) < 0.01)
}

@Test func missingValuesDoNotBreakRuns() {
    var sim = Simulator()
    sim.run(hours: 3, ratePerHour: 20, state: .listening)
    // Every 7th reading has no battery value.
    for i in sim.samples.indices where i % 7 == 3 { sim.samples[i].main = nil }
    let d = Analysis.drain(Analysis.intervals(sim.samples, channel: .main))
    #expect(d[.listening]!.hours > 2.8)
    #expect(abs(d[.listening]!.ratePerHour! - 20) < 1)
}

@Test func detectsEarbudModels() {
    #expect(EarbudModel.detect(name: "Galaxy Buds3 Pro (7A75)", productID: nil) == .galaxyBuds3)
    #expect(EarbudModel.detect(name: "Galaxy Buds2 Pro", productID: nil) == .galaxyBuds2)
    #expect(EarbudModel.detect(name: "Sam's Pixel Buds A-Series", productID: nil) == .pixelBudsA)
    #expect(EarbudModel.detect(name: "Pixel Buds Pro 2", productID: nil) == .pixelBudsPro)
    #expect(EarbudModel.detect(name: "Sam's Bose QC35 II", productID: nil) == .headphones)
    #expect(EarbudModel.detect(name: "Sam's AirPods", productID: 0x2014) == .airpodsPro)
    #expect(EarbudModel.detect(name: "Sam's AirPods Max", productID: nil) == .airpodsMax)
    #expect(EarbudModel.detect(name: "Some Headset", productID: nil) == .earbuds)
}
