// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Algorator",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlgoratorCore", targets: ["AlgoratorCore"]),
        .library(name: "AlgoratorEditor", targets: ["AlgoratorEditor"]),
    ],
    targets: [
        .target(name: "AlgoratorCore"),
        .target(name: "AlgoratorEditor", dependencies: ["AlgoratorCore"]),
        .executableTarget(name: "AlgoratorDemo", dependencies: ["AlgoratorCore", "AlgoratorEditor"]),
        .testTarget(name: "AlgoratorCoreTests", dependencies: ["AlgoratorCore"]),
        .testTarget(name: "AlgoratorEditorTests", dependencies: ["AlgoratorEditor"]),
    ]
)
