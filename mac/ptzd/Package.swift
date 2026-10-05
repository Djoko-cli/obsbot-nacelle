// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ptzd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
    ]
)
