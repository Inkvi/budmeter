import Foundation
import SQLite3
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
    #expect(EarbudModel.detect(name: "Pixel Buds Pro", productID: nil) == .pixelBudsPro)
    #expect(EarbudModel.detect(name: "Sam's Bose QC35 II", productID: nil) == .boseHeadphones)
    #expect(EarbudModel.detect(name: "Sam's AirPods", productID: 0x2014) == .airpodsPro)
    #expect(EarbudModel.detect(name: "Sam's AirPods Max", productID: nil) == .airpodsMax)
    #expect(EarbudModel.detect(name: "Some Headset", productID: nil) == .earbuds)
}

@Test func detectsOtherBrands() {
    let cases: [(String, Int?, EarbudModel)] = [
        ("WF-1000XM5", nil, .sonyWFXM5), ("WF-1000XM4", nil, .sonyWFXM4), ("LinkBuds S", nil, .sonyWFXM5),
        ("LinkBuds", nil, .sonyLinkBuds), ("WH-1000XM5", nil, .sonyWHXM5), ("WH-1000XM4", nil, .sonyWHXM4),
        ("Nothing Ear (2)", nil, .nothingEar), ("Ear (a)", nil, .nothingEar), ("CMF Buds Pro 2", nil, .cmfBuds),
        ("Nothing Headphone (1)", nil, .nothingHeadphone),
        ("Bose QC Ultra Earbuds", nil, .boseQCEarbuds), ("Bose Ultra Open Earbuds", nil, .boseUltraOpen),
        ("Bose QC Ultra Headphones", nil, .boseHeadphones),
        ("Beats Fit Pro", nil, .beatsFitPro), ("Sam's Beats", 0x200B, .powerbeatsPro),
        ("Beats Studio Pro", nil, .beatsHeadphones), ("Beats Studio Buds +", nil, .beatsStudioBuds),
        ("Galaxy Buds Live", nil, .galaxyBudsLive), ("Galaxy Buds FE", nil, .galaxyBudsFE),
        ("Pixel Buds Pro 2", nil, .pixelBudsPro2),
        ("Jabra Elite 10", nil, .jabraElite), ("MOMENTUM TW 4", nil, .sennheiserMomentum),
        ("Momentum 4", nil, .headphones), ("OnePlus Buds Pro 3", nil, .oneplusBuds),
        ("Soundcore Liberty 4 NC", nil, .soundcoreLiberty), ("OpenRun Pro 2 by Shokz", nil, .shokzOpenRun),
        ("HUAWEI FreeBuds Pro 3", nil, .huaweiFreeBudsPro),
    ]
    for (name, pid, model) in cases {
        #expect(EarbudModel.detect(name: name, productID: pid) == model, "\(name)")
    }
}

@Test func everyModelHasAPicture() {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../design/devices").standardized
    for model in EarbudModel.allCases {
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(model.rawValue).png").path),
                "missing picture for \(model.rawValue)")
    }
}

@Test func connectedTimeSkipsTheCase() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    func add(_ minutes: Int, level: (Int) -> Int, state: UsageState = .idle, inCase: Bool? = nil) {
        for i in 0..<(minutes / 2) {
            samples.append(Sample(time: t, address: "x", main: level(i), state: state, inCase: inCase))
            t += 120
        }
    }
    add(60, level: { 80 - $0 / 3 }, state: .listening)          // 1h listening
    add(30, level: { _ in 70 }, inCase: true)                     // 30 min in the case, flat
    add(30, level: { 70 + $0 })                                   // 30 min charging, case status unknown
    add(60, level: { _ in 100 })                                  // 1h idle out of the case
    let h = Analysis.connectedHours(samples)
    #expect(abs(h[.listening]! - 1) < 0.05)
    #expect(abs(h[.idle]! - 1) < 0.1)
}

@Test func galaxyInCaseStatus() {
    func status(_ l: Int, _ r: Int) -> GalaxyProtocol.Status {
        .init(left: 50, right: 50, caseLevel: nil, placementLeft: l, placementRight: r)
    }
    #expect(status(3, 3).inCase)
    #expect(status(3, 0).inCase)        // other bud not connected
    #expect(!status(3, 1).inCase)       // one bud still in an ear
    #expect(!status(2, 3).inCase)       // one bud on the desk
    #expect(!status(0, 0).inCase)
}

@Test func storeKeepsInCase() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let s = Sample(time: Date(timeIntervalSince1970: 1), address: "a", left: 50, right: 60, state: .idle,
                   wearing: false, inCase: true)
    try store.insert(s)
    #expect(try store.samples(address: "a") == [s])
}

// Regression tests from the second code review.

private func s(_ t: Date, main: Int? = nil, left: Int? = nil, right: Int? = nil, _ state: UsageState,
               inCase: Bool? = nil, start: Bool = false) -> Sample {
    Sample(time: t, address: "x", main: main, left: left, right: right, state: state, inCase: inCase, sessionStart: start)
}

@Test func coarseStepIsSharedAcrossActivities() {
    // Battery falls 10 points every 30 minutes; each half hour is 29 min listening then 1 min idle.
    var samples: [Sample] = []
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    for minute in 0...120 {
        let level = 100 - (minute / 30) * 10
        let state: UsageState = minute % 30 == 29 ? .idle : .listening
        samples.append(s(t0 + Double(minute) * 60, main: level, state))
    }
    let d = Analysis.drain(Analysis.intervals(samples, channel: .main))
    #expect(d[.listening]!.drop > 25)          // used to be 0, with all 30 points on 3 idle minutes
    #expect((d[.idle]?.drop ?? 0) < 3)
}

@Test func mixedSpansLearnFromPureOnes() {
    // Pure idle spans at 2%/h teach the idle rate; mixed spans then give listening the rest.
    var sim = Simulator()
    sim.run(hours: 10, ratePerHour: 2, state: .idle)
    for _ in 0..<6 {
        sim.run(hours: 0.5, ratePerHour: 20, state: .listening)
        sim.run(hours: 0.25, ratePerHour: 2, state: .idle)
    }
    let d = Analysis.drain(Analysis.intervals(sim.samples, channel: .main))
    #expect(abs(d[.idle]!.ratePerHour! - 2) < 0.6)
    #expect(abs(d[.listening]!.ratePerHour! - 20) < 2.5)
}

@Test func shortDisconnectEndsTheSession() {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [
        s(t0, main: 80, .listening, start: true), s(t0 + 60, main: 80, .listening), s(t0 + 120, main: 79, .listening),
        // 4 minutes away, used on the phone: 10 points gone.
        s(t0 + 360, main: 69, .listening, start: true), s(t0 + 420, main: 69, .listening), s(t0 + 480, main: 68, .listening),
    ]
    #expect(Analysis.totalDrop(samples, channel: .main) == 2)
    #expect(abs(Analysis.connectedHours(samples)[.listening]! - 4.0 / 60) < 0.001)
    #expect(Analysis.intervals(samples, channel: .main).isEmpty)
}

@Test func flatTimeInTheCaseIsNotDrain() {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    var samples: [Sample] = []
    for i in 0..<10 { samples.append(s(t0 + Double(i) * 120, main: 90 - i, .idle)) }
    for i in 10..<28 { samples.append(s(t0 + Double(i) * 120, main: 81, .idle, inCase: true)) }   // 36 min in the case
    for i in 28..<38 { samples.append(s(t0 + Double(i) * 120, main: 81 - (i - 27), .idle)) }
    let d = Analysis.drain(Analysis.intervals(samples, channel: .main))
    #expect(d[.idle]!.hours < 0.65)   // two 18-minute runs, not 74 minutes
}

@Test func idleShareCountsSingleDropSessions() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<10 {   // ten idle sessions, each a single 10-point step
        samples.append(s(t, main: 100, .idle, start: true)); samples.append(s(t + 120, main: 90, .idle))
        t += 3600
    }
    var sim = Simulator()
    sim.time = t
    sim.run(hours: 4, ratePerHour: 20, state: .listening)
    samples += sim.samples
    let r = DeviceReport.build(device: device(), samples: samples, now: sim.time)
    #expect(r.idleShareOfDrain! > 0.5)
}

@Test func leftRightComparesTheSameActivity() {
    // Both buds drain identically while listening; only the right bud takes calls.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    var l = 100.0, r = 100.0
    for _ in 0..<90 { samples.append(s(t, left: Int(l.rounded(.up)), right: Int(r.rounded(.up)), .listening)); t += 120; l -= 0.5; r -= 0.5 }
    for _ in 0..<30 { samples.append(s(t, left: nil, right: Int(r.rounded(.up)), .call)); t += 120; r -= 1 }
    let rep = DeviceReport.build(device: device("AirPods Pro"), samples: samples, now: t)
    #expect(abs(rep.rightVsLeft ?? 1) < 0.05)
}

@Test func timeLeftIgnoresAChargingBud() {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    var samples = lrSamples([(3, .listening, 10, 10)], start: t0)
    let t = samples.last!.time, left = samples.last!.left!
    samples.append(s(t + 120, left: left, right: 15, .listening))   // right went into the case at 15%...
    samples.append(s(t + 240, left: left, right: 18, .listening))   // ...and is charging
    let rep = DeviceReport.build(device: device("AirPods Pro"), samples: samples, now: t + 240)
    #expect(abs(rep.remainingHours! - Double(left) / 10) < 0.6)   // the left bud, not the charging right one
}

@Test func implausibleRatedHoursAreIgnored() {
    var d = device()
    d.ratedHoursOverride = 1e-20
    #expect(d.ratedHours == 5)   // falls back to the built-in rating
    d.ratedHoursOverride = 7
    #expect(d.ratedHours == 7)
}

@Test func storeKeepsSessionStart() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let a = s(Date(timeIntervalSince1970: 1), main: 50, .idle, start: true)
    let b = s(Date(timeIntervalSince1970: 61), main: 50, .idle)
    try store.record(a, name: "Buds", productID: nil)
    try store.insert(b)
    #expect(try store.samples(address: "x") == [a, b])
    #expect(try store.devices().first?.name == "Buds")
}

@Test func oneBudInTheCaseStopsOnlyThatBud() {
    // Both buds listening; after an hour the right bud goes into the case (flat at first, then
    // charging) while the left bud keeps playing for another hour.
    var samples: [Sample] = []
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    for i in 0..<30 {
        samples.append(Sample(time: t0 + Double(i) * 120, address: "x", left: 90 - i / 2, right: 90 - i / 2,
                              state: .listening, placementLeft: 1, placementRight: 1))
    }
    for i in 30..<60 {
        let right = i < 45 ? 75 : 75 + (i - 45)   // flat in the case for 30 min, then charging
        samples.append(Sample(time: t0 + Double(i) * 120, address: "x", left: 90 - i / 2, right: right,
                              state: .listening, placementLeft: 1, placementRight: 3))
    }
    let right = Analysis.drain(Analysis.intervals(samples, channel: .right))[.listening]!
    let left = Analysis.drain(Analysis.intervals(samples, channel: .left))[.listening]!
    #expect(right.hours < 1.0)          // the flat time in the case isn't counted as drain
    #expect(abs(right.ratePerHour! - 15) < 1.5)
    #expect(left.hours > 1.8)           // the left bud keeps its whole run
    // Connected time keeps counting while one bud is still in use.
    #expect(abs(Analysis.connectedHours(samples)[.listening]! - 59.0 * 2 / 60) < 0.05)
    // Time left comes from the bud in the ear even though the cased one reads lower.
    let rep = DeviceReport.build(device: device("Galaxy Buds3 Pro"), samples: samples, now: samples.last!.time)
    let leftLevel = Double(samples.last!.left!)
    #expect(abs(rep.remainingHours! - leftLevel / 15) < 0.5)
}

@Test func storeKeepsPlacements() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let s = Sample(time: Date(timeIntervalSince1970: 1), address: "a", left: 50, right: 60, state: .idle,
                   placementLeft: 1, placementRight: 3)
    try store.insert(s)
    #expect(try store.samples(address: "a") == [s])
    #expect(s.isInCase(.right) && !s.isInCase(.left) && s.isInCase(.main))
}

@Test func unsavedReadingsAreRetriedInOrder() {
    struct Failure: Error {}
    var queue = UnsavedSamples(limit: 3)
    let t0 = Date(timeIntervalSince1970: 1)
    for i in 0..<4 { queue.add(.init(Sample(time: t0 + Double(i), address: "x", main: 50, state: .idle))) }
    #expect(queue.items.count == 3)   // the oldest one is dropped past the limit

    var saved: [Date] = []
    var failNext = true
    let error = queue.retry { sample in
        if failNext { failNext = false; throw Failure() }
        saved.append(sample.sample.time)
    }
    #expect(error != nil && saved.isEmpty && queue.items.count == 3)   // nothing lost on failure

    #expect(queue.retry { saved.append($0.sample.time) } == nil)
    #expect(saved == [t0 + 1, t0 + 2, t0 + 3] && queue.items.isEmpty)
}

@Test func queuedReadingsSurviveALockedDatabase() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    // Another connection takes an exclusive lock, so writes fail with "database is locked".
    var other: OpaquePointer?
    sqlite3_open(path, &other)
    defer { sqlite3_close(other) }
    #expect(sqlite3_exec(other, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)

    var queue = UnsavedSamples()
    let first = Sample(time: Date(timeIntervalSince1970: 1), address: "x", main: 80, state: .idle)
    let second = Sample(time: Date(timeIntervalSince1970: 2), address: "x", main: 79, state: .idle, sessionStart: true)
    #expect(throws: (any Error).self) { try store.insert(first) }
    queue.add(.init(first, device: (name: "Galaxy Buds2 Pro", productID: nil)))   // a failed first reading
    queue.add(.init(second))
    let save = { (item: UnsavedSamples.Item) in
        if let device = item.device {
            try store.record(item.sample, name: device.name, productID: device.productID)
        } else {
            try store.insert(item.sample)
        }
    }
    #expect(queue.retry(save) != nil)
    #expect(queue.items.count == 2)

    sqlite3_exec(other, "ROLLBACK", nil, nil, nil)
    #expect(queue.retry(save) == nil)
    #expect(try store.samples(address: "x") == [first, second])
    #expect(try store.devices().map(\.name) == ["Galaxy Buds2 Pro"])   // the device row came back too
}

/// Polls every 30 seconds while a battery drains from `top` to `bottom`, then leaves a 6-hour gap.
private func session(_ samples: inout [Sample], _ t: inout Date, from top: Int, to bottom: Int,
                     minutesPerPercent: (Int) -> Double) {
    var level = Double(top)
    var first = true
    while Int(level.rounded(.up)) > bottom {
        samples.append(s(t, main: Int(level.rounded(.up)), .listening, start: first))
        first = false
        level -= 0.5 / minutesPerPercent(Int(level))
        t += 30
    }
    samples.append(s(t, main: bottom, .listening))
    t += 6 * 3600
}

/// Like a worn Galaxy Buds2 Pro: 3 minutes per 1% down to 30%, then 30% -> 1% in 10 minutes.
private func cliff(_ level: Int) -> Double { level >= 30 ? 3 : 10.0 / 29 }

@Test func batteryThatCollapsesAtTheEndCountsTheCliff() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<3 { session(&samples, &t, from: 90, to: 60, minutesPerPercent: cliff) }
    session(&samples, &t, from: 45, to: 1, minutesPerPercent: cliff)

    let rep = DeviceReport.build(device: device(), samples: samples, now: t)
    let hours = rep.drain[.listening]!.fullChargeHours!
    // Truth: 70% x 3 min + 10 min = 3.67 h. A straight line through all of it said about 4 h.
    #expect(abs(hours - 3.67) < 0.2)
    #expect((28...31).contains(rep.fastDrainBelow ?? 0))
    #expect(rep.verdict == .worn)

    // At 25% only the steep part is left: minutes, not the 1h15m a straight line would give.
    let curve = Analysis.chargeCurve(samples, channels: [.main], now: t)
    #expect(curve.hoursLeft(from: 25, rate: rep.drain[.listening]!.ratePerHour!) < 0.25)
}

@Test func recentMidChargeUseKeepsTheCliffFromOlderHistory() {
    // The cliff was seen 40 days ago; the last 30 days only used the middle of the charge. The
    // recent rate is slower than the all-time one, which must not inflate runtime.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    session(&samples, &t, from: 90, to: 1, minutesPerPercent: cliff)
    t += 40 * 86400
    for _ in 0..<4 { session(&samples, &t, from: 90, to: 60, minutesPerPercent: cliff) }

    let rep = DeviceReport.build(device: device(), samples: samples, now: t)
    #expect(rep.basisDays == 30)
    #expect(abs(rep.drain[.listening]!.fullChargeHours! - 3.67) < 0.2)
    // Listening is the only activity, so the real mix is the same runtime.
    #expect(abs(rep.mixed.fullChargeHours! - rep.drain[.listening]!.fullChargeHours!) < 0.05)
}

@Test func oneGlitchyStepDoesNotMakeACliff() {
    // Steady 3 minutes per 1% above 40%, plus one session where a headset reports 40 -> 30 -> 20 -> 30.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<3 { session(&samples, &t, from: 100, to: 40) { _ in 3 } }
    for (i, level) in [40, 30, 20, 30].enumerated() {
        samples.append(s(t + Double(i) * 30, main: level, .listening, start: i == 0))
    }
    let rep = DeviceReport.build(device: device(), samples: samples, now: t + 120)
    #expect(rep.fastDrainBelow == nil)
    // The glitch's 10% still counts as drain (about 4.7 h), but not as a cliff (which gave 3.5 h).
    #expect(rep.drain[.listening]!.fullChargeHours! > 4.5)
}

@Test func aDipThatBouncesBackIsAMisreading() {
    // Steady 3 minutes per 1% from 100% to 27%, except one 30-second reading of 20% at 27%.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<3 { session(&samples, &t, from: 100, to: 27) { _ in 3 } }
    let last = samples.removeLast()
    samples.append(s(last.time, main: 20, .listening))
    samples.append(s(last.time + 30, main: 27, .listening))
    let rep = DeviceReport.build(device: device(), samples: samples, now: last.time + 60)
    #expect(rep.fastDrainBelow == nil)
    #expect(abs(rep.drain[.listening]!.fullChargeHours! - 5) < 0.2)

    // Same with the low reading held for two polls (say the activity changed in between).
    samples.removeLast()
    samples.append(s(last.time + 30, main: 20, .idle))
    samples.append(s(last.time + 60, main: 27, .listening))
    let held = DeviceReport.build(device: device(), samples: samples, now: last.time + 90)
    #expect(held.fastDrainBelow == nil)
}

@Test func aReconnectAtAHigherLevelKeepsTheRealDrop() {
    // 29 -> 27 -> 25 -> 23 at 30-second polls, then a new session reads 24%: the steps were real.
    let t = Date(timeIntervalSince1970: 1_750_000_000)
    let samples = [s(t, main: 29, .listening, start: true), s(t + 30, main: 27, .listening),
                   s(t + 60, main: 25, .listening), s(t + 90, main: 23, .listening),
                   s(t + 120, main: 24, .listening, start: true)]
    let drop = Analysis.intervals(samples, channel: .main).reduce(0) { $0 + $1.drop }
    #expect(drop == 4)   // 27 -> 25 -> 23: the first observed step to the last
}

@Test func misreadingEdgeCases() {
    let t = Date(timeIntervalSince1970: 1_750_000_000)
    func drop(_ readings: [(Double, Int?, Bool)]) -> Double {
        let samples = readings.map { s(t + $0.0, main: $0.1, .listening, start: $0.2) }
        return Analysis.intervals(samples, channel: .main).reduce(0) { $0 + $1.drop }
    }
    // A rebound exactly 2 minutes after the low reading is still a misreading.
    #expect(drop([(0, 28, true), (180, 27, false), (210, 20, false), (330, 27, false), (510, 26, false)]) == 1)
    // After a removed dip the discharge carries on: 27 -> 26 -> 25 still counts.
    #expect(drop([(0, 29, true), (180, 28, false), (360, 27, false), (390, 20, false), (420, 27, false),
                  (600, 26, false), (780, 25, false)]) == 3)
    // A reconnect whose first reading is empty still ends the old run: 30 -> 27 stays, nothing is erased.
    #expect(drop([(0, 31, true), (60, 30, false), (120, 27, false), (150, nil, true), (180, 30, false)]) == 3)
}

@Test func idleCollapseAfterNormalUseIsFound() {
    // Like the real Galaxy Buds2 Pro: listening and idle from 49% to 28% at a normal pace, then
    // 28% -> 1% in 10 minutes while idle. Later a small recharge to 17% drains normally.
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    for _ in 0..<2 { session(&samples, &t, from: 90, to: 60) { _ in 3 } }
    var level = 49.0
    var first = true
    while level > 1 {
        let state: UsageState = level < 28 ? .idle : (Int(level) % 3 == 0 ? .idle : .listening)
        samples.append(s(t, main: Int(level.rounded(.up)), state, start: first))
        first = false
        level -= level < 28 ? 27.0 / 20 : 0.15   // 20 polls for the collapse; about 3.3 min per 1% before
        t += 30
    }
    samples.append(s(t, main: 1, .idle))
    t += 3600
    session(&samples, &t, from: 17, to: 3) { _ in 3 }

    let rep = DeviceReport.build(device: device(), samples: samples, now: t)
    #expect((26...29).contains(rep.fastDrainBelow ?? 0))
    #expect(rep.verdict == .worn)
}

@Test func onlyARealCollapseToEmptyCounts() {
    var samples: [Sample] = []
    var t = Date(timeIntervalSince1970: 1_750_000_000)
    // A steady drain from 49% all the way to 1%: no cliff, even though the last step is the end.
    session(&samples, &t, from: 49, to: 1) { _ in 3 }
    #expect(Analysis.chargeCurve(samples, channels: [.main], now: t).cliff == nil)

    // A real collapse to empty sets one...
    session(&samples, &t, from: 49, to: 1, minutesPerPercent: cliff)
    let found = Analysis.chargeCurve(samples, channels: [.main], now: t)
    #expect((28...31).contains(found.cliff ?? 0))

    // ...and a later run that went into the case at 2% doesn't clear it.
    var level = 45
    var first = true
    while level > 2 {
        samples.append(s(t, main: level, .listening, start: first))
        first = false
        level -= 1
        t += 180
    }
    samples.append(s(t, main: 2, .idle, inCase: true))
    t += 3600
    #expect(Analysis.chargeCurve(samples, channels: [.main], now: t) == found)
}
