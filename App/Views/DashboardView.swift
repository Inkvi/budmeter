import BudMeterCore
import SwiftUI

struct DashboardView: View {
    @Environment(Monitor.self) private var monitor
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(monitor.reports, id: \.device.address, selection: $selection) { report in
                HStack(spacing: 10) {
                    DeviceImage(device: report.device, size: 40)
                        .opacity(report.isConnected ? 1 : 0.75)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.device.name).lineLimit(1)
                        Text(sidebarSubtitle(report))
                            .font(.caption)
                            .foregroundStyle(report.health == nil ? .secondary : report.verdict.color)
                    }
                }
                .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let report = monitor.reports.first(where: { $0.device.address == selection }) {
                DeviceDetailView(report: report)
                    .id(report.device.address)
            } else {
                ContentUnavailableView("No earbuds yet", systemImage: "earbuds",
                                       description: Text("Connect a pair to your Mac. BudMeter records battery levels in the background."))
            }
        }
        .onAppear {
            selectDefault()
            // Show in the Dock while the dashboard is open.
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: monitor.reports.map(\.device.address)) { selectDefault() }
        .onChange(of: selection) { selectDefault() }
        .frame(minWidth: 820, minHeight: 600)
    }

    private func selectDefault() {
        if selection == nil || !monitor.reports.contains(where: { $0.device.address == selection }) {
            selection = monitor.reports.first?.device.address
        }
    }

    private func sidebarSubtitle(_ report: DeviceReport) -> String {
        if report.isConnected, let state = report.latest?.state { return "Connected · \(state.liveLabel)" }
        if let health = report.health { return "\(Format.percent(health)) health" }
        return report.verdict.title
    }
}
