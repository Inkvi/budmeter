import AppKit
import Sparkle

/// Keeps BudMeter up to date. Sparkle checks the GitHub releases once a day and downloads a new
/// version in the background. Sparkle normally installs it when the app quits, but BudMeter rarely
/// quits, so it installs and relaunches right away instead, or when the dashboard closes if it's open.
/// Only release builds have a feed URL; local builds never update.
final class Updater: NSObject {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    static let isEnabled = !(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "").isEmpty

    func checkForUpdates() {
        // A downloaded update waiting for the dashboard to close blocks new checks, so install it now.
        if pendingInstall != nil { installPending() } else { controller.checkForUpdates(nil) }
    }

    func dashboardClosed() {
        installPending()
    }

    private func installPending() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    private var dashboardIsOpen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("dashboard") == true && ($0.isVisible || $0.isMiniaturized) }
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallationBlock
        if !dashboardIsOpen { installPending() }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        AppDelegate.allowQuit = true
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    /// Updates install silently, so Sparkle only shows a window when someone clicks Check for Updates
    /// or an update can't install on its own. A menu bar app shouldn't jump in front for that, which is
    /// what declaring gentle reminders asks of Sparkle.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
