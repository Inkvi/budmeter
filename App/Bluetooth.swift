import CoreAudio
import Foundation
import IOBluetooth

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
        var seen = Set<String>()
        var out: [LiveDevice] = []
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            guard isHeadset(device), let address = device.addressString?.lowercased(),
                  seen.insert(address).inserted else { continue }
            let state = audio[address]
            let pid = device.responds(to: NSSelectorFromString("productID"))
                ? (device.value(forKey: "productID") as? Int ?? 0) : 0
            out.append(LiveDevice(
                address: address,
                name: device.name ?? "Earbuds",
                productID: pid > 0 ? pid : nil,
                isConnected: device.isConnected() || state != nil,
                main: level(device, "batteryPercentSingle") ?? level(device, "batteryPercentCombined"),
                left: level(device, "batteryPercentLeft"),
                right: level(device, "batteryPercentRight"),
                caseLevel: level(device, "batteryPercentCase"),
                outputRunning: state?.output ?? false,
                inputRunning: state?.input ?? false))
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
    private static func level(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? Int,
              (1...100).contains(value) else { return nil }
        return value
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
