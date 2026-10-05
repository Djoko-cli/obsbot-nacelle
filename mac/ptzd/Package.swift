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
            name: "CUVC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .target(name: "UVCCamera", dependencies: ["CUVC", "PTZCore"]),
        .target(
            name: "PTZServer",
            dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
        .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
        .testTarget(
            name: "PTZServerTests",
            dependencies: ["PTZServer", "PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
    ]
)
