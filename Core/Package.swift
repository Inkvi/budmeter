// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudMeterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BudMeterCore", targets: ["BudMeterCore"]),
    ],
    targets: [
        .target(name: "BudMeterCore"),
        .testTarget(name: "BudMeterCoreTests", dependencies: ["BudMeterCore"]),
    ]
)
