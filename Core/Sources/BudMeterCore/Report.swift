import Foundation

/// Everything the UI shows about one pair of earbuds.
public struct DeviceReport: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// Not enough listening data yet. `needHours` is a rough amount of extra listening required.
        case collecting(needHours: Double)
        /// No rated battery life known, so health can't be judged. User can enter it.
        case unknownRating
        case good
        case worn
        case replace

        public var title: String {
            switch self {
            case .collecting: "Collecting data"
            case .unknownRating: "Set rated hours"
            case .good: "Healthy"
            case .worn: "Worn"
            case .replace: "Replace soon"
            }
        }
    }

    public struct TrendPoint: Sendable, Identifiable {
        public var weekStart: Date
        /// Full-charge runtime while listening, if that week had enough listening data.
        public var listeningHours: Double?
        /// Full-charge runtime at that week's real mix of listening, calls and idle.
        public var mixedHours: Double?
        public var id: Date { weekStart }
    }

    public var device: Device
    public var latest: Sample?
    public var isConnected: Bool
    /// Batteries this device reports (main, or left + right).
    public var channels: [Channel]

    /// Window the headline numbers are based on (last 30 days if enough data, else all time).
    public var basisDays: Int?
    /// Drain per state for the worst battery (the one that dies first).
    public var drain: [UsageState: StateDrain]
    /// Drain per state for each battery, same window.
    public var drainByChannel: [Channel: [UsageState: StateDrain]]
    /// Drain across all states combined: how long a charge lasts with the user's real habits.
    public var mixed: StateDrain

    /// Idle drain split by whether the buds were in the ears. Only for earbuds that report wearing.
    public var idleWorn: StateDrain?
    public var idleNotWorn: StateDrain?
    /// Share of battery lost while connected but idle, in the same window. 0...1.
    public var idleShareOfDrain: Double?
    public var connectedHoursLast7Days: [UsageState: Double]
    public var connectedHoursLast30Days: [UsageState: Double]

    public var health: Double?
    public var verdict: Verdict
    public var trend: [TrendPoint]
    /// Change in full-charge listening runtime per 30 days, in minutes (negative = getting worse).
    public var listeningMinutesPerMonth: Double?
    /// How much faster the right bud drains than the left (0.2 = 20% faster). Nil without both.
    public var rightVsLeft: Double?
    /// Total battery drained while tracked, expressed as full 0-100% cycles.
    public var trackedCycles: Double
    /// Estimated hours left on the current charge at the current activity.
    public var remainingHours: Double?
}

extension DeviceReport {
    /// - Parameter connected: live connection state if known; otherwise inferred from the last sample.
    public static func build(device: Device, samples: [Sample], connected: Bool? = nil, now: Date = Date(),
                             calendar: Calendar = .current) -> DeviceReport {
        let latest = samples.last
        let isConnected = connected ?? latest.map { now.timeIntervalSince($0.time) <= Analysis.maxGap } ?? false
        // AirPods-style devices report each bud; plain headsets report one value.
        let hasBuds = samples.contains { $0.left != nil || $0.right != nil }
        let channels = (hasBuds ? [Channel.left, .right] : [.main])
            .filter { ch in samples.contains { $0.value(ch) != nil } }

        let intervalsByChannel = Dictionary(uniqueKeysWithValues: channels.map {
            ($0, Analysis.intervals(samples, channel: $0))
        })

        // Prefer the last 30 days so the numbers reflect the battery as it is now.
        let recentCutoff = now.addingTimeInterval(-30 * 86400)
        let recent = intervalsByChannel.mapValues { $0.filter { $0.start >= recentCutoff } }
        let recentListening = worst(recent.mapValues(Analysis.drain), .listening)
        let useRecent = recentListening.hasEnoughData && recentListening.drop >= 15
        let basis = useRecent ? recent : intervalsByChannel
        let basisDays: Int? = useRecent ? 30 : nil

        let drainByChannel = basis.mapValues(Analysis.drain)
        var drain: [UsageState: StateDrain] = [:]
        for state in UsageState.allCases {
            drain[state] = worst(drainByChannel, state)
        }
        let worstChannel = worstChannel(drainByChannel)
        let mixed = worstChannel.map { ch in
            (drainByChannel[ch] ?? [:]).values.reduce(StateDrain(), +)
        } ?? StateDrain()
        let idleShare: Double? = mixed.drop >= StateDrain.minDrop
            ? (worstChannel.flatMap { drainByChannel[$0]?[.idle]?.drop } ?? 0) / mixed.drop
            : nil

        // Idle split by wearing, for whichever battery drains fastest.
        func idleSplit(_ worn: Bool) -> StateDrain? {
            let byChannel = basis.values.map { list in
                list.filter { $0.state == .idle && $0.wearing == worn }.reduce(into: StateDrain()) { $0.add($1) }
            }
            return byChannel.filter { $0.hours > 0 }
                .max { ($0.ratePerHour ?? 0, $0.hours) < ($1.ratePerHour ?? 0, $1.hours) }
        }

        // Health: measured listening runtime against the manufacturer's rating.
        let listening = drain[.listening] ?? StateDrain()
        let health = both(listening.fullChargeHours, device.ratedHours).map { $0 / $1 }
        let verdict: Verdict
        if let health {
            verdict = health >= 0.8 ? .good : health >= 0.6 ? .worn : .replace
        } else if listening.hasEnoughData {
            verdict = .unknownRating
        } else {
            verdict = .collecting(needHours: max(StateDrain.minHours - listening.hours, 0.5))
        }

        // Weekly trend.
        let weekOf: (Date) -> Date = { calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0 }
        var weeks: [Date: [Channel: [DrainInterval]]] = [:]
        for (ch, list) in intervalsByChannel {
            for interval in list { weeks[weekOf(interval.start), default: [:]][ch, default: []].append(interval) }
        }
        let trend = weeks.keys.sorted().map { week -> TrendPoint in
            let byChannel = weeks[week]!.mapValues(Analysis.drain)
            let listening = worst(byChannel, .listening).fullChargeHours
            let mixedRate = byChannel.values.map { $0.values.reduce(StateDrain(), +) }
                .compactMap(\.ratePerHour).max()
            return TrendPoint(weekStart: week, listeningHours: listening, mixedHours: mixedRate.map { 100 / $0 })
        }
        let slopePoints = trend.compactMap { p in p.listeningHours.map { (x: p.weekStart.timeIntervalSince1970 / 86400, y: $0) } }
        let spanDays = (slopePoints.last?.x ?? 0) - (slopePoints.first?.x ?? 0)
        let minutesPerMonth = spanDays >= 21 ? Analysis.slope(slopePoints).map { $0 * 30 * 60 } : nil

        // Left vs right.
        var rightVsLeft: Double?
        if let l = drainByChannel[.left].map({ $0.values.reduce(StateDrain(), +) })?.ratePerHour,
           let r = drainByChannel[.right].map({ $0.values.reduce(StateDrain(), +) })?.ratePerHour, l > 0 {
            rightVsLeft = r / l - 1
        }

        // Cycles: average over the reported batteries.
        let totalDrops = intervalsByChannel.values.map { $0.reduce(0) { $0 + $1.drop } }
        let trackedCycles = totalDrops.isEmpty ? 0 : totalDrops.reduce(0, +) / Double(totalDrops.count) / 100

        // Time left now.
        var remaining: Double?
        if isConnected, let latest {
            let levels = channels.compactMap { ch in latest.value(ch).map { (ch, $0) } }
            if let (ch, level) = levels.min(by: { $0.1 < $1.1 }) {
                let byState = drainByChannel[ch] ?? [:]
                let rate = byState[latest.state]?.ratePerHour ?? drain[latest.state]?.ratePerHour ?? mixed.ratePerHour
                remaining = rate.map { Double(level) / $0 }
            }
        }

        let last7 = samples.filter { $0.time >= now.addingTimeInterval(-7 * 86400) }
        let last30 = samples.filter { $0.time >= recentCutoff }

        return DeviceReport(
            device: device, latest: latest, isConnected: isConnected, channels: channels,
            basisDays: basisDays, drain: drain, drainByChannel: drainByChannel, mixed: mixed,
            idleWorn: idleSplit(true), idleNotWorn: idleSplit(false), idleShareOfDrain: idleShare,
            connectedHoursLast7Days: Analysis.connectedHours(last7),
            connectedHoursLast30Days: Analysis.connectedHours(last30),
            health: health, verdict: verdict, trend: trend, listeningMinutesPerMonth: minutesPerMonth,
            rightVsLeft: rightVsLeft, trackedCycles: trackedCycles, remainingHours: remaining)
    }

    /// The drain for `state` on whichever battery loses charge fastest in that state.
    private static func worst(_ byChannel: [Channel: [UsageState: StateDrain]], _ state: UsageState) -> StateDrain {
        let candidates = byChannel.values.compactMap { $0[state] }
        return candidates.filter(\.hasEnoughData).max { ($0.ratePerHour ?? 0) < ($1.ratePerHour ?? 0) }
            ?? candidates.max { $0.hours < $1.hours }
            ?? StateDrain()
    }

    /// The battery with the highest overall drain rate.
    private static func worstChannel(_ byChannel: [Channel: [UsageState: StateDrain]]) -> Channel? {
        byChannel.max { a, b in
            let ra = a.value.values.reduce(StateDrain(), +)
            let rb = b.value.values.reduce(StateDrain(), +)
            return (ra.ratePerHour ?? -1, ra.hours) < (rb.ratePerHour ?? -1, rb.hours)
        }?.key
    }
}

private func both(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}
