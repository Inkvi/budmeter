import BudMeterCore
import ServiceManagement
import SwiftUI

struct MenuBarLabel: View {
    let monitor: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lowest = monitor.connected.compactMap { report in
            report.channels.compactMap { report.latest?.value($0) }.min()
        }.min()
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.connected.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "earbuds").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("No earbuds connected").font(.headline)
                        Text("Connect a pair and BudMeter starts tracking.")
                            .font(.caption).foregroundStyle(.secondary)
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
                Text("Your earbuds").font(.caption).foregroundStyle(.secondary)
                ForEach(others, id: \.device.address) { report in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(report.device.name).lineLimit(1)
                            Text("Seen \(Format.ago(report.device.lastSeen))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VerdictPill(report: report)
                    }
                }
            }

            if let error = monitor.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("d")
                Spacer()
                Toggle("Open at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit BudMeter")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct LiveDeviceCard: View {
    let report: DeviceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.device.name).font(.headline).lineLimit(1)
                Spacer()
                if report.latest?.wearing == false {
                    Label("Not in ears", systemImage: "ear.trianglebadge.exclamationmark")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if let state = report.latest?.state { StateChip(state: state) }
            }
            BatteryRows(report: report)
            HStack {
                if let remaining = report.remainingHours {
                    Label("About \(Format.hours(remaining)) left", systemImage: "clock")
                } else {
                    Label("Learning how fast it drains…", systemImage: "clock")
                }
                Spacer()
                VerdictPill(report: report)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
