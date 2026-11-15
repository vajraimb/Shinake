// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShinakeServer",
    products: [
        .executable(name: "shinake-server", targets: ["shinake-server"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "ShinakeRelay",
            dependencies: [
                .product(name: "ShinakeCore", package: "Shinake"),
            ],
            path: "Sources/ShinakeRelay"
        ),
        .executableTarget(
            name: "shinake-server",
            dependencies: [
                "ShinakeRelay",
                .product(name: "ShinakeCore", package: "Shinake"),
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
