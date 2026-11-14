// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HandshakeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "HandshakeCore",
            targets: ["HandshakeCore"]
        )
    ],
    dependencies: [
        // Strictly zero external dependencies.
        // Uses Apple-native frameworks: Foundation, CryptoKit, Security, Network.
    ],
    targets: [
        .target(
            name: "HandshakeCore",
            dependencies: [],
            path: "Sources/HandshakeCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "HandshakeCoreTests",
            dependencies: ["HandshakeCore"],
            path: "Tests/HandshakeCoreTests"
        )
    ]
)

