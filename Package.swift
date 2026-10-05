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
        // The toy "ticket triage" vocabulary and acceptance document, shared by the demo app and the tests.
        // Deliberately not a product: it never travels with the library into a consumer.
        .target(name: "TicketDemo", dependencies: ["AlgoratorCore"], resources: [.copy("Resources/acceptance.json")]),
        .executableTarget(name: "AlgoratorDemo", dependencies: ["AlgoratorCore", "AlgoratorEditor", "TicketDemo"]),
        .testTarget(name: "AlgoratorCoreTests", dependencies: ["AlgoratorCore", "TicketDemo"]),
        .testTarget(name: "AlgoratorEditorTests", dependencies: ["AlgoratorEditor", "TicketDemo"]),
    ]
)
