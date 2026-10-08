// swift-tools-version: 6.0
import PackageDescription

/// La logique de PTZBot pour Mac, sans interface : testée par `swift test`, utilisée par l'app (mac/app).
let package = Package(
    name: "PTZBotKit",
    // Textes en français (langue source, au vouvoiement) et en anglais : Resources/Localizable.xcstrings.
    defaultLocalization: "fr",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PTZBotKit", targets: ["PTZBotKit"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "PTZBotKit",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "PTZBotKitTests", dependencies: ["PTZBotKit", .product(name: "NacelleProtocol", package: "NacelleProtocol")]),
    ]
)
