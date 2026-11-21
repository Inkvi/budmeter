import Foundation

/// The product family a device belongs to, used to pick its picture. The raw value is the image's
/// file name in `design/devices`.
public enum EarbudModel: String, CaseIterable, Sendable {
    // Apple and Beats
    case airpods, airpodsPro = "airpods-pro", airpodsMax = "airpods-max"
    case beatsStudioBuds = "beats-studio-buds", beatsFitPro = "beats-fit-pro", powerbeatsPro = "powerbeats-pro"
    case beatsHeadphones = "beats-headphones"
    // Samsung and Google
    case galaxyBuds3 = "galaxy-buds3", galaxyBuds2 = "galaxy-buds2", galaxyBudsLive = "galaxy-buds-live"
    case galaxyBudsFE = "galaxy-buds-fe"
    case pixelBudsA = "pixel-buds-a", pixelBudsPro = "pixel-buds-pro", pixelBudsPro2 = "pixel-buds-pro2"
    // Sony
    case sonyWFXM5 = "sony-wf-1000xm5", sonyWFXM4 = "sony-wf-1000xm4", sonyLinkBuds = "sony-linkbuds"
    case sonyWHXM5 = "sony-wh-1000xm5", sonyWHXM4 = "sony-wh-1000xm4"
    // Nothing
    case nothingEar = "nothing-ear", cmfBuds = "cmf-buds", nothingHeadphone = "nothing-headphone"
    // Bose
    case boseQCEarbuds = "bose-qc-earbuds", boseUltraOpen = "bose-ultra-open", boseHeadphones = "bose-headphones"
    // Others
    case jabraElite = "jabra-elite", sennheiserMomentum = "sennheiser-momentum", oneplusBuds = "oneplus-buds"
    case soundcoreLiberty = "soundcore-liberty", shokzOpenRun = "shokz-openrun"
    case huaweiFreeBudsPro = "huawei-freebuds-pro"
    // Fallbacks
    case earbuds, headphones

    /// Image set name in the app's asset catalog.
    public var imageName: String { "device-\(rawValue)" }

    /// Apple and Beats devices report a product ID; their names often leave the model out.
    static let appleProductIDs: [Int: EarbudModel] = [
        0x2002: .airpods, 0x200F: .airpods, 0x2013: .airpods, 0x2019: .airpods, 0x201B: .airpods,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro, 0x2027: .airpodsPro,
        0x200A: .airpodsMax, 0x201F: .airpodsMax,
        0x2011: .beatsStudioBuds, 0x2016: .beatsStudioBuds, 0x2012: .beatsFitPro, 0x200B: .powerbeatsPro,
        0x2006: .beatsHeadphones, 0x2009: .beatsHeadphones, 0x200C: .beatsHeadphones, 0x2017: .beatsHeadphones,
    ]

    /// Lowercase name fragments, checked in order, so more specific ones come first.
    static let nameRules: [(String, EarbudModel)] = [
        // Samsung
        ("galaxy buds3", .galaxyBuds3), ("galaxy buds 3", .galaxyBuds3),
        ("galaxy buds live", .galaxyBudsLive),
        ("galaxy buds fe", .galaxyBudsFE), ("galaxy buds core", .galaxyBudsFE),
        ("galaxy buds", .galaxyBuds2),
        // Google
        ("pixel buds pro 2", .pixelBudsPro2), ("pixel buds pro", .pixelBudsPro), ("pixel buds", .pixelBudsA),
        // Apple and Beats
        ("airpods max", .airpodsMax), ("airpods pro", .airpodsPro), ("airpods", .airpods),
        ("beats studio buds", .beatsStudioBuds), ("beats solo buds", .beatsStudioBuds),
        ("beats fit", .beatsFitPro), ("powerbeats", .powerbeatsPro),
        ("beats studio", .beatsHeadphones), ("beats solo", .beatsHeadphones),
        ("beats", .beatsStudioBuds),
        // Sony
        ("linkbuds s", .sonyWFXM5), ("linkbuds fit", .sonyWFXM5), ("linkbuds", .sonyLinkBuds),
        ("wf-1000xm4", .sonyWFXM4), ("wf-1000xm3", .sonyWFXM4), ("wf-", .sonyWFXM5),
        ("wh-1000xm5", .sonyWHXM5), ("wh-1000xm6", .sonyWHXM5), ("wh-", .sonyWHXM4), ("ult wear", .sonyWHXM4),
        // Nothing
        ("nothing headphone", .nothingHeadphone), ("cmf", .cmfBuds),
        ("nothing ear", .nothingEar), ("ear (1)", .nothingEar), ("ear (2)", .nothingEar),
        ("ear (3)", .nothingEar), ("ear (a)", .nothingEar), ("ear (open)", .nothingEar),
        // Bose
        ("ultra open", .boseUltraOpen),
        ("qc ultra earbuds", .boseQCEarbuds), ("qc earbuds", .boseQCEarbuds),
        ("quietcomfort earbuds", .boseQCEarbuds), ("quietcomfort ultra earbuds", .boseQCEarbuds),
        ("sport earbuds", .boseQCEarbuds),
        ("bose", .boseHeadphones), ("qc35", .boseHeadphones), ("qc45", .boseHeadphones),
        ("quietcomfort", .boseHeadphones),
        // Others
        ("jabra", .jabraElite),
        ("momentum 4", .headphones), ("momentum", .sennheiserMomentum), ("sennheiser", .sennheiserMomentum),
        ("oneplus buds", .oneplusBuds), ("nord buds", .oneplusBuds),
        ("soundcore space", .headphones), ("soundcore life q", .headphones),
        ("soundcore", .soundcoreLiberty), ("liberty 4", .soundcoreLiberty),
        ("shokz", .shokzOpenRun), ("openrun", .shokzOpenRun), ("openmove", .shokzOpenRun),
        ("opencomm", .shokzOpenRun), ("aeropex", .shokzOpenRun),
        ("freebuds", .huaweiFreeBudsPro),
        // Fallbacks
        ("headphones", .headphones), ("earbuds", .earbuds), ("buds", .earbuds),
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
