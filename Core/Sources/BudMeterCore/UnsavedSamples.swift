import Foundation

/// Readings that failed to save, kept in order and retried later, so a database hiccup doesn't lose
/// the end of a session even if the earbuds reconnect before the retry.
public struct UnsavedSamples {
    /// A reading plus the device details to save with it (nil for a session's last reading, whose
    /// device row already exists).
    public struct Item {
        public var sample: Sample
        public var device: (name: String, productID: Int?)?

        public init(_ sample: Sample, device: (name: String, productID: Int?)? = nil) {
            self.sample = sample
            self.device = device
        }
    }

    public private(set) var items: [Item] = []
    /// Oldest readings are dropped past this, so a database that never recovers can't grow memory forever.
    let limit: Int

    public init(limit: Int = 1000) {
        self.limit = limit
    }

    public mutating func add(_ item: Item) {
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    /// Saves queued readings oldest first and stops at the first failure. Returns that failure, if any.
    @discardableResult
    public mutating func retry(_ save: (Item) throws -> Void) -> Error? {
        while let first = items.first {
            do {
                try save(first)
                items.removeFirst()
            } catch {
                return error
            }
        }
        return nil
    }
}
