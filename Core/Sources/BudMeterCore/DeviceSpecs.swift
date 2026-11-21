import Foundation

/// Manufacturer-rated listening time per charge for the earbuds themselves (not counting the case).
/// Where noise cancelling exists, the rating with noise cancelling ON is used, since that is how
/// most people wear them. Users can override the number per device.
public enum DeviceSpecs {
    /// Apple product IDs. AirPods names rarely include the generation, so we match on product ID.
    static let appleProductIDs: [Int: Double] = [
        0x2002: 5,    // AirPods (1st gen)
        0x200F: 5,    // AirPods (2nd gen)
        0x2013: 6,    // AirPods (3rd gen)
        0x2019: 5,    // AirPods 4
        0x201B: 4,    // AirPods 4 with ANC
        0x200E: 4.5,  // AirPods Pro
        0x2014: 6,    // AirPods Pro 2 (Lightning)
        0x2024: 6,    // AirPods Pro 2 (USB-C)
        0x2027: 8,    // AirPods Pro 3
        0x200A: 20,   // AirPods Max
        0x201F: 20,   // AirPods Max (USB-C)
    ]

    /// Name fragments, most specific first.
    static let nameRules: [(String, Double)] = [
        ("galaxy buds3 pro", 6),
        ("galaxy buds3", 5),
        ("galaxy buds2 pro", 5),
        ("galaxy buds2", 5),
        ("galaxy buds fe", 6),
        ("galaxy buds pro", 5),
        ("galaxy buds live", 6),
        ("galaxy buds+", 11),
        ("galaxy buds", 6),
        ("pixel buds pro 2", 8),
        ("pixel buds pro", 7),
        ("pixel buds a-series", 5),
        ("pixel buds", 5),
        ("wf-1000xm5", 8),
        ("wf-1000xm4", 8),
        ("wh-1000xm5", 30),
        ("wh-1000xm4", 30),
        ("qc35", 20),
        ("quietcomfort ultra earbuds", 6),
        ("airpods pro", 6),
        ("airpods max", 20),
        ("airpods", 5),
        ("beats studio buds", 8),
        ("powerbeats pro", 9),
    ]

    public static func ratedListeningHours(name: String, productID: Int?) -> Double? {
        if let productID, let hours = appleProductIDs[productID] { return hours }
        let lower = name.lowercased()
        return nameRules.first { lower.contains($0.0) }?.1
    }
}
