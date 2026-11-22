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

    /// Window the listening and health numbers are based on (last 30 days if enough data, else all time).
    /// Other activities pick their own window the same way.
    public var basisDays: Int?
    /// Drain per state for the worst battery (the one that dies first).
    public var drain: [UsageState: StateDrain]
    /// Drain per state for each battery, same window.
    public var drainByChannel: [Channel: [UsageState: StateDrain]]
    /// Drain across all states combined: how long a charge lasts with the user's real habits.
    public var mixed: StateDrain
    /// Window for `mixed` and `idleShareOfDrain` (30 when based on the last 30 days, nil for all time).
    public var mixBasisDays: Int?

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
    /// Level below which the battery that dies first drains at least twice as fast as average.
    public var fastDrainBelow: Int?
}

extension DeviceReport {
    /// - Parameter connected: live connection state if known; otherwise inferred from the last sample.
    public static func build(device: Device, samples: [Sample], connected: Bool? = nil, now: Date = Date(),
                             calendar: Calendar = .current) -> DeviceReport {
        let latest = samples.last
        let isConnected = connected ?? latest.map { now.timeIntervalSince($0.time) <= Analysis.maxGap } ?? false
        // Analyze every battery that has data. Galaxy Buds report one level for the pair (always) and
        // each bud (when Samsung's channel is available), so they get all three series.
        let channels = Channel.allCases.filter { ch in samples.contains { $0.value(ch) != nil } }
        let all = Dictionary(uniqueKeysWithValues: channels.map { ($0, Analysis.intervals(samples, channel: $0)) })
        // The shape of the charge comes from all history: the steep end is only seen when the
        // earbuds are used until they die, which is rare.
        let curves = all.mapValues(Analysis.chargeCurve)
        func shaped(_ byChannel: [Channel: [UsageState: StateDrain]]) -> [Channel: [UsageState: StateDrain]] {
            Dictionary(uniqueKeysWithValues: byChannel.map { ch, byState in
                (ch, byState.mapValues { d in
                    var d = d
                    d.usable = curves[ch]?.usable ?? 1
                    return d
                })
            })
        }

        // Prefer the last 30 days so the numbers reflect the battery as it is now, but only for an
        // activity that has enough recent data. Otherwise fall back to all tracked history.
        let recentCutoff = now.addingTimeInterval(-30 * 86400)
        let recent = all.mapValues { $0.filter { $0.start >= recentCutoff } }
        let recentDrain = shaped(recent.mapValues(Analysis.drain))
        let allDrain = shaped(all.mapValues(Analysis.drain))
        func useRecent(_ d: StateDrain) -> Bool { d.hasEnoughData && d.drop >= 15 }

        var drainByChannel: [Channel: [UsageState: StateDrain]] = [:]
        var recentStates = Set<UsageState>()
        for state in UsageState.allCases {
            let recentForState = useRecent(worst(recentDrain, state))
            if recentForState { recentStates.insert(state) }
            for (ch, byState) in recentForState ? recentDrain : allDrain {
                drainByChannel[ch, default: [:]][state] = byState[state]
            }
        }
        var drain: [UsageState: StateDrain] = [:]
        for state in UsageState.allCases {
            drain[state] = worst(drainByChannel, state)
        }
        let basisDays: Int? = recentStates.contains(.listening) ? 30 : nil

        // Real-mix runtime and idle share come from one window so the shares add up.
        let recentMixed = worstChannel(recentDrain).map { total(recentDrain[$0]) } ?? StateDrain()
        let mixRecent = useRecent(recentMixed)
        let mixSource = mixRecent ? recentDrain : allDrain
        let mixChannel = worstChannel(mixSource)
        let mixed = mixChannel.map { total(mixSource[$0]) } ?? StateDrain()
        // Share of battery spent idle counts every observed drop, including sessions too short to
        // measure a rate, in the same window as the real mix.
        let shareChannel = mixChannel ?? channels.first
        let drops = shareChannel.map { Analysis.observedDrops(samples, channel: $0) }?
            .filter { !mixRecent || $0.time >= recentCutoff } ?? []
        let droppedTotal = drops.reduce(0) { $0 + $1.drop }
        let idleShare: Double? = droppedTotal >= StateDrain.minDrop
            ? drops.filter { $0.state == .idle }.reduce(0) { $0 + $1.drop } / droppedTotal
            : nil

        // Idle split by wearing, for whichever battery drains fastest.
        let idleSource = recentStates.contains(.idle) ? recent : all
        func idleSplit(_ worn: Bool) -> StateDrain? {
            let byChannel = idleSource.mapValues { list in
                [UsageState.idle: list.filter { $0.state == .idle && $0.wearing == worn }
                    .reduce(into: StateDrain()) { $0.add($1) }]
            }
            let d = worst(byChannel, .idle)
            return d.hours > 0 ? d : nil
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
        for (ch, list) in all {
            for interval in list { weeks[weekOf(interval.start), default: [:]][ch, default: []].append(interval) }
        }
        let trend = weeks.keys.sorted().map { week -> TrendPoint in
            let byChannel = shaped(weeks[week]!.mapValues(Analysis.drain))
            let listening = worst(byChannel, .listening).fullChargeHours
            let mixedHours = worstChannel(byChannel).flatMap { total(byChannel[$0]).fullChargeHours }
            return TrendPoint(weekStart: week, listeningHours: listening, mixedHours: mixedHours)
        }
        let slopePoints = trend.compactMap { p in p.listeningHours.map { (x: p.weekStart.timeIntervalSince1970 / 86400, y: $0) } }
        let spanDays = (slopePoints.last?.x ?? 0) - (slopePoints.first?.x ?? 0)
        let minutesPerMonth = spanDays >= 21 ? Analysis.slope(slopePoints).map { $0 * 30 * 60 } : nil

        // Left vs right, compared within the same activity so that, say, calls on one bud only
        // don't look like a weaker battery. Uses the activity with the most data on both buds.
        var rightVsLeft: Double?
        let paired = UsageState.allCases.compactMap { state -> (l: StateDrain, r: StateDrain)? in
            guard let l = drainByChannel[.left]?[state], let r = drainByChannel[.right]?[state],
                  l.hasEnoughData, r.hasEnoughData else { return nil }
            return (l, r)
        }
        if let best = paired.max(by: { min($0.l.drop, $0.r.drop) < min($1.l.drop, $1.r.drop) }),
           let l = best.l.ratePerHour, let r = best.r.ratePerHour, l > 0 {
            rightVsLeft = r / l - 1
        }

        // Full charges used: every step down while connected, for the most used battery.
        let trackedCycles = (channels.map { Analysis.totalDrop(samples, channel: $0) }.max() ?? 0) / 100

        // Time left now: whichever battery runs out first at its own rate.
        var remaining: Double?
        if isConnected, let latest {
            remaining = displayChannels(latest).compactMap { ch -> Double? in
                guard let level = latest.value(ch), !latest.isInCase(ch) else { return nil }
                // Skip a bud that is charging (level went up since its previous reading).
                if let previous = samples.dropLast().last(where: { $0.value(ch) != nil })?.value(ch),
                   level > previous { return nil }
                let rate = drainByChannel[ch]?[latest.state]?.ratePerHour
                    ?? drain[latest.state]?.ratePerHour ?? mixed.ratePerHour
                return rate.map { (curves[ch] ?? .flat).hoursLeft(from: Double(level), rate: $0) }
            }.min()
        }

        let last7 = samples.filter { $0.time >= now.addingTimeInterval(-7 * 86400) }
        let last30 = samples.filter { $0.time >= recentCutoff }

        return DeviceReport(
            device: device, latest: latest, isConnected: isConnected, channels: channels,
            basisDays: basisDays, drain: drain, drainByChannel: drainByChannel, mixed: mixed,
            mixBasisDays: mixRecent ? 30 : nil,
            idleWorn: idleSplit(true), idleNotWorn: idleSplit(false), idleShareOfDrain: idleShare,
            connectedHoursLast7Days: Analysis.connectedHours(last7),
            connectedHoursLast30Days: Analysis.connectedHours(last30),
            health: health, verdict: verdict, trend: trend, listeningMinutesPerMonth: minutesPerMonth,
            rightVsLeft: rightVsLeft, trackedCycles: trackedCycles, remainingHours: remaining,
            fastDrainBelow: curves.values.compactMap(\.fastBelow).max())
    }

    /// Batteries shown to the user: each bud when the latest reading has them, else the single level.
    public static func displayChannels(_ sample: Sample) -> [Channel] {
        sample.left != nil || sample.right != nil ? [.left, .right].filter { sample.value($0) != nil } : [.main]
    }

    /// Battery levels to show now.
    public var levels: [(channel: Channel, level: Int)] {
        guard let latest else { return [] }
        return Self.displayChannels(latest).compactMap { ch in latest.value(ch).map { (ch, $0) } }
    }

    /// The drain for `state` on whichever battery loses charge fastest in that state. Only batteries
    /// with comparable evidence compete, so half an hour on one bud can't outweigh days on the other.
    private static func worst(_ byChannel: [Channel: [UsageState: StateDrain]], _ state: UsageState) -> StateDrain {
        let candidates = byChannel.values.compactMap { $0[state] }
        return fastest(candidates) ?? candidates.max { $0.hours < $1.hours } ?? StateDrain()
    }

    /// The battery with the highest overall drain rate, among those with comparable evidence.
    private static func worstChannel(_ byChannel: [Channel: [UsageState: StateDrain]]) -> Channel? {
        let totals = byChannel.mapValues { total($0) }
        if let best = fastest(Array(totals.values)) {
            return totals.first { $0.value == best }?.key
        }
        return totals.max { $0.value.hours < $1.value.hours }?.key
    }

    private static func fastest(_ candidates: [StateDrain]) -> StateDrain? {
        let enough = candidates.filter(\.hasEnoughData)
        let maxDrop = enough.map(\.drop).max() ?? 0
        return enough.filter { $0.drop >= 0.25 * maxDrop }.max { ($0.ratePerHour ?? 0) < ($1.ratePerHour ?? 0) }
    }

    private static func total(_ byState: [UsageState: StateDrain]?) -> StateDrain {
        (byState ?? [:]).values.reduce(StateDrain(), +)
    }
}

private func both(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}
