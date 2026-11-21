import BudMeterCore
import Charts
import SwiftUI

struct DeviceDetailView: View {
    let report: DeviceReport
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HealthHero(report: report)
                if report.drain.values.contains(where: \.hasEnoughData) { PerChargeSection(report: report) }
                IdleSection(report: report)
                TrendSection(report: report)
                HistorySection(report: report)
                UsageSection(report: report)
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button { showInfo.toggle() } label: { Label("How it's measured", systemImage: "info.circle") }
                    .help("How BudMeter measures battery")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) { MethodInfo(report: report) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DeviceImage(device: report.device, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.device.name).font(.title2.bold())
                Group {
                    if report.isConnected, let state = report.latest?.state {
                        Text("Connected · \(state.liveLabel)")
                    } else {
                        Text("Last connected \(Format.ago(report.device.lastSeen))")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Building blocks

/// A big value with a short label under it. Details go in the tooltip, not on screen.
private struct Stat: View {
    let value: String?
    let label: String
    var dot: Color?
    /// Shown dimmed when the estimate is based on little data.
    var tentative = false
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(value == nil || tentative ? .secondary : .primary)
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }
}

private struct Section<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Section where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// Tooltip text for a drain estimate.
private func detail(_ d: StateDrain?) -> String? {
    guard let d, let rate = d.ratePerHour else {
        return d.map { "\(Format.hours($0.hours)) measured so far. Needs 30 minutes and a 5% drop." }
    }
    return "\(Format.rate(rate)) · measured over \(Format.hours(d.hours)) · \(d.confidence.rawValue) confidence"
}

// MARK: Health

/// The battery ring from the app icon, filled to the health percentage.
private struct HealthRing: View {
    let report: DeviceReport

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            if let health = report.health {
                Circle()
                    .trim(from: 0, to: min(health, 1))
                    .stroke(report.verdict.color.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.percent(health))
                    .font(.title2.bold().monospacedDigit())
            } else {
                Image(systemName: report.verdict.symbol).font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement()
        .accessibilityLabel(report.health.map { "Battery health \(Format.percent($0))" } ?? report.verdict.title)
    }
}

private struct HealthHero: View {
    let report: DeviceReport
    @State private var editingRating = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            HealthRing(report: report)
            VStack(alignment: .leading, spacing: 6) {
                if let hours = report.drain[.listening]?.fullChargeHours {
                    (Text(Format.hours(hours)).font(.title.bold()) + Text("  listening per charge").foregroundStyle(.secondary))
                } else {
                    Text("Collecting data").font(.title.bold())
                }
                HStack(spacing: 6) {
                    Button(report.device.ratedHours.map { "Rated \(Format.hours($0))" } ?? "Set rated time") {
                        editingRating = true
                    }
                    .buttonStyle(.link)
                    .help("Manufacturer's listening time per charge. Click to change.")
                    .popover(isPresented: $editingRating, arrowEdge: .bottom) { RatingEditor(device: report.device) }
                    if report.health != nil {
                        Text("·").foregroundStyle(.tertiary)
                        Text(report.verdict.title).foregroundStyle(report.verdict.color)
                    }
                    if let trend = report.listeningMinutesPerMonth, abs(trend) >= 5 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(trend < 0 ? "−" : "+")\(Int(abs(trend))) min a month").foregroundStyle(.secondary)
                    }
                }
                if let note { Text(note).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            if report.isConnected {
                VStack(alignment: .leading, spacing: 8) {
                    BatteryRows(report: report)
                    if let remaining = report.remainingHours {
                        Text("About \(Format.hours(remaining)) left").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One short line, only when there's something to act on.
    private var note: String? {
        switch report.verdict {
        case .collecting: return "Needs about 30 minutes of playback with this Mac."
        case .replace: return "Time to replace them."
        case .worn: return "Plan a replacement."
        default: break
        }
        if let diff = report.rightVsLeft, abs(diff) >= 0.1 {
            let ratio = diff > 0 ? diff : 1 / (1 + diff) - 1
            return "\(diff > 0 ? "Right" : "Left") bud drains \(Format.percent(ratio)) faster."
        }
        return nil
    }
}

private struct RatingEditor: View {
    @Environment(Monitor.self) private var monitor
    let device: Device
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Hours", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(save)
                Text("hours per charge")
            }
            Text("From the manufacturer, noise cancelling on.").font(.callout).foregroundStyle(.secondary)
            if device.ratedHoursOverride != nil {
                Button("Use built-in value") {
                    text = ""   // so closing the popover doesn't save the old value again
                    monitor.setRatedHours(nil, for: device.address)
                }
                .buttonStyle(.link)
            }
        }
        .padding(14)
        .onAppear { text = device.ratedHours.map { String(format: "%g", $0) } ?? "" }
        .onDisappear(perform: save)
    }

    /// Empty restores the built-in value; anything that isn't a plausible number of hours is ignored.
    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty {
            if device.ratedHoursOverride != nil { monitor.setRatedHours(nil, for: device.address) }
        } else if let value = Double(t), Device.ratedHoursRange.contains(value), value != device.ratedHours {
            monitor.setRatedHours(value, for: device.address)
        }
    }
}

// MARK: Per charge

private struct PerChargeSection: View {
    let report: DeviceReport

    var body: some View {
        Section(title: "Per charge") {
            HStack(alignment: .top, spacing: 16) {
                stat(.listening, "Listening")
                stat(.call, "Calls")
                stat(.idle, "Idle")
                Stat(value: report.mixed.fullChargeHours.map(Format.hours), label: "Your mix", dot: .purple,
                     tentative: report.mixed.confidence == .low,
                     help: detail(report.mixed).map { "Listening, calls and idle as you actually use them. \($0)" })
            }
        }
    }

    private func stat(_ state: UsageState, _ label: String) -> some View {
        let d = report.drain[state]
        return Stat(value: d?.fullChargeHours.map(Format.hours), label: label, dot: state.color,
                    tentative: d?.confidence == .low, help: detail(d))
    }
}

// MARK: Idle

private struct IdleSection: View {
    let report: DeviceReport

    var body: some View {
        let idle = report.drain[.idle]
        let listeningRate = report.drain[.listening]?.ratePerHour
        Section(title: "Idle drain") {
            if idle?.ratePerHour == nil {
                Text("Leave the earbuds connected with nothing playing and BudMeter will measure it.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Stat(value: report.idleShareOfDrain.map(Format.percent), label: "Of battery spent idle",
                         help: [report.mixBasisDays.map { "Last \($0) days." },
                                listeningRate.flatMap { l in idle.map { "Same as \(Format.hours($0.drop / l)) of listening." } },
                                idle?.ratePerHour.map { "Idle drain \(Format.rate($0))." }]
                            .compactMap { $0 }.joined(separator: " "))
                    if report.idleWorn != nil || report.idleNotWorn != nil {
                        Stat(value: report.idleWorn?.ratePerHour.map(Format.rate), label: "In ears", help: detail(report.idleWorn))
                        Stat(value: report.idleNotWorn?.ratePerHour.map(Format.rate), label: "Out of ears", help: detail(report.idleNotWorn))
                    } else {
                        Stat(value: Format.hours(report.connectedHoursLast7Days[.idle] ?? 0), label: "Idle this week")
                    }
                }
            }
        }
    }
}

// MARK: Trend

private struct TrendSection: View {
    let report: DeviceReport

    var body: some View {
        let points = report.trend.filter { $0.listeningHours != nil || $0.mixedHours != nil }
        if !points.isEmpty {
            Section(title: "Runtime per charge") {
                LegendItem(color: UsageState.listening.color, text: "Listening")
                LegendItem(color: .purple, text: "Your mix", dashed: true)
            } content: {
                Chart {
                    if let rated = report.device.ratedHours {
                        RuleMark(y: .value("Rated", rated))
                            .foregroundStyle(Color.gray)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Rated").font(.caption).foregroundStyle(.secondary)
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
                                     series: .value("Kind", "Your mix"))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        }
                    }
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)h") }
                } }
                .frame(height: 170)
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
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: Battery history

private struct HistorySection: View {
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
        Section(title: "Battery") {
            Picker("Range", selection: $range) {
                Text("Day").tag(1)
                Text("Week").tag(7)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if samples.isEmpty {
                Text("No readings yet.").foregroundStyle(.secondary)
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
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                } }
                .frame(height: 190)
                HStack(spacing: 16) {
                    ForEach(UsageState.allCases, id: \.self) { s in
                        LegendItem(color: s.color.opacity(0.5), text: s.label)
                    }
                    if samples.contains(where: { $0.right != nil }) {
                        LegendItem(color: .secondary, text: "Right bud", dashed: true)
                    }
                }
            }
        }
        .task(id: "\(range)-\(report.latest?.time.timeIntervalSince1970 ?? 0)") {
            // The window ends at the last reading, so pairs not used today still show their latest use.
            let end = report.latest?.time ?? Date()
            let loaded = await monitor.samples(for: report.device.address, since: end.addingTimeInterval(-Double(range) * 86400))
            if !Task.isCancelled { samples = loaded }   // a newer range may have replaced this load
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

    /// Battery lines: each bud where the reading has them, otherwise the single level. Each line breaks
    /// at its own gaps and at new sessions, so it never bridges time it has no data for.
    private var points: [Point] {
        var out: [Point] = []
        var segment: [Channel: Int] = [:]
        var previous: [Channel: Date] = [:]
        for s in samples {
            for ch in DeviceReport.displayChannels(s) {
                guard let v = s.value(ch) else { continue }
                if let p = previous[ch], !Analysis.continues(from: p, to: s) { segment[ch, default: 0] += 1 }
                previous[ch] = s.time
                out.append(Point(time: s.time, level: v, series: "\(ch.rawValue)-\(segment[ch, default: 0])", channel: ch))
            }
        }
        return out
    }
}

// MARK: Connected time

private struct UsageSection: View {
    let report: DeviceReport
    @State private var days = 7

    var body: some View {
        let hours = days == 7 ? report.connectedHoursLast7Days : report.connectedHoursLast30Days
        let total = hours.values.reduce(0, +)
        Section(title: "Connected time") {
            Picker("Range", selection: $days) {
                Text("Week").tag(7)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if total == 0 {
                Text("Not connected in this period.").foregroundStyle(.secondary)
            } else {
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
                HStack(spacing: 16) {
                    ForEach(UsageState.allCases, id: \.self) { s in
                        Stat(value: Format.hours(hours[s] ?? 0), label: s.label, dot: s.color)
                    }
                    Stat(value: Format.hours(total), label: "Total")
                }
            }
        }
    }
}

// MARK: Method info

private struct MethodInfo: View {
    let report: DeviceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it's measured").font(.headline)
            Text("BudMeter reads the battery every 30 seconds while the earbuds are connected to this Mac, and notes whether audio is playing, the microphone is on, or neither.")
            Text("Drain is measured from one battery step to the next, so earbuds that report in 10% steps aren't skewed. Charging, disconnects and sleep are left out. Health compares listening time per charge with the rated time.")
            Text("Use on your phone isn't counted. Hover over a number to see how much data it's based on.")
            Divider()
            Text("Tracked since \(report.device.firstSeen.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.1f", report.trackedCycles)) full charges used")
                .foregroundStyle(.secondary)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}
