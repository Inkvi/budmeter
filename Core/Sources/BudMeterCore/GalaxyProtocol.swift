import Foundation

/// Decoder for the status messages Samsung Galaxy Buds (Buds+ and later) send on their own serial channel.
///
/// Message format, as documented by the open source GalaxyBudsClient project and checked against
/// Galaxy Buds2 Pro:
///   0xFD | header (2 bytes, little endian, low 10 bits = size) | id | payload | crc16 (2) | 0xDD
public enum GalaxyProtocol {
    public struct Status: Equatable, Sendable {
        public var left: Int?
        public var right: Int?
        public var caseLevel: Int?
        /// Per bud: 0 = not connected, 1 = in ear, 2 = out of ear, 3 = in case.
        public var placementLeft: Int
        public var placementRight: Int

        public var wearing: Bool { placementLeft == 1 || placementRight == 1 }
    }

    /// Pulls complete messages off the front of `buffer`, leaving any partial message.
    public static func extractMessages(_ buffer: inout Data) -> [(id: UInt8, payload: Data)] {
        var out: [(UInt8, Data)] = []
        var bytes = [UInt8](buffer)
        while true {
            guard let start = bytes.firstIndex(of: 0xFD) else { bytes.removeAll(); break }
            if start > 0 { bytes.removeFirst(start) }
            guard bytes.count >= 3 else { break }
            let size = (Int(bytes[1]) | Int(bytes[2]) << 8) & 0x3FF
            let total = 3 + size + 1
            guard size >= 3 else { bytes.removeFirst(); continue }
            guard bytes.count >= total else { break }
            if bytes[total - 1] == 0xDD {
                out.append((bytes[3], Data(bytes[4..<(3 + size - 2)])))
                bytes.removeFirst(total)
            } else {
                bytes.removeFirst()  // lost sync; look for the next start byte
            }
        }
        buffer = Data(bytes)
        return out
    }

    public static func parse(id: UInt8, payload p: Data) -> Status? {
        let b = [UInt8](p)
        let offset: Int
        switch id {
        case 0x61 where b.count >= 8: offset = 2  // extended status: revision, ear type, then the fields below
        case 0x60 where b.count >= 7: offset = 1  // status update: revision, then the fields below
        default: return nil
        }
        // left, right, coupled, main connection, placement (left high nibble, right low), case
        let left = Int(b[offset]), right = Int(b[offset + 1])
        let placement = b[offset + 4]
        let caseLevel = Int(b[offset + 5])
        let pl = Int(placement >> 4), pr = Int(placement & 0x0F)
        guard left <= 100, right <= 100, caseLevel <= 100, pl <= 4, pr <= 4 else { return nil }
        // A bud that isn't connected to the other (placement 0) reports a stale level.
        return Status(left: pl == 0 || left == 0 ? nil : left, right: pr == 0 || right == 0 ? nil : right,
                      caseLevel: caseLevel == 0 ? nil : caseLevel, placementLeft: pl, placementRight: pr)
    }
}
