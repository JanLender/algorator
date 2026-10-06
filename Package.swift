// swift-tools-version:5.9
import PackageDescription

// Complete strict-concurrency checking for the library, while staying on tools 5.9 and the Swift 5 language
// mode so that consumers on 5.9 can still load the package. The library must build without concurrency warnings.
let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "Algorator",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlgoratorCore", targets: ["AlgoratorCore"]),
        .library(name: "AlgoratorEditor", targets: ["AlgoratorEditor"]),
    ],
    targets: [
        .target(name: "AlgoratorCore", swiftSettings: strictConcurrency),
        .target(name: "AlgoratorEditor", dependencies: ["AlgoratorCore"], swiftSettings: strictConcurrency),
        // The toy "ticket triage" vocabulary and acceptance document, shared by the demo app and the tests.
        // Deliberately not a product: it never travels with the library into a consumer.
        .target(name: "TicketDemo", dependencies: ["AlgoratorCore"], resources: [.copy("Resources/acceptance.json")],
                swiftSettings: strictConcurrency),
        .executableTarget(name: "AlgoratorDemo", dependencies: ["AlgoratorCore", "AlgoratorEditor", "TicketDemo"]),
        .testTarget(name: "AlgoratorCoreTests", dependencies: ["AlgoratorCore", "TicketDemo"]),
        .testTarget(name: "AlgoratorEditorTests", dependencies: ["AlgoratorEditor", "TicketDemo"]),
    ]
)
