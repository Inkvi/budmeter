import CoreAudio
import Foundation
import IOBluetooth
import os

let log = Logger(subsystem: "app.budmeter.BudMeter", category: "monitor")

/// A paired audio device as currently seen by the Mac.
struct LiveDevice {
    var address: String
    var name: String
    var productID: Int?
    var isConnected: Bool
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var outputRunning: Bool
    var inputRunning: Bool
    var wearing: Bool?
    var inCase: Bool?
    var placementLeft: Int?
    var placementRight: Int?

    var hasBattery: Bool { main != nil || left != nil || right != nil }
}

enum Bluetooth {
    /// Paired earbuds and headphones with their battery and audio state.
    ///
    /// Battery comes from IOBluetooth's battery properties. They are not public API, but they are what
    /// the macOS Bluetooth menu shows: per-bud and case levels for AirPods and Beats, and a single
    /// level for other headsets that report it over the hands-free profile (Galaxy Buds, Pixel Buds,
    /// Bose, Sony...). Audio state comes from CoreAudio: an open input means a call, an open output
    /// means audio is streaming.
    static func scan() -> [LiveDevice] {
        let audio = AudioDevices.bluetoothStates()
        var out: [LiveDevice] = []
        for device in headsets() {
            let address = device.addressString!.lowercased()
            let state = audio[address]
            let pid = device.responds(to: NSSelectorFromString("productID"))
                ? (device.value(forKey: "productID") as? Int ?? 0) : 0
            let battery = levels(device)
            out.append(LiveDevice(
                address: address,
                name: device.name ?? "Earbuds",
                productID: pid > 0 ? pid : nil,
                isConnected: device.isConnected() || state != nil,
                main: battery.main, left: battery.left, right: battery.right, caseLevel: battery.caseLevel,
                outputRunning: state?.output ?? false,
                inputRunning: state?.input ?? false))
        }
        // In a long-running process the device objects stop reporting battery after the first change
        // (they read 0, "unknown"), while a new process still gets the current level. So when a
        // connected headset has no level, ask a short-lived copy of the app.
        if out.contains(where: { $0.isConnected && !$0.hasBattery }) {
            let fresh = freshLevels()
            for i in out.indices where out[i].isConnected && !out[i].hasBattery {
                guard let b = fresh[out[i].address] else { continue }
                (out[i].main, out[i].left, out[i].right, out[i].caseLevel) = (b.main, b.left, b.right, b.caseLevel)
            }
        }
        return out
    }

    struct Levels {
        var main, left, right, caseLevel: Int?
    }

    private static func headsets() -> [IOBluetoothDevice] {
        var seen = Set<String>()
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter { device in
            guard isHeadset(device), let address = device.addressString?.lowercased() else { return false }
            return seen.insert(address).inserted
        }
    }

    private static func levels(_ device: IOBluetoothDevice) -> Levels {
        Levels(main: level(device, "batteryPercentSingle") ?? level(device, "batteryPercentCombined"),
               left: level(device, "batteryPercentLeft"), right: level(device, "batteryPercentRight"),
               caseLevel: level(device, "batteryPercentCase"))
    }

    /// For `BudMeter --battery`: one line per headset, "address main left right case", 0 for none.
    static func printLevels() {
        for device in headsets() {
            let b = levels(device)
            print(device.addressString!.lowercased(), b.main ?? 0, b.left ?? 0, b.right ?? 0, b.caseLevel ?? 0)
        }
    }

    /// Battery levels read by a new process (this app run with `--battery`). Gives up after 5 seconds.
    private static func freshLevels() -> [String: Levels] {
        guard let path = Bundle.main.executablePath else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--battery"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            log.error("Could not read battery levels: \(String(describing: error), privacy: .public)")
            return [:]
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            log.error("Reading battery levels timed out")
            return [:]
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var out: [String: Levels] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 5 else { continue }
            let n = f.dropFirst().map { Int($0).flatMap { $0 > 0 ? $0 : nil } }
            out[String(f[0])] = Levels(main: n[0], left: n[1], right: n[2], caseLevel: n[3])
        }
        return out
    }

    /// Audio/video major class with a headset, hands-free or headphones minor class.
    private static func isHeadset(_ device: IOBluetoothDevice) -> Bool {
        let cod = device.classOfDevice
        let major = (cod >> 8) & 0x1F
        let minor = (cod >> 2) & 0x3F
        return major == 0x04 && [0x01, 0x02, 0x06].contains(minor)
    }

    /// Reads a private battery property. 0 means "unknown" in IOBluetooth, so it maps to nil.
    /// macOS logs some Galaxy Buds levels as negative ("-16%"). The property is an unsigned byte, so
    /// that would read 240 here; it's decoded back to 16.
    private static func level(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? Int, value != 0 else { return nil }
        if (1...100).contains(value) { return value }
        if (156...255).contains(value) { return 256 - value }
        log.notice("Ignored \(key, privacy: .public) = \(value) for \(device.name ?? "?", privacy: .public)")
        return nil
    }

    /// Calls `handler` on the main thread whenever any Bluetooth device connects.
    final class ConnectWatcher: NSObject {
        private let handler: () -> Void
        private var notification: IOBluetoothUserNotification?

        init(handler: @escaping () -> Void) {
            self.handler = handler
            super.init()
            notification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                      selector: #selector(connected(_:device:)))
        }

        @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            handler()
        }
    }
}

enum AudioDevices {
    struct State {
        var output = false
        var input = false
    }

    /// Bluetooth audio devices keyed by lowercase Bluetooth address ("aa-bb-cc-dd-ee-ff").
    /// Their CoreAudio UIDs look like "AA-BB-CC-DD-EE-FF:output".
    static func bluetoothStates() -> [String: State] {
        var out: [String: State] = [:]
        for id in deviceIDs() {
            let transport = property(id, kAudioDevicePropertyTransportType, 0)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
            let address = String(uid.prefix { $0 != ":" }).lowercased()
            let running = property(id, kAudioDevicePropertyDeviceIsRunningSomewhere, 0)
            var state = out[address] ?? State()
            // macOS exposes a Bluetooth headset as separate ":input" and ":output" devices.
            let isInput = uid.hasSuffix(":input")
                || (!uid.hasSuffix(":output") && !hasStreams(id, scope: kAudioObjectPropertyScopeOutput))
            if isInput {
                state.input = state.input || running != 0
            } else {
                state.output = state.output || running != 0
            }
            out[address] = state
        }
        return out
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: UInt32) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = fallback
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
