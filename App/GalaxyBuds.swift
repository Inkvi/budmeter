import BudMeterCore
import Foundation
import IOBluetooth

/// Reads per-bud battery, case battery and in-ear status from Samsung Galaxy Buds.
///
/// The standard hands-free profile only gives one number for the whole pair. Galaxy Buds (Buds+ and
/// later) also expose Samsung's own serial channel (the one the Galaxy Wearable app uses). Right after
/// it opens, the buds send an "extended status" message, and then a "status" message whenever battery
/// or placement changes. We only listen; nothing is ever written to the buds.
final class GalaxyBuds: NSObject, IOBluetoothRFCOMMChannelDelegate {
    typealias Status = GalaxyProtocol.Status

    private(set) var status: [String: Status] = [:]
    private var channels: [String: IOBluetoothRFCOMMChannel] = [:]
    private var buffers: [String: Data] = [:]
    private var lastAttempt: [String: Date] = [:]

    static func isGalaxyBuds(name: String) -> Bool {
        name.lowercased().contains("galaxy buds")
    }

    /// Opens the channel if it isn't open. Retries at most every 5 minutes.
    func connect(address: String) {
        guard channels[address] == nil,
              Date().timeIntervalSince(lastAttempt[address] ?? .distantPast) > 300,
              let device = IOBluetoothDevice(addressString: address),
              let channelID = Self.channelID(device) else { return }
        lastAttempt[address] = Date()
        var channel: IOBluetoothRFCOMMChannel?
        if device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self) == kIOReturnSuccess,
           let channel {
            channels[address] = channel
            // The buds don't always answer (for example while the phone's app holds the channel).
            // Give up after a while; `connect` retries later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.channels[address] === channel, !channel.isOpen() else { return }
                self.channels[address] = nil
                channel.close()
            }
        }
    }

    func disconnect(address: String) {
        lastAttempt[address] = nil
        channels.removeValue(forKey: address)?.close()
        status[address] = nil
        buffers[address] = nil
    }

    func disconnectAll() {
        for address in Array(channels.keys) { disconnect(address: address) }
        lastAttempt.removeAll()
    }

    /// The "GEARMANAGER" service from the cached service list.
    private static func channelID(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            var id: BluetoothRFCOMMChannelID = 0
            if record.getServiceName() == "GEARMANAGER", record.getRFCOMMChannelID(&id) == kIOReturnSuccess {
                return id
            }
        }
        return nil
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        guard let address = rfcommChannel.getDevice()?.addressString?.lowercased() else { return }
        var buffer = buffers[address, default: Data()]
        buffer.append(Data(bytes: dataPointer, count: dataLength))
        for (id, payload) in GalaxyProtocol.extractMessages(&buffer) {
            if let s = GalaxyProtocol.parse(id: id, payload: payload) { status[address] = s }
        }
        buffers[address] = buffer.count > 65536 ? Data() : buffer
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard let address = rfcommChannel.getDevice()?.addressString?.lowercased() else { return }
        channels[address] = nil
        status[address] = nil
        buffers[address] = nil
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error != kIOReturnSuccess { rfcommChannelClosed(rfcommChannel) }
    }
}
