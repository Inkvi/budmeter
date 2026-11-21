import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle(isOn: $monitor.galaxyDetail) {
                Text("Read each Galaxy Bud separately")
                Text("Adds each bud's battery, the case and in-ear status. Turn off if Galaxy Wearable on your phone has trouble connecting.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}
