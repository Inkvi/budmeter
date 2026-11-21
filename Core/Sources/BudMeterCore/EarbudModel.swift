import Foundation

/// The product family a device belongs to, used to pick its picture.
public enum EarbudModel: String, CaseIterable, Sendable {
    case airpods, airpodsPro = "airpods-pro", airpodsMax = "airpods-max"
    case galaxyBuds3 = "galaxy-buds3", galaxyBuds2 = "galaxy-buds2"
    case pixelBudsA = "pixel-buds-a", pixelBudsPro = "pixel-buds-pro"
    case earbuds, headphones

    /// Image set name in the app's asset catalog.
    public var imageName: String { "device-\(rawValue)" }

    static let appleProductIDs: [Int: EarbudModel] = [
        0x2002: .airpods, 0x200F: .airpods, 0x2013: .airpods, 0x2019: .airpods, 0x201B: .airpods,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro, 0x2027: .airpodsPro,
        0x200A: .airpodsMax, 0x201F: .airpodsMax,
    ]

    /// Name fragments, most specific first.
    static let nameRules: [(String, EarbudModel)] = [
        ("galaxy buds3", .galaxyBuds3), ("galaxy buds 3", .galaxyBuds3),
        ("galaxy buds", .galaxyBuds2),
        ("pixel buds pro", .pixelBudsPro), ("pixel buds", .pixelBudsA),
        ("airpods max", .airpodsMax), ("airpods pro", .airpodsPro), ("airpods", .airpods),
        ("earbuds", .earbuds), ("buds", .earbuds),
        ("qc35", .headphones), ("qc45", .headphones), ("quietcomfort", .headphones),
        ("wh-1000", .headphones), ("headphones", .headphones), ("bose 700", .headphones),
    ]

    public static func detect(name: String, productID: Int?) -> EarbudModel {
        if let productID, let model = appleProductIDs[productID] { return model }
        let lower = name.lowercased()
        return nameRules.first { lower.contains($0.0) }?.1 ?? .earbuds
    }
}

extension Device {
    public var model: EarbudModel { EarbudModel.detect(name: name, productID: productID) }
}
