import Foundation
import os
import PTZCore
import PTZServer
import UVCCamera

@main
struct PTZDaemon {
    /// Dossier de travail (spec § 6.7). PTZD_SUPPORT_DIR le remplace pour les essais.
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ObsbotNacelle")
    }()

    /// Journaux (spec § 6.7) ; sous PTZD_SUPPORT_DIR pendant les essais.
    static let logsDirectory: URL = {
        if ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] != nil {
            return supportDirectory.appending(path: "logs")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle")
    }()
    static let logger = Logger(subsystem: "io.github.djoko-cli.obsbot-nacelle", category: "ptzd")

    /// Une ligne dans le journal système et sur la sortie standard (redirigée par launchd).
    nonisolated static func write(_ line: String) {
        logger.log("\(line, privacy: .public)")
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    @MainActor
    static func main() {
        let log: LogSink = { write($0) }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "uvc" {
            exit(UVCDebugCommand.run(Array(arguments.dropFirst()), log: log))
        }

        let config: PTZConfig
        do {
            config = try PTZConfig.load(from: supportDirectory.appending(path: "config.json"))
        } catch {
            log("config.json absent ou invalide : \(error)")
            exit(78)
        }

        let scheduler = DispatchScheduler()
        let camera = UVCCamera(log: log)
        let controller = PTZController(
            camera: camera,
            scheduler: scheduler,
            aiOff: ProcessAIOffRunner(
                executableURL: config.aiOffURL(relativeTo: supportDirectory),
                outputURL: logsDirectory.appending(path: "obsbot-ai-off.log"),
                scheduler: scheduler
            ),
            store: JSONFileStateStore(url: supportDirectory.appending(path: "state.json"), log: { write($0) }),
            settings: config.motion,
            isObsbotCenterRunning: { ObsbotCenterDetector.isRunning() },
            log: log
        )
        camera.onPresenceChange = { controller.cameraPresenceChanged($0) }
        // 127.0.0.1 en plus de l'adresse Tailscale : le Mac ne peut pas se joindre
        // lui-même par Tailscale, et les diagnostics locaux en ont besoin.
        let server = WebSocketServer(
            hosts: [config.listenAddress, "127.0.0.1"],
            port: UInt16(config.port),
            controller: controller,
            scheduler: scheduler,
            log: log
        )

        log("ptzd démarre.")
        camera.startWatching()
        server.start()
        withExtendedLifetime((camera, controller, server)) {
            dispatchMain()
        }
    }
}
