import Foundation
import Testing
@testable import PTZBotKit

/// L'API de go2rtc simulée : le corps rendu, ou une erreur.
final class FakeGo2RTCAPI: Go2RTCAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _body: Data?
    private var _calls = 0

    /// nil : l'API ne répond pas.
    var body: Data? {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func streams() async throws -> Data {
        let body = lock.withLock {
            _calls += 1
            return _body
        }
        guard let body else { throw URLError(.cannotConnectToHost) }
        return body
    }
}

/// La liste des processus simulée.
final class FakeProcessListing: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?

    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    func psOutput() -> String? {
        output
    }
}

/// Des réponses de `GET /api/streams` de la forme de go2rtc 1.9.14 (relevée le 12/10 sur un go2rtc en service, valeurs
/// remplacées par des fictives).
enum StreamsFixtures {
    static let active = Data(#"""
    {"obsbot":{
      "producers":[
        {"id":1,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["video, recvonly, H264"],"receivers":[{}],"bytes_recv":1200},
        {"id":2,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["audio, recvonly, MPEG4-GENERIC/48000/2"],"receivers":[{}],"bytes_recv":300},
        {"url":"ffmpeg:obsbot#audio=opus"}],
      "consumers":[
        {"id":3,"format_name":"preload","medias":["video, sendonly, ANY"],"senders":[{}],"bytes_send":0},
        {"id":4,"format_name":"rtsp","protocol":"rtsp+tcp","remote_addr":"192.168.0.10:50000","medias":[],"senders":[],"bytes_send":10},
        {"id":5,"format_name":"webrtc","protocol":"udp","medias":[],"senders":[],"bytes_send":10},
        {"id":6,"format_name":"rtsp","protocol":"rtsp+tcp","medias":[],"senders":[],"bytes_send":10}]
    }}
    """#.utf8)

    /// La caméra débranchée : les producteurs exec ne reçoivent plus rien, seul le préchargement reste.
    static let noProducer = Data(#"""
    {"obsbot":{"producers":[{"url":"exec:…"},{"url":"exec:…"},{"url":"ffmpeg:obsbot#audio=opus"}],
     "consumers":[{"id":3,"format_name":"preload","medias":[],"senders":[],"bytes_send":0}]}}
    """#.utf8)
}

@Suite("go2rtc : API, coreaudiod et journal", .french)
struct Go2RTCSignalsTests {
    @Test("Clients par type, sans le préchargement ; producteur actif")
    func clients() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.active))
        #expect(status.clients == Go2RTCClients(byType: ["rtsp": 2, "webrtc": 1]))
        #expect(status.clients.total == 3)
        #expect(status.hasActiveProducer)
    }

    @Test("Stream sans producteur actif : la caméra est absente ; stream absent ou réponse illisible : nil")
    func noProducer() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.noProducer))
        #expect(!status.hasActiveProducer)
        #expect(status.clients.total == 0)
        #expect(Go2RTCStreams.status(of: "autre", in: StreamsFixtures.active) == nil)
        #expect(Go2RTCStreams.status(of: "obsbot", in: Data("pas du json".utf8)) == nil)
    }

    /// pid, ppid, commande : le gardien 500, son go2rtc 501, deux ffmpeg vidéo, un audio, le transcodeur Opus, et un ffmpeg
    /// vidéo d'un autre programme (900).
    static let ps = """
      1     0 /sbin/launchd
    400     1 /Applications/PTZBot.app/Contents/MacOS/PTZBot
    500   400 /Applications/PTZBot.app/Contents/Helpers/gardien --parent 400 --arret 10 -- /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    501   500 /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    502   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    503   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -i :OBSBOT Tiny2 Microphone -vn -f rtsp rtsp://127.0.0.1:8554/b
    504   501 ffmpeg -hide_banner -i rtsp://127.0.0.1:8554/obsbot -c:a libopus -f rtsp rtsp://127.0.0.1:8554/c
    505   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    900     1 /usr/local/bin/ffmpeg -f avfoundation -i 0 sortie.mp4
    """

    @Test("coreaudiod : les ffmpeg vidéo comptés sous le gardien seulement ; plus d'un : bloqué")
    func videoFFmpegs() {
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 500) == 2)
        let healthy = Self.ps.split(separator: "\n").filter { !$0.hasPrefix("505 ") }.joined(separator: "\n")
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: healthy, root: 500) == 1)
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 999) == 0)
        #expect(CoreAudioDetector.isStuck(videoFFmpegs: 2, lastTimeout: nil, now: 0))
        #expect(!CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: nil, now: 0))
    }

    @Test("coreaudiod : un exec: timeout de moins de 2 min suffit ; plus vieux, non")
    func timeoutWindow() {
        #expect(CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: 100, now: 219))
        #expect(!CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: 100, now: 220))
        #expect(CoreAudioDetector.repairCommand == "sudo killall -9 coreaudiod")
    }

    @Test("Journal : exec: timeout et refus d'accès d'avfoundation reconnus ; le reste ignoré")
    func logPatterns() {
        #expect(Go2RTCLogPatterns.scan("12:00:01.000 ERR [exec] timeout source=exec:…\n") == Go2RTCLogScan(sawTimeout: true))
        #expect(Go2RTCLogPatterns.scan(#"WRN [streams] error="exec: timeout""#) == Go2RTCLogScan(sawTimeout: true))
        let denied = #"WRN [streams] error="exec/rtsp\n[avfoundation @ 0x1] Failed to create AV capture input device: Cannot use OBSBOT""#
        #expect(Go2RTCLogPatterns.scan(denied) == Go2RTCLogScan(sawAccessDenied: true))
        #expect(Go2RTCLogPatterns.scan("ERR [rtsp] wrong user/pass denied") == Go2RTCLogScan())
        #expect(Go2RTCLogPatterns.scan("INF [api] listen addr=127.0.0.1:1984\n") == Go2RTCLogScan())
    }

    @Test("Lecteur du journal : seulement la suite ; au plus les derniers octets ; journal raccourci relu du début")
    func logReader() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "go2rtc.log")
        try Data("ancien\n".utf8).write(to: url)
        var reader = Go2RTCLogReader(url: url, offset: 7)
        #expect(reader.readNew() == "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("nouveau\n".utf8))
        try handle.close()
        #expect(reader.readNew() == "nouveau\n")
        #expect(reader.readNew() == "")
        try Data("court\n".utf8).write(to: url)
        #expect(reader.readNew() == "court\n")
        try Data("0123456789".utf8).write(to: url)
        reader.reset(to: 0)
        #expect(reader.readNew(maxBytes: 4) == "6789")
        #expect(Go2RTCLogReader(url: directory.appending(path: "absent.log")).offset == 0)
    }
}

@MainActor
@Suite("go2rtc : surveillance pour le panneau", .french, .timeLimit(.minutes(1)))
struct Go2RTCMonitorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let api = FakeGo2RTCAPI()
    let processes = FakeProcessListing()

    /// Un go2rtc qui tourne (gardien simulé de pid 1000), son journal dans `directory`.
    private func running(_ directory: URL) async -> (Go2RTCSupervisor, Go2RTCMonitor, URL) {
        let log = directory.appending(path: "go2rtc.log")
        settings.values[Go2RTCSupervisor.enabledKey] = true
        let supervisor = Go2RTCSupervisor(
            paths: Go2RTCSupervisor.Paths(gardien: URL(fileURLWithPath: "/app/gardien"), go2rtc: URL(fileURLWithPath: "/app/go2rtc"), log: log),
            launcher: launcher, preparer: FakePreparer(), settings: settings, scheduler: scheduler, parentPID: 4242,
            configuration: Go2RTCFixtures.settings()
        )
        supervisor.start()
        await supervisor.waitForPreparation()
        let monitor = Go2RTCMonitor(supervisor: supervisor, api: api, processes: processes, logURL: log, scheduler: scheduler)
        return (supervisor, monitor, log)
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test("Panneau ouvert : clients et producteur lus dans l'API ; un seul ffmpeg vidéo : pas d'alerte")
    func clients() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        processes.output = "1000 1 gardien\n1001 1000 go2rtc\n1002 1001 /opt/homebrew/bin/ffmpeg -f avfoundation -i Cam -an\n"
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(monitor.stream?.clients.total == 3)
        #expect(monitor.health == Go2RTCHealth())
    }

    @Test("Deux ffmpeg vidéo : coreaudiod bloqué ; caméra sans producteur : absente")
    func alerts() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.noProducer
        processes.output = "1000 1 g\n1001 1000 go2rtc\n1002 1001 ffmpeg -f avfoundation -an\n1003 1001 ffmpeg -f avfoundation -an\n"
        await monitor.refresh()
        #expect(monitor.health == Go2RTCHealth(coreAudioStuck: true, cameraMissing: true))
    }

    @Test("Journal : un refus d'accès écrit après le lancement est vu ; avant, non ; un nouveau go2rtc l'efface")
    func accessDenied() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "go2rtc.log")
        try append("[avfoundation] not authorized (exec, avant le lancement)\n", to: log)
        let (supervisor, monitor, _) = await running(directory)
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
        try append(#"WRN error="exec/rtsp [avfoundation @ 0x1] Failed to create AV capture input device""# + "\n", to: log)
        monitor.scanLog()
        #expect(monitor.health.accessDenied)
        supervisor.restart()
        await supervisor.waitForPreparation()
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
    }

    @Test("exec: timeout : alerte coreaudiod 2 min, puis plus rien ; relu toutes les 10 s sans panneau")
    func timeout() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        monitor.start()
        try append("ERR [exec] timeout source=exec:…\n", to: log)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        #expect(monitor.health.coreAudioStuck)
        scheduler.advance(by: CoreAudioDetector.timeoutWindow)
        #expect(!monitor.health.coreAudioStuck)
    }

    @Test("Panneau fermé : plus de lecture de l'API ; go2rtc arrêté : ni clients ni alerte")
    func endWatching() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (supervisor, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(api.calls == 1)
        scheduler.advance(by: Go2RTCMonitor.pollInterval)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        monitor.endWatching()
        scheduler.advance(by: Go2RTCMonitor.pollInterval * 3)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        supervisor.stop()
        await monitor.refresh()
        #expect(monitor.stream == nil)
        #expect(monitor.health == Go2RTCHealth())
    }
}
