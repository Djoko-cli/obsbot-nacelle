import Foundation
import os
import TalkCore

/// talkd : reçoit en UDP la voix envoyée depuis l'app Maison (par Homebridge) et la joue sur les haut-parleurs
/// intégrés du Mac (spec haut-parleur). Sans interface ; lancé par l'agent launchd embarqué dans PTZBot.app, il tourne
/// aussi quand PTZBot est fermé. Réglages : talkd.json ; journal : talkd.log.
@main
struct TalkDaemon {
    static let logger = Logger(subsystem: "io.github.djoko-cli.obsbot-nacelle", category: "talkd")

    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty else {
            FileHandle.standardError.write(Data("talkd : option inconnue : \(arguments[0])\n\(TalkExit.usageText)\n".utf8))
            exit(TalkExit.usage)
        }

        let paths = TalkPaths(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        let journal = JournalFile(url: paths.journal)
        // Une ligne dans le journal système, dans talkd.log et sur la sortie standard (perdue sous launchd).
        let log: LogSink = { line in
            logger.log("\(line, privacy: .public)")
            journal.write(line)
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        let settings = TalkSettings.load(from: paths.settings, log: log)
        // L'AUHAL n'est créée qu'à la première prise de parole, puis gardée (un seul client coreaudiod).
        let output = HALOutput { try AUHALUnit() }
        let controller = TalkController(
            settings: settings,
            catalog: CoreAudioCatalog(),
            output: output,
            volume: CoreAudioVolume(),
            stateStore: JSONFileTalkStateStore(url: paths.state),
            recovery: JSONFileVolumeRecoveryStore(url: paths.volumeRecovery),
            scheduler: DispatchScheduler(),
            log: log
        )

        // Le port d'abord : occupé, talkd s'arrête avec un code d'erreur et launchd le relance au rythme du
        // ThrottleInterval (spec § 9).
        let receiver = UDPReceiver()
        let port: UInt16
        do {
            port = try receiver.start(port: UInt16(settings.port)) { datagram in
                MainActor.assumeIsolated { controller.receive(datagram) }
            }
        } catch {
            log("talkd ne peut pas écouter : \(error). talkd s'arrête.")
            // L'app affiche la raison (« Arrêté : … ») ; ce fichier ne touche pas CoreAudio.
            let failed = TalkState(
                speaking: false, since: Date(), pid: ProcessInfo.processInfo.processIdentifier,
                failure: TalkState.failure(for: error)
            )
            do {
                try JSONFileTalkStateStore(url: paths.state).save(failed)
            } catch {
                log("L'état de talkd n'a pas pu être écrit (\(error)).")
            }
            exit(error == .addressInUse(UInt16(settings.port)) ? TalkExit.busy : 1)
        }
        log("Écoute UDP sur le port \(port).")

        // La phase CoreAudio, freinée si les précédentes ont été courtes (plantage en boucle, relecture I4).
        let runs = JSONFileStartupRecordStore(url: paths.runs)
        let previous: StartupRecord?
        do {
            previous = try runs.load()
        } catch {
            log("Fichier du frein au démarrage illisible (\(error)) : le frein repart de zéro.")
            previous = nil
        }
        let decision = StartupBrake.decide(previous: previous, now: Date())
        controller.start(braking: decision) {
            do {
                try runs.save(StartupRecord(lastCoreAudioStart: Date(), shortRuns: decision.shortRuns))
            } catch {
                log("Le fichier du frein au démarrage n'a pas pu être écrit (\(error)).")
            }
        }

        // SIGTERM (launchd) et SIGINT : la prise de parole en cours est finie, le volume rétabli.
        let signals = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                controller.shutdown()
                receiver.stop()
                // Un arrêt propre n'est pas un plantage : le frein repart de zéro au prochain démarrage.
                try? runs.clear()
                exit(0)
            }
            source.resume()
            return source
        }
        withExtendedLifetime((controller, receiver, output, journal, signals)) {
            dispatchMain()
        }
    }
}
