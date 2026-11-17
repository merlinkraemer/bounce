// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BounceKit",
    platforms: [
        .iOS("18.0"),
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BounceKit",
            targets: ["BounceKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BounceKit",
            dependencies: [],
            path: "Sources/BounceKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "BounceKitTests",
            dependencies: ["BounceKit"],
            path: "Tests/BounceKitTests"
        )
    ]
)
