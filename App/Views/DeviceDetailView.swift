import BudMeterCore
import Charts
import SwiftUI

struct DeviceDetailView: View {
    let report: DeviceReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    HealthCard(report: report)
                    if report.isConnected {
                        Card(title: "Right now") {
                            BatteryRows(report: report)
                            if let remaining = report.remainingHours {
                                Text("About **\(Format.hours(remaining))** left at the current activity.")
                                    .font(.callout)
                            } else {
                                Text("Time left appears once BudMeter has seen the battery drop a few times.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 280)
                    }
                }
                RuntimeCard(report: report)
                IdleCard(report: report)
                TrendCard(report: report)
                HistoryCard(report: report)
                UsageCard(report: report)
                if report.rightVsLeft != nil { LeftRightCard(report: report) }
                if GalaxyBuds.isGalaxyBuds(name: report.device.name) { GalaxySettingCard() }
                footer
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.device.name).font(.title2.bold())
                Group {
                    if report.isConnected, let state = report.latest?.state {
                        Text("Connected · \(state.liveLabel)")
                    } else {
                        Text("Last connected \(Format.ago(report.device.lastSeen))")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VerdictPill(report: report)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tracked since \(report.device.firstSeen.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.1f", report.trackedCycles)) full charges used while connected to this Mac.")
            Text("BudMeter only sees time connected to this Mac. Drain is measured between battery steps, so the numbers stay accurate even when the earbuds report battery in 10% steps. Time spent charging, disconnected or with the Mac asleep is left out.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Health

private struct HealthCard: View {
    @Environment(Monitor.self) private var monitor
    let report: DeviceReport
    @State private var ratedText = ""

    var body: some View {
        Card(title: "Battery health", subtitle: report.basisDays.map { "Based on the last \($0) days" } ?? "Based on all tracked use") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let health = report.health {
                    Text(Format.percent(health))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(report.verdict.color)
                } else {
                    Image(systemName: report.verdict.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let hours = report.drain[.listening]?.fullChargeHours {
                        Text("Lasts about **\(Format.hours(hours))** of listening per charge")
                    }
                    if let rated = report.device.ratedHours {
                        Text("Rated \(Format.hours(rated)) when new").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            Text(advice).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let trend = report.listeningMinutesPerMonth {
                Label(trend < -5 ? "Losing about \(Int(-trend)) min of listening time per month"
                      : trend > 5 ? "Runtime improved recently (likely lighter use)"
                      : "Runtime has been stable",
                      systemImage: trend < -5 ? "chart.line.downtrend.xyaxis" : "chart.line.flattrend.xyaxis")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Rated listening time:").font(.caption).foregroundStyle(.secondary)
                TextField("hours", text: $ratedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .font(.caption)
                    .onSubmit(saveRated)
                Text("h").font(.caption).foregroundStyle(.secondary)
                if report.device.ratedHoursOverride != nil {
                    Button("Reset") {
                        monitor.setRatedHours(nil, for: report.device.address)
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
        .onAppear(perform: syncRated)
        .onChange(of: report.device.ratedHours) { syncRated() }
    }

    private var advice: String {
        switch report.verdict {
        case .good:
            "The battery is in good shape."
        case .worn:
            "Noticeably shorter than new. Fine for now, but plan for a replacement."
        case .replace:
            "Lasting under 60% of the rated time. Time to replace them, or have the batteries serviced."
        case .collecting:
            "Keep using them with your Mac. A first estimate needs about 30 minutes of playback and a few percent of battery drop."
        case .unknownRating:
            "Enter the manufacturer's rated listening time below to see battery health."
        }
    }

    private func syncRated() {
        ratedText = report.device.ratedHours.map { String(format: "%g", $0) } ?? ""
    }

    private func saveRated() {
        let value = Double(ratedText.replacingOccurrences(of: ",", with: "."))
        monitor.setRatedHours(value.flatMap { $0 > 0 ? $0 : nil }, for: report.device.address)
    }
}

// MARK: Runtime per activity

private struct RuntimeCard: View {
    let report: DeviceReport

    var body: some View {
        Card(title: "How long a full charge lasts", subtitle: "Measured from real drain, for the bud that runs out first") {
            HStack(spacing: 12) {
                RuntimeTile(title: "Listening", symbol: UsageState.listening.symbol, color: UsageState.listening.color,
                            drain: report.drain[.listening])
                RuntimeTile(title: "Calls", symbol: UsageState.call.symbol, color: UsageState.call.color,
                            drain: report.drain[.call])
                RuntimeTile(title: "Idle", symbol: UsageState.idle.symbol, color: UsageState.idle.color,
                            drain: report.drain[.idle])
                RuntimeTile(title: "Your real mix", symbol: "person.fill", color: .purple, drain: report.mixed)
            }
        }
    }
}

private struct RuntimeTile: View {
    let title: String
    let symbol: String
    let color: Color
    let drain: StateDrain?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            if let drain, let hours = drain.fullChargeHours, let rate = drain.ratePerHour {
                Text(Format.hours(hours)).font(.title2.bold().monospacedDigit())
                Text("\(Format.rate(rate)) · \(Format.hours(drain.hours)) measured")
                    .font(.caption).foregroundStyle(.secondary)
                ConfidenceDots(confidence: drain.confidence)
            } else {
                Text("—").font(.title2.bold()).foregroundStyle(.tertiary)
                Text(drain.flatMap { $0.hours >= 1.0 / 60 ? "\(Format.hours($0.hours)) measured so far" : nil } ?? "No data yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConfidenceDots: View {
    let confidence: Confidence

    var body: some View {
        let filled = confidence == .high ? 3 : confidence == .medium ? 2 : 1
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(i < filled ? Color.primary.opacity(0.6) : Color.primary.opacity(0.12))
                    .frame(width: 5, height: 5)
            }
            Text("\(confidence.rawValue) confidence").font(.caption2).foregroundStyle(.secondary)
        }
        .help("Based on how much battery drop has been observed: low under 15%, medium under 40%, high above.")
    }
}

// MARK: Idle drain

private struct IdleCard: View {
    let report: DeviceReport

    var body: some View {
        let idle = report.drain[.idle]
        let listeningRate = report.drain[.listening]?.ratePerHour
        let idleHours7 = report.connectedHoursLast7Days[.idle] ?? 0
        Card(title: "Idle drain", subtitle: "Connected to the Mac with no audio playing") {
            if let idle, let rate = idle.ratePerHour {
                VStack(alignment: .leading, spacing: 8) {
                    Text("While idle, the battery drops **\(Format.rate(rate))**. Left connected and silent, a full charge would be gone in about **\(Format.hours(100 / rate))**.")
                    if let listeningRate, listeningRate > 0 {
                        Text("That is \(Format.percent(rate / listeningRate)) of the drain while listening.")
                    }
                    if let share = report.idleShareOfDrain, share > 0.01 {
                        let cost = listeningRate.map { idle.drop / $0 }
                        let period = report.basisDays.map { "In the last \($0) days, idle" } ?? "Idle"
                        Text("\(period) time used **\(Format.percent(share))** of all battery spent\(cost.map { ", the same as \(Format.hours($0)) of listening" } ?? "").")
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(idle.flatMap { $0.hours >= 1.0 / 60 ? "\(Format.hours($0.hours)) of idle time measured so far. An idle estimate needs at least 30 minutes and a 5% drop, which can take a few hours of idle time." : nil }
                     ?? "No idle time recorded yet. Leave the earbuds connected without audio and BudMeter will measure how much they drain.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.idleWorn != nil || report.idleNotWorn != nil {
                HStack(spacing: 12) {
                    IdleSplitTile(title: "In your ears", symbol: "ear", drain: report.idleWorn)
                    IdleSplitTile(title: "Out of your ears, still connected", symbol: "rectangle.portrait.on.rectangle.portrait.slash",
                                  drain: report.idleNotWorn)
                }
            }
            if idleHours7 > 0 {
                Text("Idle connected time in the last 7 days: \(Format.hours(idleHours7))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IdleSplitTile: View {
    let title: String
    let symbol: String
    let drain: StateDrain?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let drain, let rate = drain.ratePerHour {
                Text(Format.rate(rate)).font(.title3.bold().monospacedDigit())
                Text("Full charge gone in \(Format.hours(100 / rate)) · \(Format.hours(drain.hours)) measured")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.title3.bold()).foregroundStyle(.tertiary)
                Text(drain.map { "\(Format.hours($0.hours)) measured so far" } ?? "No data yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Trend

private struct TrendCard: View {
    let report: DeviceReport

    var body: some View {
        let points = report.trend.filter { $0.listeningHours != nil || $0.mixedHours != nil }
        Card(title: "Runtime over time", subtitle: "Full-charge runtime, week by week") {
            if points.isEmpty {
                Text("A weekly trend appears once there is enough data for a week.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    if let rated = report.device.ratedHours {
                        RuleMark(y: .value("Rated", rated))
                            .foregroundStyle(Color.gray)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Rated \(Format.hours(rated))").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    ForEach(points) { p in
                        if let h = p.listeningHours {
                            LineMark(x: .value("Week", p.weekStart, unit: .weekOfYear), y: .value("Hours", h),
                                     series: .value("Kind", "Listening"))
                                .foregroundStyle(UsageState.listening.color)
                            PointMark(x: .value("Week", p.weekStart, unit: .weekOfYear), y: .value("Hours", h))
                                .foregroundStyle(UsageState.listening.color)
                        }
                        if let h = p.mixedHours {
                            LineMark(x: .value("Week", p.weekStart, unit: .weekOfYear), y: .value("Hours", h),
                                     series: .value("Kind", "Real mix"))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        }
                    }
                }
                .chartYAxisLabel("hours per charge")
                .frame(height: 180)
                HStack(spacing: 16) {
                    LegendItem(color: UsageState.listening.color, text: "Listening")
                    LegendItem(color: .purple, text: "Your real mix", dashed: true)
                }
            }
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 5))
                    p.addLine(to: CGPoint(x: 14, y: 5))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                .frame(width: 14, height: 10)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Battery history

private struct HistoryCard: View {
    @Environment(Monitor.self) private var monitor
    let report: DeviceReport
    @State private var range = 1
    @State private var samples: [Sample] = []

    private struct Band: Identifiable {
        var start: Date
        var end: Date
        var state: UsageState
        var id: Date { start }
    }

    private struct Point: Identifiable {
        var time: Date
        var level: Int
        var series: String
        var channel: Channel
        var id: String { "\(series)-\(time.timeIntervalSince1970)" }
    }

    var body: some View {
        Card(title: "Battery history", subtitle: report.isConnected ? nil : report.latest.map { "Up to the last reading, \(Format.ago($0.time))" }) {
            Picker("Range", selection: $range) {
                Text("24 hours").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if samples.isEmpty {
                Text("No readings yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(bands) { band in
                        RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end),
                                      yStart: .value("Low", 0), yEnd: .value("High", 100))
                            .foregroundStyle(band.state.color.opacity(0.18))
                    }
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.time), y: .value("Battery", p.level),
                                 series: .value("Series", p.series))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: p.channel == .right ? [4, 3] : []))
                            .interpolationMethod(.stepEnd)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                } }
                .frame(height: 200)
                HStack(spacing: 16) {
                    ForEach(UsageState.allCases, id: \.self) { s in
                        LegendItem(color: s.color.opacity(0.5), text: s.label)
                    }
                    if report.channels.contains(.right) {
                        Text("solid: left · dashed: right").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: "\(range)-\(report.latest?.time.timeIntervalSince1970 ?? 0)") {
            // Window ends at the last reading, so pairs not used today still show their latest use.
            let end = report.latest?.time ?? Date()
            samples = monitor.samples(for: report.device.address, since: end.addingTimeInterval(-Double(range) * 86400))
        }
    }

    /// Background bands showing what the earbuds were doing, merged across same-state samples.
    private var bands: [Band] {
        var out: [Band] = []
        for (a, b) in zip(samples, samples.dropFirst()) where b.time.timeIntervalSince(a.time) <= Analysis.maxGap {
            if var last = out.last, last.state == a.state, last.end == a.time {
                last.end = b.time
                out[out.count - 1] = last
            } else {
                out.append(Band(start: a.time, end: b.time, state: a.state))
            }
        }
        return out
    }

    /// Battery lines, broken into separate series at disconnects so they don't bridge gaps.
    private var points: [Point] {
        var out: [Point] = []
        var segment = 0
        var previous: Date?
        for s in samples {
            if let previous, s.time.timeIntervalSince(previous) > Analysis.maxGap { segment += 1 }
            previous = s.time
            for ch in report.channels {
                if let v = s.value(ch) {
                    out.append(Point(time: s.time, level: v, series: "\(ch.rawValue)-\(segment)", channel: ch))
                }
            }
        }
        return out
    }
}

// MARK: Usage

private struct UsageCard: View {
    let report: DeviceReport

    var body: some View {
        Card(title: "Time connected to this Mac") {
            VStack(alignment: .leading, spacing: 12) {
                UsageBar(title: "Last 7 days", hours: report.connectedHoursLast7Days)
                UsageBar(title: "Last 30 days", hours: report.connectedHoursLast30Days)
            }
        }
    }
}

private struct UsageBar: View {
    let title: String
    let hours: [UsageState: Double]

    var body: some View {
        let total = hours.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(Format.hours(total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(UsageState.allCases, id: \.self) { s in
                            let h = hours[s] ?? 0
                            if h > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(s.color.gradient)
                                    .frame(width: max(geo.size.width * h / total - 2, 3))
                            }
                        }
                    }
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    ForEach(UsageState.allCases, id: \.self) { s in
                        if let h = hours[s], h > 0 {
                            LegendItem(color: s.color, text: "\(s.label) \(Format.hours(h))")
                        }
                    }
                }
            }
        }
    }
}

// MARK: Galaxy Buds

private struct GalaxySettingCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Card(title: "Galaxy Buds details") {
            Toggle("Read each bud's battery, the case and in-ear status", isOn: $monitor.galaxyDetail)
            Text("Uses Samsung's own Bluetooth channel, the one the Galaxy Wearable app uses. BudMeter only listens. Turn this off if your phone's Galaxy Wearable app has trouble connecting while the buds are paired to the Mac; you'll still get one battery level for the pair.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Left vs right

private struct LeftRightCard: View {
    let report: DeviceReport

    var body: some View {
        let diff = report.rightVsLeft ?? 0
        let worse = diff > 0 ? "right" : "left"
        let ratio = diff > 0 ? diff : (1 / (1 + diff) - 1)
        Card(title: "Left vs right") {
            if abs(diff) < 0.1 {
                Text("Both buds drain at about the same rate.").font(.callout)
            } else {
                Text("The **\(worse)** bud drains **\(Format.percent(ratio)) faster**. Uneven drain usually means that bud's battery has worn more, or it is the one handling the microphone.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 24) {
                ForEach([Channel.left, .right], id: \.self) { ch in
                    let mix = (report.drainByChannel[ch] ?? [:]).values.reduce(StateDrain(), +)
                    VStack(alignment: .leading) {
                        Text(ch.label).font(.caption).foregroundStyle(.secondary)
                        Text(mix.fullChargeHours.map(Format.hours) ?? "—").font(.title3.bold())
                    }
                }
            }
        }
    }
}
