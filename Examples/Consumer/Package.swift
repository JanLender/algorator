// swift-tools-version:5.9
import PackageDescription

// A throwaway consumer: proves the library can be depended on from another package, by path.
let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(name: "Consumer", dependencies: [
            .product(name: "AlgoratorCore", package: "algorator"),
            .product(name: "AlgoratorEditor", package: "algorator"),
        ]),
    ]
)
