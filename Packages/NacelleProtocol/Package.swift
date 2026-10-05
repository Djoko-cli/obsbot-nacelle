// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NacelleProtocol",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "NacelleProtocol", targets: ["NacelleProtocol"]),
    ],
    targets: [
        .target(name: "NacelleProtocol"),
        .testTarget(name: "NacelleProtocolTests", dependencies: ["NacelleProtocol"]),
    ]
)
