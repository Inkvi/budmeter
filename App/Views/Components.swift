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
        guard fraction.isFinite else { return "—" }
        return "\(Int(min(max(fraction * 100, -9999), 9999).rounded()))%"
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

    /// Height of this activity in the battery chart's activity row (in battery-scale points). Calls are
    /// a bit taller so they don't depend on color alone.
    var stripHeight: Int {
        switch self {
        case .call: 12
        case .listening, .idle: 8
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

    /// For text. System green, orange and red are too light for text on light backgrounds (about 2:1),
    /// so text uses darker variants in light mode and lighter ones in dark mode, all 4.6:1 or better
    /// on cards and on the pill tint. Fills such as the ring and dots keep `color`.
    var textColor: Color {
        switch self {
        case .good: Color(light: 0x1E7B34, dark: 0x4ADE80)
        case .worn: Color(light: 0xA64A00, dark: 0xFFB86B)
        case .replace: Color(light: 0xC0281C, dark: 0xFFA099)
        case .collecting, .unknownRating: .secondaryText
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
        .foregroundStyle(report.verdict.textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(report.verdict.color.opacity(0.12), in: Capsule())
    }
}

struct StateChip: View {
    let state: UsageState

    var body: some View {
        // Colored icon, secondary text: blue and orange text would be under 3.5:1 on light backgrounds.
        Label {
            Text(state.liveLabel).foregroundStyle(Color.secondaryText)
        } icon: {
            Image(systemName: state.symbol).foregroundStyle(state.color)
        }
        .font(.caption.weight(.medium))
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
                    .frame(width: level > 0 ? max(geo.size.width * CGFloat(level) / 100, 4) : 0)
            }
        }
        .frame(height: 6)
    }
}

/// One battery row: "Left  [=====    ]  64%"
struct BatteryRow: View {
    let label: String
    let level: Int
    var inCase = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
                .frame(width: 52, alignment: .leading)
            BatteryBar(level: level)
            Text("\(level)%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(Color.secondaryText)
                .opacity(inCase ? 1 : 0)
                .help("In the case")
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
                    BatteryRow(label: item.channel.label, level: item.level, inCase: latest.isInCase(item.channel))
                }
                if let level = latest.caseLevel {
                    BatteryRow(label: "Case", level: level)
                }
            }
        }
    }
}

/// Product picture for a device (Galaxy Buds3, AirPods Pro, ...).
struct DeviceImage: View {
    let device: Device
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Just the product, like macOS Bluetooth settings. In light mode a faint shadow gives white
        // earbuds an edge against light backgrounds; dark mode doesn't need it.
        Image(device.model.imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.28), radius: max(1, size * 0.025), y: size * 0.012)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// A color with separate light and dark appearance values, given as 0xRRGGBB.
    init(light: Int, dark: Int) {
        func ns(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

extension Color {
    /// Secondary text for small labels. The system secondary label is about 3.9:1 on light cards;
    /// this is 5.6:1 in light mode (darker still with Increase Contrast) and the system color in dark.
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .aqua: NSColor(white: 0.40, alpha: 1)
        case .accessibilityHighContrastAqua: NSColor(white: 0.28, alpha: 1)
        default: .secondaryLabelColor
        }
    })
}
