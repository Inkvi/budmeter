import Foundation

/// A stretch of time between two samples where the battery was measurably discharging.
public struct DrainInterval: Sendable, Equatable {
    public var start: Date
    public var hours: Double
    /// Percentage points lost during the interval.
    public var drop: Double
    public var state: UsageState
    public var wearing: Bool?
}

/// Battery lost over a period of time in one usage state.
public struct StateDrain: Sendable, Equatable {
    public var hours: Double
    public var drop: Double

    public init(hours: Double = 0, drop: Double = 0) {
        self.hours = hours
        self.drop = drop
    }

    /// Minimum evidence before we trust a rate.
    public static let minHours = 0.5
    public static let minDrop = 5.0

    public var hasEnoughData: Bool { hours >= Self.minHours && drop >= Self.minDrop }
    /// Percent per hour, nil until there is enough data.
    public var ratePerHour: Double? { hasEnoughData ? drop / hours : nil }
    /// How long a full 100% charge lasts at this rate.
    public var fullChargeHours: Double? { ratePerHour.map { 100 / $0 } }

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
        StateDrain(hours: a.hours + b.hours, drop: a.drop + b.drop)
    }
}

public enum Confidence: String, Sendable {
    case low, medium, high
}

public enum Analysis {
    /// Samples further apart than this are treated as a disconnect (or Mac asleep).
    public static let maxGap: TimeInterval = 6 * 60

    /// Turn raw samples into discharge intervals for one battery.
    ///
    /// Headsets report battery in steps (often 10%, sometimes 1%). Measuring from an arbitrary
    /// point would mix in an unknown part of a step, so within each continuous discharge run we
    /// only count time from the first observed step down to the last observed step down. That
    /// makes the measurement exact regardless of step size, and it also drops the flat time
    /// spent in the charging case before the level starts rising.
    ///
    /// A run ends on: a gap (disconnect / sleep), a rise in level (charging), a missing value,
    /// or an implausible jump (a bud swapped or reset).
    public static func intervals(_ samples: [Sample], channel: Channel) -> [DrainInterval] {
        var out: [DrainInterval] = []
        var run: [(time: Date, value: Int, state: UsageState, wearing: Bool?)] = []

        func flush() {
            defer { run.removeAll() }
            let steps = run.indices.dropFirst().filter { run[$0].value < run[$0 - 1].value }
            guard let first = steps.first, let last = steps.last, first < last else { return }
            for i in first..<last {
                let hours = run[i + 1].time.timeIntervalSince(run[i].time) / 3600
                let drop = Double(run[i].value - run[i + 1].value)
                out.append(DrainInterval(start: run[i].time, hours: hours, drop: drop, state: run[i].state,
                                         wearing: run[i].wearing))
            }
        }

        for sample in samples {
            guard let value = sample.value(channel) else {
                flush()
                continue
            }
            if let prev = run.last {
                let gap = sample.time.timeIntervalSince(prev.time)
                let jump = prev.value - value
                let implausible = jump >= 15 && gap < 15 * 60
                if gap > maxGap || value > prev.value || implausible {
                    flush()
                }
            }
            run.append((sample.time, value, sample.state, sample.wearing))
        }
        flush()
        return out
    }

    public static func drain(_ intervals: [DrainInterval]) -> [UsageState: StateDrain] {
        var out: [UsageState: StateDrain] = [:]
        for interval in intervals {
            out[interval.state, default: StateDrain()].add(interval)
        }
        return out
    }

    /// Hours spent connected in each state, regardless of battery data.
    public static func connectedHours(_ samples: [Sample]) -> [UsageState: Double] {
        var out: [UsageState: Double] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let gap = b.time.timeIntervalSince(a.time)
            if gap <= maxGap { out[a.state, default: 0] += gap / 3600 }
        }
        return out
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
