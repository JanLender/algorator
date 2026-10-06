// swift-tools-version: 6.0
import PackageDescription

// A throwaway consumer in the Swift 6 language mode: proves the library is usable under strict concurrency.
// `swift build` here must finish with zero warnings and zero errors.
let package = Package(
    name: "Consumer6",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(name: "Consumer6", dependencies: [
            .product(name: "AlgoratorCore", package: "algorator"),
            .product(name: "AlgoratorEditor", package: "algorator"),
        ]),
    ]
)
