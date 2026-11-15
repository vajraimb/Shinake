// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShinakeServer",
    platforms: [
        .iOS(.v16),
        .macOS(.v12),
    ],
    products: [
        .executable(name: "shinake-server", targets: ["shinake-server"]),
    ],
    dependencies: [
        .package(name: "ShinakeCore", path: ".."),
    ],
    targets: [
        .target(
            name: "ShinakeRelay",
            dependencies: [
                .product(name: "ShinakeCore", package: "ShinakeCore"),
            ],
            path: "Sources/ShinakeRelay"
        ),
        .executableTarget(
            name: "shinake-server",
            dependencies: [
                "ShinakeRelay",
                .product(name: "ShinakeCore", package: "ShinakeCore"),
            ],
            path: "Sources/shinake-server"
        ),
        .testTarget(
            name: "ShinakeRelayTests",
            dependencies: ["ShinakeRelay"],
            path: "Tests/ShinakeRelayTests"
        ),
    ]
)
