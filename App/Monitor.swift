import AppKit
import BudMeterCore
import Foundation
import Observation

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
    @ObservationIgnored private var lastWritten: [String: Sample] = [:]
    /// Latest reading that was not stored yet (unchanged since last write). Stored on disconnect / sleep
    /// so the end of a session is exact.
    @ObservationIgnored private var pending: [String: Sample] = [:]
    @ObservationIgnored private var connectedNow = Set<String>()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: Bluetooth.ConnectWatcher?
    @ObservationIgnored private let galaxy = GalaxyBuds()
    /// Keeps App Nap from stretching the poll timer, which would split sessions.
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Recording earbud battery levels")

    init() {
        do {
            store = try Store(path: Store.defaultPath())
        } catch {
            errorMessage = "Could not open the database: \(error)"
        }
        refreshAllReports()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Battery level usually arrives a few seconds after the connection, so look twice.
        watcher = Bluetooth.ConnectWatcher { [weak self] in
            for delay in [3.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.poll() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPending() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPending()
                self?.galaxy.disconnectAll()
            }
        }
    }

    func poll() {
        guard let store else { return }
        let now = Date()
        var changed = Set<String>()
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
            }
        }

        for device in live where device.isConnected && device.hasBattery {
            let state: UsageState = device.inputRunning ? .call : device.outputRunning ? .listening : .idle
            let sample = Sample(time: now, address: device.address, main: device.main, left: device.left,
                                right: device.right, caseLevel: device.caseLevel, state: state,
                                wearing: device.wearing, inCase: device.inCase)
            do {
                if let last = lastWritten[device.address], !sample.differs(from: last),
                   now.timeIntervalSince(last.time) < heartbeat {
                    pending[device.address] = sample
                } else {
                    try store.insert(sample)
                    try store.upsertDevice(address: device.address, name: device.name,
                                           productID: device.productID, seen: now)
                    lastWritten[device.address] = sample
                    pending[device.address] = nil
                    changed.insert(device.address)
                }
            } catch {
                errorMessage = "Could not save a reading: \(error)"
            }
        }

        // Devices that just disconnected: store their final reading.
        let wasConnected = connectedNow
        connectedNow = Set(live.filter { $0.isConnected && $0.hasBattery }.map(\.address))
        for address in lastWritten.keys where !connectedNow.contains(address) {
            if let sample = pending.removeValue(forKey: address) { try? store.insert(sample) }
            lastWritten[address] = nil
        }
        // Close the Samsung channel only on a real disconnect, not when battery briefly reads as unknown.
        let linked = Set(live.filter(\.isConnected).map(\.address))
        for address in wasConnected where !linked.contains(address) {
            galaxy.disconnect(address: address)
            changed.insert(address)
        }

        if !changed.isEmpty || wasConnected != connectedNow {
            refreshAllReports()
        }
    }

    func setRatedHours(_ hours: Double?, for address: String) {
        try? store?.setRatedHours(address: address, hours: hours)
        refreshAllReports()
    }

    private func flushPending() {
        for sample in pending.values { try? store?.insert(sample) }
        pending.removeAll()
        lastWritten.removeAll()
    }

    private func refreshAllReports() {
        guard let store else { return }
        do {
            let now = Date()
            reports = try store.devices().map { device in
                DeviceReport.build(device: device, samples: try store.samples(address: device.address),
                                   connected: connectedNow.contains(device.address), now: now)
            }
            .sorted { a, b in
                a.isConnected != b.isConnected ? a.isConnected : a.device.lastSeen > b.device.lastSeen
            }
        } catch {
            errorMessage = "Could not read history: \(error)"
        }
    }

    /// Samples for the battery history chart.
    func samples(for address: String, since: Date) -> [Sample] {
        (try? store?.samples(address: address, since: since)) ?? []
    }
}
