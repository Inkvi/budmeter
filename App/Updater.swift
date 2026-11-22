import AppKit
import Sparkle

/// Keeps BudMeter up to date. Sparkle checks the GitHub releases once a day and downloads a new
/// version in the background. Sparkle normally installs it when the app quits, but BudMeter rarely
/// quits, so it installs and relaunches right away instead, or when the dashboard closes if it's open.
final class Updater: NSObject {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func dashboardClosed() {
        installPending()
    }

    private func installPending() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        AppDelegate.allowQuit = true
        install()
    }

    private var dashboardIsOpen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("dashboard") == true && $0.isVisible }
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
