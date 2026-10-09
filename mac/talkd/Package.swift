// swift-tools-version: 6.0
import PackageDescription

/// talkd : le retour audio de la caméra, de l'app Maison vers les haut-parleurs du Mac (spec haut-parleur).
/// `TalkCore` ne touche ni le son ni le réseau réels (tout passe par des protocoles) : il se teste sans matériel.
/// Le moteur audio et CoreAudio ne sont construits que dans l'exécutable.
let package = Package(
    name: "talkd",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TalkCore"),
        .executableTarget(name: "talkd", dependencies: ["TalkCore"]),
        .testTarget(name: "TalkCoreTests", dependencies: ["TalkCore"]),
    ]
)
