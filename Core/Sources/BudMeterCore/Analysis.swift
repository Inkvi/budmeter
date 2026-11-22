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

    /// Share of a straight-line full charge the battery really delivers (see `ChargeCurve.usable`).
    public var usable: Double

    public init(hours: Double = 0, drop: Double = 0, usable: Double = 1) {
        self.hours = hours
        self.drop = drop
        self.usable = usable
    }

    /// Minimum evidence before we trust a rate.
    public static let minHours = 0.5
    public static let minDrop = 5.0

    public var hasEnoughData: Bool { hours >= Self.minHours && drop >= Self.minDrop }
    /// Percent per hour, nil until there is enough data.
    public var ratePerHour: Double? { hasEnoughData ? drop / hours : nil }
    /// How long a full 100% charge lasts at this rate, following the battery's charge curve.
    public var fullChargeHours: Double? { ratePerHour.map { 100 / $0 * usable } }

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
        StateDrain(hours: a.hours + b.hours, drop: a.drop + b.drop, usable: min(a.usable, b.usable))
    }
}

/// How fast each tenth of the charge drains compared with the battery's average.
///
/// A worn battery often reads normally down to some level and then collapses: the last quarter can
/// go in ten minutes. Projecting the rate from the middle of the charge in a straight line to 0%
/// misses that, so full-charge and time-left estimates follow this curve instead.
public struct ChargeCurve: Sendable, Equatable {
    /// Relative drain speed for 0-10%, 10-20%, ... 90-100%. 2 means twice as fast as average.
    public var speed: [Double]

    public static let flat = ChargeCurve(speed: Array(repeating: 1, count: 10))

    /// Share of a straight-line full charge the battery really lasts. 1 when it drains evenly.
    public var usable: Double { speed.reduce(0) { $0 + 1 / $1 } / 10 }

    /// Hours from `level` down to 0% when the battery drains at `rate` percent per hour on average.
    public func hoursLeft(from level: Double, rate: Double) -> Double {
        (0..<10).reduce(0) { sum, band in
            sum + min(max(level - Double(band * 10), 0), 10) / (rate * speed[band])
        }
    }

    /// The level below which the battery drains at least twice as fast as average, if it does.
    public var fastBelow: Int? {
        speed.prefix(5).lastIndex { $0 >= 2 }.map { ($0 + 1) * 10 }
    }
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
    /// (charging), this bud going into the case, or an implausible jump. A sample without a value for this
    /// battery is skipped, not a break: headsets sometimes report nothing for a moment.
    ///
    /// Each step-to-step span is one measurement: we know its total drop, not when inside it the
    /// battery fell. When a span mixes activities, its drop is shared between them in proportion to
    /// how fast each activity drains, estimated from all spans together (see `attribute`).
    public static func intervals(_ samples: [Sample], channel: Channel) -> [DrainInterval] {
        var spans: [Span] = []
        var run: [(time: Date, value: Int, state: UsageState, wearing: Bool?)] = []

        func flush() {
            defer { run.removeAll() }
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

        for sample in samples {
            if sample.isInCase(channel) {
                flush()
                continue
            }
            guard let value = sample.value(channel) else { continue }
            if let prev = run.last {
                let gap = sample.time.timeIntervalSince(prev.time)
                if !continues(from: prev.time, to: sample) || value > prev.value
                    || implausible(from: prev.value, to: value, after: gap) {
                    flush()
                }
            }
            run.append((sample.time, value, sample.state, sample.wearing))
        }
        flush()
        return attribute(spans)
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

    /// The charge curve measured from `intervals`: in each tenth of the charge, the battery actually
    /// lost compared with what each activity's average rate predicts for the time spent there.
    /// A tenth with less than `StateDrain.minDrop` measured copies the nearest measured tenth above it
    /// (or below, at the top): the steep part is at the bottom, so gaps are more like the charge above.
    public static func chargeCurve(_ intervals: [DrainInterval]) -> ChargeCurve {
        let rates = drain(intervals).mapValues { $0.hours > 0 ? $0.drop / $0.hours : 0 }
        var actual = [Double](repeating: 0, count: 10), expected = actual
        for interval in intervals {
            let band = min(max(Int(interval.level / 10), 0), 9)
            actual[band] += interval.drop
            expected[band] += (rates[interval.state] ?? 0) * interval.hours
        }
        let measured = (0..<10).map { band -> Double? in
            actual[band] >= StateDrain.minDrop && expected[band] > 0 ? actual[band] / expected[band] : nil
        }
        guard measured.contains(where: { $0 != nil }) else { return .flat }
        return ChargeCurve(speed: measured.indices.map { band in
            measured[band] ?? measured[(band + 1)...].lazy.compactMap { $0 }.first
                ?? measured[..<band].reversed().lazy.compactMap { $0 }.first!
        })
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
