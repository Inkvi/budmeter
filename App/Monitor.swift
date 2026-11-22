import AppKit
import BudMeterCore
import Foundation
import Observation

/// Builds reports off the main thread with its own database connection.
actor ReportBuilder {
    private let store: Store

    init(path: String) throws {
        store = try Store(path: path)
    }

    /// Reports for the given devices, or for every device when `addresses` is nil.
    func reports(for addresses: Set<String>?, connected: Set<String>, now: Date) throws -> [DeviceReport] {
        try store.devices()
            .filter { addresses?.contains($0.address) ?? true }
            .map { device in
                DeviceReport.build(device: device, samples: try store.samples(address: device.address),
                                   connected: connected.contains(device.address), now: now)
            }
    }

    func samples(address: String, since: Date) throws -> [Sample] {
        try store.samples(address: address, since: since)
    }
}

/// Polls connected earbuds, records battery samples and keeps reports up to date.
@Observable
final class Monitor {
    private(set) var reports: [DeviceReport] = []
    private(set) var errorMessage: String?

    var connected: [DeviceReport] { reports.filter(\.isConnected) }

    /// Read per-bud battery and in-ear status from Galaxy Buds over Samsung's own channel.
    var galaxyDetail: Bool = UserDefaults.standard.object(forKey: "galaxyDetail") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(galaxyDetail, forKey: "galaxyDetail")
            if !galaxyDetail { galaxy.disconnectAll() }
            poll()
        }
    }

    /// How often we look at the earbuds.
    private let pollInterval: TimeInterval = 30
    /// Unchanged readings are still stored this often, so we know the device stayed connected.
    private let heartbeat: TimeInterval = 120

    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var builder: ReportBuilder?
    /// Last stored reading per device in the current session. No entry means the next reading starts
    /// a new session (after a connect, wake or app start).
    @ObservationIgnored private var lastWritten: [String: Sample] = [:]
    /// Latest reading that was not stored yet (unchanged since last write). Stored when the session
    /// ends so its end is exact.
    @ObservationIgnored private var pending: [String: Sample] = [:]
    /// Readings that failed to save; retried on every poll, before new ones.
    @ObservationIgnored private var unsaved = UnsavedSamples()
    @ObservationIgnored private var connectedNow = Set<String>()
    /// Connected devices without a battery level, so the log notes each one once.
    @ObservationIgnored private var noBattery = Set<String>()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var watcher: Bluetooth.ConnectWatcher?
    @ObservationIgnored private let galaxy = GalaxyBuds()
    /// Keeps App Nap from stretching the poll timer while earbuds are connected.
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// Guards against an older report build finishing after a newer one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appliedGeneration: [String: Int] = [:]

    init() {
        do {
            let path = try Store.defaultPath()
            store = try Store(path: path)
            builder = try ReportBuilder(path: path)
        } catch {
            errorMessage = "Could not open the database: \(error)"
        }
        refresh(nil)
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // "Last 7 days" and similar windows move even when nothing is recorded.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(nil) }
        }
        // Battery level usually arrives a few seconds after the connection, so look twice.
        watcher = Bluetooth.ConnectWatcher { [weak self] in
            for delay in [3.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.poll() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAllSessions() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endAllSessions()
                self?.galaxy.disconnectAll()
            }
        }
    }

    func poll() {
        guard let store else { return }
        let now = Date()
        var changed = Set<String>()
        let retryError = unsaved.retry { item in
            if let device = item.device {
                try store.record(item.sample, name: device.name, productID: device.productID)
            } else {
                try store.insert(item.sample)
            }
            changed.insert(item.sample.address)
        }
        if let retryError {
            errorMessage = "Could not save \(unsaved.items.count) readings: \(retryError)"
            log.error("Retry failed, \(self.unsaved.items.count) queued: \(String(describing: retryError), privacy: .public)")
        }
        var live = Bluetooth.scan()
        for i in live.indices where live[i].isConnected && GalaxyBuds.isGalaxyBuds(name: live[i].name) {
            guard galaxyDetail else { continue }
            galaxy.connect(address: live[i].address)
            if let status = galaxy.status[live[i].address] {
                live[i].left = status.left
                live[i].right = status.right
                live[i].caseLevel = status.caseLevel
                live[i].wearing = status.wearing
                live[i].inCase = status.inCase
                live[i].placementLeft = status.placementLeft
                live[i].placementRight = status.placementRight
            }
        }

        // A connected device that briefly reports no battery keeps its session; it just isn't recorded.
        for device in live where device.isConnected && device.hasBattery {
            let state: UsageState = device.inputRunning ? .call : device.outputRunning ? .listening : .idle
            let last = lastWritten[device.address]
            let sample = Sample(time: now, address: device.address, main: device.main, left: device.left,
                                right: device.right, caseLevel: device.caseLevel, state: state,
                                wearing: device.wearing, inCase: device.inCase, sessionStart: last == nil,
                                placementLeft: device.placementLeft, placementRight: device.placementRight)
            if let last, !sample.differs(from: last), now.timeIntervalSince(last.time) < heartbeat {
                pending[device.address] = sample
                continue
            }
            if unsaved.items.isEmpty {
                do {
                    try store.record(sample, name: device.name, productID: device.productID)
                    changed.insert(device.address)
                } catch {
                    unsaved.add(.init(sample, device: (device.name, device.productID)))
                    errorMessage = "Could not save a reading: \(error)"
                    log.error("Save failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                unsaved.add(.init(sample, device: (device.name, device.productID)))   // older readings wait first
            }
            lastWritten[device.address] = sample
            pending[device.address] = nil
        }

        let silent = Set(live.filter { $0.isConnected && !$0.hasBattery }.map(\.address))
        for device in live where silent.contains(device.address) && !noBattery.contains(device.address) {
            log.notice("\(device.name, privacy: .public) is connected but reports no battery level")
        }
        noBattery = silent

        // Devices that disconnected: end their session.
        let linked = Set(live.filter(\.isConnected).map(\.address))
        for address in Set(lastWritten.keys).union(pending.keys) where !linked.contains(address) {
            endSession(address)
            galaxy.disconnect(address: address)
        }

        let wasConnected = connectedNow
        connectedNow = Set(live.filter { $0.isConnected && $0.hasBattery }.map(\.address))
        changed.formUnion(wasConnected.symmetricDifference(connectedNow))
        updateActivity()
        if !changed.isEmpty { refresh(changed) }
    }

    func setRatedHours(_ hours: Double?, for address: String) {
        do {
            try store?.setRatedHours(address: address, hours: hours)
        } catch {
            errorMessage = "Could not save the rated time: \(error)"
        }
        refresh([address])
    }

    /// Rebuild everything, for example when the dashboard opens.
    func refreshAll() { refresh(nil) }

    /// Samples for the battery history chart, read off the main thread.
    func samples(for address: String, since: Date) async -> [Sample] {
        guard let builder else { return [] }
        do {
            return try await builder.samples(address: address, since: since)
        } catch {
            errorMessage = "Could not read history: \(error)"
            return []
        }
    }

    // MARK: Sessions

    /// Stores the session's last reading (if not stored yet) and makes the next reading start a new
    /// session. A reading that fails to save is queued and retried, even after a reconnect.
    private func endSession(_ address: String) {
        if let sample = pending.removeValue(forKey: address) {
            if !unsaved.items.isEmpty {
                unsaved.add(.init(sample))
            } else {
                do {
                    try store?.insert(sample)
                } catch {
                    unsaved.add(.init(sample))
                    errorMessage = "Could not save the last reading: \(error)"
                }
            }
        }
        lastWritten[address] = nil
    }

    private func endAllSessions() {
        for address in Set(lastWritten.keys).union(pending.keys) { endSession(address) }
    }

    private func updateActivity() {
        if connectedNow.isEmpty, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        } else if !connectedNow.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Recording earbud battery levels")
        }
    }

    // MARK: Reports

    private func refresh(_ addresses: Set<String>?) {
        guard let builder else { return }
        generation += 1
        let gen = generation
        let connected = connectedNow
        Task {
            do {
                let fresh = try await builder.reports(for: addresses, connected: connected, now: Date())
                apply(fresh, generation: gen, full: addresses == nil)
            } catch {
                errorMessage = "Could not read history: \(error)"
                log.error("Report failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func apply(_ fresh: [DeviceReport], generation gen: Int, full: Bool) {
        var byAddress = Dictionary(uniqueKeysWithValues: reports.map { ($0.device.address, $0) })
        if full {
            let present = Set(fresh.map(\.device.address))
            byAddress = byAddress.filter { present.contains($0.key) }
        }
        for report in fresh where gen >= appliedGeneration[report.device.address, default: 0] {
            byAddress[report.device.address] = report
            appliedGeneration[report.device.address] = gen
        }
        reports = byAddress.values.sorted { a, b in
            a.isConnected != b.isConnected ? a.isConnected : a.device.lastSeen > b.device.lastSeen
        }
    }
}
