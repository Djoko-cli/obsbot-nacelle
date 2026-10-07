// swift-tools-version: 6.0
import PackageDescription

/// La logique de PTZBot pour Mac, sans interface : testée par `swift test`, utilisée par l'app (mac/app).
let package = Package(
    name: "PTZBotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PTZBotKit", targets: ["PTZBotKit"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(name: "PTZBotKit", dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]),
        .testTarget(name: "PTZBotKitTests", dependencies: ["PTZBotKit", .product(name: "NacelleProtocol", package: "NacelleProtocol")]),
    ]
)
