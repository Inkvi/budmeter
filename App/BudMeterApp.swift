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
        .commands {
            // ⌘Q closes the dashboard; quitting for real happens from the menu bar icon.
            CommandGroup(replacing: .appTermination) {
                Button("Close Dashboard") { AppDelegate.closeDashboard() }
                    .keyboardShortcut("q")
            }
        }

        Settings {
            SettingsView().environment(monitor)
        }
    }
}

/// BudMeter lives in the menu bar. It shows in the Dock only while the dashboard is open, and quitting
/// from the Dock or with ⌘Q just closes the dashboard. Only the Quit button in the menu bar icon (or
/// logging out / shutting down) really quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar's Quit button.
    static var allowQuit = false

    static func quit() {
        allowQuit = true
        NSApp.terminate(nil)
    }

    /// Logout, restart and shutdown send a quit event with a reason. The SDK documents it as a
    /// parameter; older code reads it as an attribute, so check both.
    private static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let reason = event.paramDescriptor(forKeyword: kAEQuitReason) ?? event.attributeDescriptor(forKeyword: kAEQuitReason)
        return reason != nil
    }

    static func closeDashboard() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("dashboard") == true {
            window.close()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowQuit || Self.isSystemQuit() { return .terminateNow }
        Self.closeDashboard()
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer option for checking both appearances: BUDMETER_APPEARANCE=dark or light.
        switch ProcessInfo.processInfo.environment["BUDMETER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        _ = Updater.shared
        // Belt and braces: never block a shutdown or logout.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.allowQuit = true }
        }
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
