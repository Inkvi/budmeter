import BudMeterCore
import SwiftUI

enum Format {
    /// 0.75 -> "45m", 4.5 -> "4h 30m", 60 -> "2.5 days"
    static func hours(_ h: Double) -> String {
        if h >= 48 { return String(format: "%.1f days", h / 24) }
        let minutes = Int((h * 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let m = minutes % 60
        return m == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(m)m"
    }

    static func rate(_ r: Double) -> String {
        r < 10 ? String(format: "%.1f%%/h", r) : String(format: "%.0f%%/h", r)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension UsageState {
    var color: Color {
        switch self {
        case .call: .orange
        case .listening: .blue
        case .idle: .gray
        }
    }

    var symbol: String {
        switch self {
        case .call: "phone.fill"
        case .listening: "music.note"
        case .idle: "pause.circle"
        }
    }

    /// Short live description for the current state.
    var liveLabel: String {
        switch self {
        case .call: "On a call"
        case .listening: "Playing audio"
        case .idle: "Idle"
        }
    }
}

extension DeviceReport.Verdict {
    var color: Color {
        switch self {
        case .good: .green
        case .worn: .orange
        case .replace: .red
        case .collecting, .unknownRating: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.seal.fill"
        case .worn: "exclamationmark.triangle.fill"
        case .replace: "battery.0percent"
        case .collecting: "hourglass"
        case .unknownRating: "questionmark.circle"
        }
    }
}

struct VerdictPill: View {
    let report: DeviceReport

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: report.verdict.symbol)
            if let health = report.health {
                Text("\(Format.percent(health)) · \(report.verdict.title)")
            } else {
                Text(report.verdict.title)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(report.verdict.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(report.verdict.color.opacity(0.12), in: Capsule())
    }
}

struct StateChip: View {
    let state: UsageState

    var body: some View {
        Label(state.liveLabel, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.color)
    }
}

struct BatteryBar: View {
    let level: Int

    private var color: Color {
        level <= 15 ? .red : level <= 30 ? .orange : .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient)
                    .frame(width: max(geo.size.width * CGFloat(level) / 100, 4))
            }
        }
        .frame(height: 6)
    }
}

/// One battery row: "Left  [=====    ]  64%"
struct BatteryRow: View {
    let label: String
    let level: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            BatteryBar(level: level)
            Text("\(level)%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// Battery rows for every battery the latest sample reports.
struct BatteryRows: View {
    let report: DeviceReport

    var body: some View {
        if let latest = report.latest {
            VStack(spacing: 6) {
                ForEach(report.levels, id: \.channel) { item in
                    BatteryRow(label: item.channel.label, level: item.level)
                }
                if let level = latest.caseLevel {
                    BatteryRow(label: "Case", level: level)
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
