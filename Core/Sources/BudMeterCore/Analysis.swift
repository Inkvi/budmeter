import Foundation

/// A stretch of time between two samples where the battery was measurably discharging.
public struct DrainInterval: Sendable, Equatable {
    public var start: Date
    public var hours: Double
    /// Percentage points lost during the interval.
    public var drop: Double
    public var state: UsageState
    public var wearing: Bool?
    /// Battery level in the middle of the step-to-step span this piece belongs to.
    public var level: Double = 50
}

/// Battery lost over a period of time in one usage state.
public struct StateDrain: Sendable, Equatable {
    public var hours: Double
    public var drop: Double

    /// The battery's charge curve, for turning the rate into runtime.
    public var curve: ChargeCurve

    public init(hours: Double = 0, drop: Double = 0, curve: ChargeCurve = .flat) {
        self.hours = hours
        self.drop = drop
        self.curve = curve
    }

    /// Minimum evidence before we trust a rate.
    public static let minHours = 0.5
    public static let minDrop = 5.0

    public var hasEnoughData: Bool { hours >= Self.minHours && drop >= Self.minDrop }
    /// Percent per hour, nil until there is enough data.
    public var ratePerHour: Double? { hasEnoughData ? drop / hours : nil }
    /// How long a full 100% charge lasts, following the battery's charge curve.
    public var fullChargeHours: Double? { ratePerHour.map(curve.fullChargeHours) }

    public var confidence: Confidence {
        switch drop {
        case ..<15: .low
        case ..<40: .medium
        default: .high
        }
    }

    mutating func add(_ interval: DrainInterval) {
        hours += interval.hours
        drop += interval.drop
    }

    public static func + (a: StateDrain, b: StateDrain) -> StateDrain {
        // Both sides come from the same battery, so they share one curve; an empty side has none.
        StateDrain(hours: a.hours + b.hours, drop: a.drop + b.drop, curve: a.hours > 0 ? a.curve : b.curve)
    }
}

/// Where a worn battery stops behaving normally.
///
/// A worn battery often reads normally down to some level and then collapses, whatever the earbuds
/// are doing: these Galaxy Buds went from 28% to empty in ten minutes, mostly idle. Projecting the
/// normal rate in a straight line to 0% misses that. So runtime is the normal drain down to the
/// cliff, plus the time the cliff itself was measured to last.
public struct ChargeCurve: Sendable, Equatable {
    /// Level below which the battery collapses, nil when that hasn't been seen.
    public var cliff: Int?
    /// Hours the battery lasts from `cliff` to empty.
    public var cliffHours: Double

    public static let flat = ChargeCurve(cliff: nil, cliffHours: 0)

    /// Full-charge hours when the battery drains at `rate` percent per hour above the cliff.
    public func fullChargeHours(rate: Double) -> Double {
        hoursLeft(from: 100, rate: rate)
    }

    public func hoursLeft(from level: Double, rate: Double) -> Double {
        guard let cliff, cliff > 0 else { return level / rate }
        let edge = Double(cliff)
        return max(level - edge, 0) / rate + cliffHours * min(level, edge) / edge
    }

    /// True for readings inside the cliff, which say nothing about the normal drain rate.
    public func contains(level: Double) -> Bool { cliff.map { level < Double($0) } ?? false }
}

public enum Confidence: String, Sendable {
    case low, medium, high
}

public enum Analysis {
    /// Samples further apart than this are treated as a disconnect (or Mac asleep).
    public static let maxGap: TimeInterval = 6 * 60

    /// True when `sample` belongs to the same continuous connection as the reading at `previous`.
    public static func continues(from previous: Date, to sample: Sample) -> Bool {
        !sample.sessionStart && sample.time.timeIntervalSince(previous) <= maxGap
    }

    /// A drop this big this fast means a bud was swapped or reset, not drained.
    static func implausible(from a: Int, to b: Int, after gap: TimeInterval) -> Bool {
        a - b >= 15 && gap < 15 * 60
    }

    /// Turn raw samples into discharge intervals for one battery.
    ///
    /// Headsets report battery in steps (often 10%, sometimes 1%). Measuring from an arbitrary
    /// point would mix in an unknown part of a step, so within each continuous discharge run we
    /// only count time from the first observed step down to the last observed step down. That
    /// keeps step size from skewing the rate, and it drops flat time in the charging case.
    ///
    /// A run ends on: a new session (disconnect, sleep, restart) or a gap, a rise in level
    /// (charging), this bud going into the case, or an implausible jump. A drop of 3 or more points
    /// that is mostly undone within 2 minutes is dropped as a misreading. A sample without a value for this
    /// battery is skipped, not a break: headsets sometimes report nothing for a moment.
    ///
    /// Each step-to-step span is one measurement: we know its total drop, not when inside it the
    /// battery fell. When a span mixes activities, its drop is shared between them in proportion to
    /// how fast each activity drains, estimated from all spans together (see `attribute`).
    ///
    /// Readings below `cliff` are left out: inside a collapse the drop says nothing about how fast
    /// each activity drains, and it would skew the shares between them.
    public static func intervals(_ samples: [Sample], channel: Channel, above cliff: Int? = nil) -> [DrainInterval] {
        var spans: [Span] = []
        for whole in runs(samples, channel: channel) {
            let run = whole.readings.filter { $0.value >= cliff ?? 0 }
            let steps = run.indices.dropFirst().filter { run[$0].value < run[$0 - 1].value }
            for (a, b) in zip(steps, steps.dropFirst()) {
                let level = Double(run[a].value + run[b].value) / 2
                let pieces = (a..<b).map { i in
                    DrainInterval(start: run[i].time, hours: run[i + 1].time.timeIntervalSince(run[i].time) / 3600,
                                  drop: 0, state: run[i].state, wearing: run[i].wearing, level: level)
                }
                spans.append(Span(pieces: pieces, drop: Double(run[a].value - run[b].value)))
            }
        }
        return attribute(spans)
    }

    public struct Reading: Sendable, Equatable {
        public var time: Date
        public var value: Int
        public var state: UsageState
        public var wearing: Bool?
    }

    public struct Run: Sendable {
        public var readings: [Reading]
        /// True when the connection ended right after this run (the earbuds disconnected or died),
        /// false when it ended any other way, nil when it's the latest run and may still be going.
        public var endedByDisconnect: Bool?
    }

    /// Continuous discharge runs of one battery: readings from one connection, never rising, outside
    /// the case (see `intervals` for what ends a run).
    public static func runs(_ samples: [Sample], channel: Channel) -> [Run] {
        var out: [Run] = []
        var run: [Reading] = []
        func flush(disconnect: Bool?) {
            if run.count > 1 { out.append(Run(readings: run, endedByDisconnect: disconnect)) }
            run.removeAll()
        }
        for sample in samples {
            if sample.isInCase(channel) {
                flush(disconnect: false)
                continue
            }
            // A new connection ends the run even when its first reading has no value for this battery.
            if sample.sessionStart { flush(disconnect: true) }
            guard let value = sample.value(channel) else { continue }
            // A level that drops at least 3 points and wins back at least half of that within
            // 2 minutes, in the same connection, was a misreading: drop the low readings.
            if let prev = run.last, continues(from: prev.time, to: sample), value > prev.value,
               let low = run.lastIndex(where: { $0.value != prev.value }).map({ $0 + 1 }) {
                let dip = run[low - 1].value - prev.value
                if dip >= 3, 2 * (value - prev.value) >= dip,
                   sample.time.timeIntervalSince(run[low].time) <= 120 {
                    run.removeSubrange(low...)
                }
            }
            if let prev = run.last {
                let gap = sample.time.timeIntervalSince(prev.time)
                if !continues(from: prev.time, to: sample) || value > prev.value
                    || implausible(from: prev.value, to: value, after: gap) {
                    flush(disconnect: false)
                }
            }
            run.append(Reading(time: sample.time, value: value, state: sample.state, wearing: sample.wearing))
        }
        flush(disconnect: nil)
        return out
    }

    struct Span {
        var pieces: [DrainInterval]
        var drop: Double
    }

    /// Shares each span's drop between its pieces in proportion to (drain rate of that activity) x time.
    /// The rates come from the spans themselves, refined a few times (expectation maximization): spans
    /// with a single activity pin down that activity's rate, and mixed spans follow. Totals are exact.
    static func attribute(_ spans: [Span]) -> [DrainInterval] {
        struct Key: Hashable { var state: UsageState; var wearing: Bool? }
        let key = { (p: DrainInterval) in Key(state: p.state, wearing: p.wearing) }
        let totalHours = spans.flatMap(\.pieces).reduce(0) { $0 + $1.hours }
        guard totalHours > 0 else { return [] }
        var rate: [Key: Double] = [:]
        let start = spans.reduce(0) { $0 + $1.drop } / totalHours
        for p in spans.flatMap(\.pieces) { rate[key(p)] = start }

        func shares(_ span: Span) -> [Double] {
            let weights = span.pieces.map { (rate[key($0)] ?? 0) * $0.hours }
            let total = weights.reduce(0, +)
            let hours = span.pieces.reduce(0) { $0 + $1.hours }
            if total > 0 { return weights.map { $0 / total } }
            return span.pieces.map { hours > 0 ? $0.hours / hours : 1 / Double(span.pieces.count) }
        }

        for _ in 0..<25 {
            var drop: [Key: Double] = [:], hours: [Key: Double] = [:]
            for span in spans {
                for (p, share) in zip(span.pieces, shares(span)) {
                    drop[key(p), default: 0] += span.drop * share
                    hours[key(p), default: 0] += p.hours
                }
            }
            for (k, h) in hours where h > 0 { rate[k] = (drop[k] ?? 0) / h }
        }

        return spans.flatMap { span in
            zip(span.pieces, shares(span)).map { p, share in
                var out = p
                out.drop = span.drop * share
                return out
            }
        }
    }

    /// Finds where the battery collapses, from the latest discharge that started at 40% or more and
    /// ran empty (2% or less, then the connection ended), across the pair's batteries. A run that
    /// ended in the case, in a gap or that may still be going doesn't count.
    ///
    /// The edge is the reading after which the rest of that run went fastest compared with how the
    /// run had been going: the time the earlier pace predicts for the drop seen after it, over the
    /// time that drop took. It's a cliff when that is 3x or more over at least 5 points. Its measured
    /// length then replaces the straight-line guess for the end of every charge. The latest such run
    /// decides, so a battery that stops collapsing (or starts) is picked up.
    public static func chargeCurve(_ samples: [Sample], channels: [Channel], now: Date) -> ChargeCurve {
        var latest: (end: Date, curve: ChargeCurve)?
        for channel in channels {
            for run in runs(samples, channel: channel) {
                let r = run.readings
                let end = r.last!.time
                let closed = run.endedByDisconnect ?? (now.timeIntervalSince(end) > maxGap)
                guard closed, r[0].value >= 40, r.last!.value <= 2, end > latest?.end ?? .distantPast else { continue }
                var best: (ratio: Double, edge: Int, hours: Double)?
                for i in r.indices.dropFirst() where r[i].value <= 40 && r[i].value < r[i - 1].value {
                    let before = r[i].time.timeIntervalSince(r[0].time) / 3600
                    let rest = end.timeIntervalSince(r[i].time) / 3600
                    let dropBefore = Double(r[0].value - r[i].value)
                    let dropAfter = Double(r[i].value - r.last!.value)
                    guard before > 0, rest > 0, dropBefore >= 5, dropAfter >= 5 else { continue }
                    let ratio = dropAfter / (dropBefore / before) / rest
                    if ratio > best?.ratio ?? 0 { best = (ratio, r[i].value, rest) }
                }
                let curve = best.map { $0.ratio >= 3 ? ChargeCurve(cliff: $0.edge, cliffHours: $0.hours) : .flat }
                latest = (end, curve ?? .flat)
            }
        }
        return latest?.curve ?? .flat
    }

    public static func drain(_ intervals: [DrainInterval]) -> [UsageState: StateDrain] {
        var out: [UsageState: StateDrain] = [:]
        for interval in intervals {
            out[interval.state, default: StateDrain()].add(interval)
        }
        return out
    }

    /// Every step down in level within one continuous connection, with the activity at the time.
    /// Unlike `intervals`, this counts partial steps at the edges and single-step sessions: it
    /// measures how much battery was used, not how fast.
    public static func observedDrops(_ samples: [Sample], channel: Channel) -> [(time: Date, state: UsageState, drop: Double)] {
        var out: [(Date, UsageState, Double)] = []
        var previous: (time: Date, value: Int, state: UsageState)?
        for sample in samples {
            if sample.isInCase(channel) {
                previous = nil
                continue
            }
            guard let value = sample.value(channel) else { continue }
            if let p = previous, continues(from: p.time, to: sample), value < p.value,
               !implausible(from: p.value, to: value, after: sample.time.timeIntervalSince(p.time)) {
                out.append((sample.time, p.state, Double(p.value - value)))
            }
            previous = (sample.time, value, sample.state)
        }
        return out
    }

    public static func totalDrop(_ samples: [Sample], channel: Channel) -> Double {
        observedDrops(samples, channel: channel).reduce(0) { $0 + $1.drop }
    }

    /// Hours spent connected in each state. Time in the charging case is left out: when the earbuds
    /// say both buds are in the case, or, for earbuds that don't report where the buds are, when a
    /// battery is charging and none is draining.
    public static func connectedHours(_ samples: [Sample]) -> [UsageState: Double] {
        var out: [UsageState: Double] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let knowsPlacement = a.placementLeft != nil || a.placementRight != nil
            guard continues(from: a.time, to: b), a.inCase != true,
                  knowsPlacement || !isCharging(from: a, to: b) else { continue }
            out[a.state, default: 0] += b.time.timeIntervalSince(a.time) / 3600
        }
        return out
    }

    /// Some battery went up and none went down. One bud charging while the other is in use still counts.
    static func isCharging(from a: Sample, to b: Sample) -> Bool {
        let changes = Channel.allCases.compactMap { ch -> Int? in
            guard let va = a.value(ch), let vb = b.value(ch) else { return nil }
            return vb - va
        }
        return changes.contains { $0 > 0 } && !changes.contains { $0 < 0 }
    }

    /// Ordinary least squares slope of y over x. Nil when fewer than 3 points or no spread in x.
    static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let mx = points.map(\.x).reduce(0, +) / n
        let my = points.map(\.y).reduce(0, +) / n
        let sxx = points.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = points.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +)
        return sxy / sxx
    }
}
