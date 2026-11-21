import Foundation

/// What the earbuds were doing between two samples, as seen from the Mac.
public enum UsageState: String, CaseIterable, Sendable, Codable {
    /// Microphone is open (calls, meetings). Bluetooth switches to the headset profile.
    case call
    /// Audio stream to the earbuds is open (music, video, or an app holding the output).
    case listening
    /// Connected to the Mac, but no audio stream is open.
    case idle

    public var label: String {
        switch self {
        case .call: "Calls"
        case .listening: "Listening"
        case .idle: "Idle (connected)"
        }
    }
}

/// Which battery a value belongs to. Single-value headsets only report `.main`.
public enum Channel: String, CaseIterable, Sendable {
    case main, left, right

    public var label: String {
        switch self {
        case .main: "Earbuds"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// One observation of a connected device. Battery values are 1...100, nil when unknown.
public struct Sample: Sendable, Equatable {
    public var time: Date
    public var address: String
    public var main: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    public var state: UsageState
    /// At least one bud is in an ear. Only known for earbuds that report it (Galaxy Buds).
    public var wearing: Bool?

    public init(time: Date, address: String, main: Int? = nil, left: Int? = nil, right: Int? = nil,
                caseLevel: Int? = nil, state: UsageState, wearing: Bool? = nil) {
        self.time = time
        self.address = address
        self.main = main
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.state = state
        self.wearing = wearing
    }

    public func value(_ channel: Channel) -> Int? {
        switch channel {
        case .main: main
        case .left: left
        case .right: right
        }
    }

    /// True when battery, state or case changed compared to `other`.
    public func differs(from other: Sample) -> Bool {
        main != other.main || left != other.left || right != other.right
            || caseLevel != other.caseLevel || state != other.state || wearing != other.wearing
    }
}

/// A pair of earbuds or headphones we have seen at least once.
public struct Device: Sendable, Equatable, Identifiable {
    public var address: String
    public var name: String
    public var productID: Int?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Manufacturer-rated listening hours per charge. Nil means use the built-in table.
    public var ratedHoursOverride: Double?

    public var id: String { address }

    public init(address: String, name: String, productID: Int? = nil, firstSeen: Date, lastSeen: Date,
                ratedHoursOverride: Double? = nil) {
        self.address = address
        self.name = name
        self.productID = productID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.ratedHoursOverride = ratedHoursOverride
    }

    public var ratedHours: Double? {
        ratedHoursOverride ?? DeviceSpecs.ratedListeningHours(name: name, productID: productID)
    }
}
