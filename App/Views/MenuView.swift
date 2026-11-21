import BudMeterCore
import SwiftUI

struct MenuBarLabel: View {
    let monitor: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lowest = monitor.connected.compactMap { $0.levels.map(\.level).min() }.min()
        HStack(spacing: 3) {
            Image(systemName: "earbuds")
            if let lowest { Text("\(lowest)%") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.connected.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "earbuds").font(.title2).foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading) {
                        Text("No earbuds connected").font(.headline)
                        Text("Connect a pair and BudMeter starts tracking.")
                            .font(.caption).foregroundStyle(Color.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(monitor.connected, id: \.device.address) { report in
                    LiveDeviceCard(report: report)
                }
            }

            let others = monitor.reports.filter { !$0.isConnected }
            if !others.isEmpty {
                Divider()
                ForEach(others, id: \.device.address) { report in
                    HStack {
                        DeviceImage(device: report.device, size: 26)
                        Text(report.device.name).lineLimit(1)
                        Spacer()
                        VerdictPill(report: report)
                    }
                    .help("Last connected \(Format.ago(report.device.lastSeen))")
                }
            }

            if let error = monitor.errorMessage {
                Text(error).font(.caption).foregroundStyle(DeviceReport.Verdict.replace.textColor)
            }

            Divider()
            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("d")
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button {
                    AppDelegate.quit()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit BudMeter")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct LiveDeviceCard: View {
    let report: DeviceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DeviceImage(device: report.device, size: 34)
                Text(report.device.name).font(.headline).lineLimit(1)
                Spacer()
                if report.latest?.inCase == true {
                    Label("In case", systemImage: "bolt.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Color.secondaryText)
                } else if report.latest?.wearing == false {
                    Label("Not in ears", systemImage: "ear.trianglebadge.exclamationmark")
                        .font(.caption.weight(.medium)).foregroundStyle(Color.secondaryText)
                }
                if let state = report.latest?.state { StateChip(state: state) }
            }
            BatteryRows(report: report)
            HStack {
                if let remaining = report.remainingHours {
                    Text("About \(Format.hours(remaining)) left")
                }
                Spacer()
                VerdictPill(report: report)
            }
            .font(.callout)
            .foregroundStyle(Color.secondaryText)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
