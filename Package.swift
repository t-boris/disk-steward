// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskSteward",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DiskStewardCore",
            targets: ["DiskStewardCore"]
        ),
        .executable(
            name: "DiskSteward",
            targets: ["DiskStewardApp"]
        )
    ],
    targets: [
        .target(
            name: "DiskStewardCore",
            path: "Sources/DiskStewardCore"
        ),
        .executableTarget(
            name: "DiskStewardApp",
            dependencies: ["DiskStewardCore"],
            path: "Sources/DiskStewardApp"
        ),
        .testTarget(
            name: "DiskStewardCoreTests",
            dependencies: ["DiskStewardCore"],
            path: "Tests/DiskStewardCoreTests"
        )
    ]
)
