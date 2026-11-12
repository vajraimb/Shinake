// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShinakeCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ShinakeCore", targets: ["ShinakeCore"]),
        .executable(name: "ShinakePreview", targets: ["ShinakePreview"]),
    ],
    targets: [
        .target(name: "ShinakeCore", path: "Sources/ShinakeCore"),
        .executableTarget(
            name: "ShinakePreview",
            dependencies: ["ShinakeCore"],
            path: "Sources/ShinakePreview"
        ),
        .testTarget(
            name: "ShinakeCoreTests",
            dependencies: ["ShinakeCore"],
            path: "Tests/ShinakeCoreTests"
        ),
    ]
)
