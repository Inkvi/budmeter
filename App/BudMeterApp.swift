import SwiftUI

extension Notification.Name {
    static let openDashboard = Notification.Name("openDashboard")
}

@main
struct BudMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("BudMeter", id: "dashboard") {
            DashboardView().environment(monitor)
        }
        .defaultSize(width: 1000, height: 780)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show the dashboard once on first launch so it's clear where the app lives.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) while it runs in the menu bar shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
        return true
    }
}
