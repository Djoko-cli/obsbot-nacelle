import Foundation
import NacelleProtocol
import Testing
@testable import PTZCore

@Suite("Talkback prêt : lecture de talkd-state.json et de talkd.json", .timeLimit(.minutes(1)))
struct TalkbackProbeTests {
    private func json(pid: Int32 = 4242, failure: String? = nil) -> Data {
        let failureField = failure.map { #","failure":"\#($0)""# } ?? ""
        return Data(#"{"pid":\#(pid),"since":"2026-10-09T10:00:00Z","speaking":false\#(failureField)}"#.utf8)
    }

    @Test("Fichier absent : indisponible")
    func missing() {
        #expect(TalkbackProbe.availability(stateFile: nil, isAlive: { _ in true }) == .unavailable)
    }

    @Test("Fichier illisible : indisponible")
    func corrupt() {
        #expect(TalkbackProbe.availability(stateFile: Data("{pas du json".utf8), isAlive: { _ in true }) == .unavailable)
        #expect(TalkbackProbe.availability(stateFile: Data(), isAlive: { _ in true }) == .unavailable)
    }

    @Test("Échec noté par talkd : indisponible, même si le pid est vivant")
    func failure() {
        #expect(TalkbackProbe.availability(stateFile: json(failure: "portBusy"), isAlive: { _ in true }) == .unavailable)
    }

    @Test("Pid mort : indisponible")
    func deadPid() {
        #expect(TalkbackProbe.availability(stateFile: json(pid: 99_999), isAlive: { _ in false }) == .unavailable)
    }

    @Test("Sans échec et pid vivant : prêt, et le pid noté est celui qu'on interroge")
    func ready() {
        var asked: [Int32] = []
        let result = TalkbackProbe.availability(stateFile: json(pid: 777), isAlive: { asked.append($0); return true })
        #expect(result == .ready)
        #expect(asked == [777])
    }

    @Test("Un fichier d'état avec « speaking » vrai est prêt aussi")
    func speaking() {
        let data = Data(#"{"pid":5,"since":"2026-10-09T10:00:00Z","speaking":true}"#.utf8)
        #expect(TalkbackProbe.availability(stateFile: data, isAlive: { _ in true }) == .ready)
    }

    @Test("Pid de ce processus : vivant ; pid 0 ou négatif : jamais vivant")
    func realLiveness() {
        #expect(TalkbackProbe.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!TalkbackProbe.isProcessAlive(0))
        #expect(!TalkbackProbe.isProcessAlive(-1))
    }

    @Test("Lecture réelle d'un dossier : fichier absent puis présent")
    func fileRead() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-talkback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "talkd-state.json")
        #expect(TalkbackProbe.availability(stateFileAt: url, isAlive: { _ in true }) == .unavailable)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json().write(to: url)
        #expect(TalkbackProbe.availability(stateFileAt: url, isAlive: { _ in true }) == .ready)
    }
}

@Suite("Port de talkd", .timeLimit(.minutes(1)))
struct TalkPortTests {
    private func port(of text: String?) throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-talkport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "talkd.json")
        if let text {
            try Data(text.utf8).write(to: url)
        }
        return TalkPort.load(from: url)
    }

    @Test("Fichier absent ou sans port : 1986")
    func defaults() throws {
        #expect(try port(of: nil) == 1986)
        #expect(try port(of: #"{"volumeFloor":0.3}"#) == 1986)
        #expect(TalkPort.defaultPort == 1986)
    }

    @Test("Port du fichier lu, les autres champs ignorés")
    func custom() throws {
        #expect(try port(of: #"{"port":2024,"allowedSources":["127.0.0.1"],"volumeFloor":0.3,"voiceThreshold":0.01}"#) == 2024)
    }

    @Test("Fichier invalide ou port hors de 1…65535 : 1986")
    func invalid() throws {
        #expect(try port(of: "{pas du json") == 1986)
        #expect(try port(of: #"{"port":0}"#) == 1986)
        #expect(try port(of: #"{"port":70000}"#) == 1986)
        #expect(try port(of: #"{"port":"mille"}"#) == 1986)
    }
}

@MainActor
@Suite("Veilleur de Talkback", .timeLimit(.minutes(1)))
struct TalkbackWatcherTests {
    let scheduler = FakeScheduler()

    @Test("Lit au démarrage, puis toutes les 5 s, et signale seulement un changement de valeur")
    func publishesOnlyChanges() {
        let source = ValueBox(TalkbackAvailability.unavailable)
        var published: [TalkbackAvailability] = []
        var readCount = 0
        let watcher = TalkbackWatcher(scheduler: scheduler, read: { readCount += 1; return source.value }, onChange: { published.append($0) })
        watcher.start()
        // Première lecture : la valeur de départ de l'état est « indisponible », rien à diffuser.
        #expect(readCount == 1)
        #expect(published.isEmpty)

        scheduler.advance(by: 4.9)
        #expect(readCount == 1)
        source.value = .ready
        scheduler.advance(by: 0.1)
        #expect(readCount == 2)
        #expect(published == [.ready])

        scheduler.advance(by: 5)
        scheduler.advance(by: 5)
        #expect(readCount == 4)
        #expect(published == [.ready])

        source.value = .unavailable
        scheduler.advance(by: 5)
        #expect(published == [.ready, .unavailable])
    }

    @Test("Prêt dès le démarrage : signalé tout de suite")
    func readyAtStart() {
        var published: [TalkbackAvailability] = []
        let watcher = TalkbackWatcher(scheduler: scheduler, read: { .ready }, onChange: { published.append($0) })
        watcher.start()
        #expect(published == [.ready])
    }

    @Test("stop() arrête les lectures")
    func stop() {
        var readCount = 0
        let watcher = TalkbackWatcher(scheduler: scheduler, read: { readCount += 1; return .unavailable }, onChange: { _ in })
        watcher.start()
        watcher.stop()
        scheduler.advance(by: 30)
        #expect(readCount == 1)
    }
}

@MainActor
@Suite("Contrôleur : talkback dans l'état", .timeLimit(.minutes(1)))
struct ControllerTalkbackTests {
    @Test("setTalkback diffuse un nouvel état seulement quand la valeur change")
    func publishes() {
        let controller = PTZController(
            camera: FakeCamera(), scheduler: FakeScheduler(), ai: FakeAIRunner(), store: MemoryStateStore(),
            settings: MotionSettings(), isObsbotCenterRunning: { false }, log: { _ in }
        )
        var published: [StateSnapshot] = []
        controller.onStateChange = { published.append($0) }
        #expect(controller.snapshot.talkback == .unavailable)
        controller.setTalkback(.unavailable)
        #expect(published.isEmpty)
        controller.setTalkback(.ready)
        #expect(published.count == 1)
        #expect(published.last?.talkback == .ready)
        #expect(controller.snapshot.talkback == .ready)
        controller.setTalkback(.ready)
        #expect(published.count == 1)
    }
}

/// Valeur partagée entre le test et la closure de lecture.
final class ValueBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
