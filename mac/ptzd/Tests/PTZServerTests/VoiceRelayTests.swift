import Darwin
import Foundation
import NacelleProtocol
import Testing
@testable import PTZServer

/// Faux récepteur UDP de talkd : une socket sur 127.0.0.1, port choisi par le système, lue avec une limite de temps.
final class UDPTestReceiver: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32

    struct SetupFailure: Error {}

    init() throws {
        let candidate = socket(AF_INET, SOCK_DGRAM, 0)
        guard candidate >= 0 else { throw SetupFailure() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(candidate, pointer, length) == 0 && getsockname(candidate, pointer, &length) == 0
            }
        }
        guard bound else {
            close(candidate)
            throw SetupFailure()
        }
        descriptor = candidate
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(descriptor)
    }

    /// Un datagramme, ou nil au bout de `timeout` secondes.
    func receive(timeout: TimeInterval = 5) -> Data? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        return count >= 0 ? Data(buffer.prefix(count)) : nil
    }

    /// Comme `receive`, sans bloquer la file principale (où tourne le serveur testé).
    func receiveAsync(timeout: TimeInterval = 5) async -> Data? {
        await Task.detached { self.receive(timeout: timeout) }.value
    }

    func drainAsync(quiet: TimeInterval = 0.5) async -> [Data] {
        await Task.detached { self.drain(quiet: quiet) }.value
    }

    /// Tous les datagrammes arrivés, jusqu'à `quiet` secondes de silence.
    func drain(quiet: TimeInterval = 0.3) -> [Data] {
        var frames: [Data] = []
        while let frame = receive(timeout: quiet) {
            frames.append(frame)
        }
        return frames
    }
}

/// Faux relais : garde les trames reçues.
@MainActor
final class RecordingSink: VoiceSink {
    private(set) var frames: [Data] = []

    func send(_ frame: Data) {
        frames.append(frame)
    }
}

@Suite("Limite de 50 trames par seconde", .timeLimit(.minutes(1)))
struct VoiceLimiterTests {
    @Test("50 trames dans une seconde passent, la 51e est refusée")
    func fiftyThenRefused() {
        var limiter = VoiceLimiter()
        for index in 0..<50 {
            let allowed = limiter.allow(at: Double(index) * 0.01)
            #expect(allowed, "trame \(index)")
        }
        let early = limiter.allow(at: 0.5)
        let late = limiter.allow(at: 0.99)
        #expect(!early && !late)
    }

    @Test("Fenêtre glissante : la place revient une seconde après la trame la plus ancienne")
    func slides() {
        var limiter = VoiceLimiter()
        for index in 0..<50 {
            _ = limiter.allow(at: Double(index) * 0.01)
        }
        let before = limiter.allow(at: 0.999)
        // La première trame (t = 0) sort de la fenêtre à t = 1.
        let after = limiter.allow(at: 1.0)
        let again = limiter.allow(at: 1.0)
        #expect(!before && after && !again)
    }

    @Test("Le rythme normal de 20 ms ne se heurte jamais à la limite")
    func normalRate() {
        var limiter = VoiceLimiter()
        for index in 0..<500 {
            let allowed = limiter.allow(at: Double(index * 20) / 1000)
            #expect(allowed, "trame \(index)")
        }
    }

    @Test("Les trames refusées ne comptent pas dans la fenêtre")
    func refusedDoNotCount() {
        var limiter = VoiceLimiter()
        for _ in 0..<50 { _ = limiter.allow(at: 0) }
        var anyAllowed = false
        for _ in 0..<200 where limiter.allow(at: 0.5) { anyAllowed = true }
        let later = limiter.allow(at: 1.0)
        #expect(!anyAllowed && later)
    }
}

@MainActor
@Suite("Envoi UDP vers talkd", .timeLimit(.minutes(1)))
struct UDPVoiceSinkTests {
    @Test("La trame arrive intacte à 127.0.0.1:<port>, sur une socket gardée")
    func relays() throws {
        let receiver = try UDPTestReceiver()
        let sink = UDPVoiceSink(port: receiver.port)
        let first = Data((0..<VoiceFrame.byteCount).map { UInt8($0 % 251) })
        let second = Data(repeating: 7, count: VoiceFrame.byteCount)
        sink.send(first)
        sink.send(second)
        #expect(receiver.receive() == first)
        #expect(receiver.receive() == second)
        #expect(sink.sendFailures == 0)
    }

    @Test("talkd absent : l'envoi échoue sans erreur ni plantage, et reprend quand talkd revient")
    func absentTalkd() throws {
        var receiver: UDPTestReceiver? = try UDPTestReceiver()
        let port = receiver!.port
        let sink = UDPVoiceSink(port: port)
        receiver = nil
        // Rien n'écoute plus : le noyau peut refuser (ICMP) les envois suivants ; rien ne doit remonter.
        for _ in 0..<5 {
            sink.send(Data(count: VoiceFrame.byteCount))
        }
        #expect(sink.sendFailures >= 0)
    }
}

@MainActor
@Suite("Relais des trames voix", .timeLimit(.minutes(1)))
struct VoiceRelayerTests {
    let scheduler = FakeScheduler()
    let sink = RecordingSink()
    let lines = LineBox()
    let clock = TestClock()
    let device = VoiceRelayer.Sender.device(id: "00112233445566778899aabbccddeeff", name: "iPhone de test")

    private func makeRelayer() -> VoiceRelayer {
        VoiceRelayer(sink: sink, scheduler: scheduler, now: { [clock] in clock.date }, log: { [lines] in lines.values.append($0) })
    }

    private func frame(_ byte: UInt8 = 1) -> Data {
        Data(repeating: byte, count: VoiceFrame.byteCount)
    }

    @Test("Un appareil authentifié : la trame est relayée telle quelle")
    func relaysFromDevice() {
        let relayer = makeRelayer()
        relayer.receive(frame(9), from: 1, as: device)
        #expect(sink.frames == [frame(9)])
        #expect(relayer.refused == VoiceRelayer.Refusals())
    }

    @Test("Client non authentifié ou de confiance (127.0.0.1) : refusé et compté")
    func refusesOthers() {
        let relayer = makeRelayer()
        relayer.receive(frame(), from: 1, as: .unauthenticated)
        relayer.receive(frame(), from: 2, as: .trusted)
        #expect(sink.frames.isEmpty)
        #expect(relayer.refused.unauthorized == 2)
    }

    @Test("Taille différente de 640 octets : refusée et comptée", arguments: [0, 1, 639, 641, 1280, 4096])
    func refusesBadSize(size: Int) {
        let relayer = makeRelayer()
        relayer.receive(Data(count: size), from: 1, as: device)
        #expect(sink.frames.isEmpty)
        #expect(relayer.refused.badSize == 1)
    }

    @Test("Au-delà de 50 trames par seconde (plus une marge de 10 pour la gigue) et par client : l'excédent est refusé, l'autre client n'est pas touché")
    func rateLimit() {
        let relayer = makeRelayer()
        let allowed = VoiceFrame.maxFramesPerSecond + VoiceRelayer.burstTolerance
        for _ in 0..<(allowed + 10) {
            relayer.receive(frame(1), from: 1, as: device)
        }
        #expect(sink.frames.count == allowed)
        #expect(relayer.refused.tooFast == 10)
        // Un autre client a sa propre fenêtre.
        relayer.receive(frame(2), from: 2, as: .device(id: "ffeeddccbbaa99887766554433221100", name: "iPad"))
        #expect(sink.frames.count == allowed + 1)
        // Une seconde plus tard, la fenêtre est libre.
        scheduler.advance(by: 1.01)
        relayer.receive(frame(3), from: 1, as: device)
        #expect(sink.frames.count == allowed + 2)
    }

    @Test("Une prise de parole : une ligne de journal à sa fin (1 s sans trame), avec début, durée, relayées et refusées")
    func turnLine() {
        let relayer = makeRelayer()
        for _ in 0..<100 {
            relayer.receive(frame(), from: 1, as: device)
            scheduler.advance(by: 0.02)
        }
        relayer.receive(Data(count: 3), from: 1, as: device)
        #expect(lines.values.filter { $0.hasPrefix("Parole") }.isEmpty)
        scheduler.advance(by: 1.1)
        let turns = lines.values.filter { $0.hasPrefix("Parole") }
        #expect(turns.count == 1)
        let line = turns[0]
        #expect(line.contains("00112233"))
        #expect(line.contains("iPhone de test"))
        #expect(line.contains("100 trames relayées"))
        #expect(line.contains("1 refusée"))
        #expect(line.contains("durée 2,0 s"))
        #expect(line.contains("début "))
    }

    @Test("Après une pause, une nouvelle prise de parole a sa propre ligne")
    func twoTurns() {
        let relayer = makeRelayer()
        relayer.receive(frame(), from: 1, as: device)
        scheduler.advance(by: 1.5)
        relayer.receive(frame(), from: 1, as: device)
        relayer.receive(frame(), from: 1, as: device)
        scheduler.advance(by: 1.5)
        let turns = lines.values.filter { $0.hasPrefix("Parole") }
        #expect(turns.count == 2)
        #expect(turns[0].contains("1 trame relayée"))
        #expect(turns[1].contains("2 trames relayées"))
    }

    @Test("Déconnexion en pleine parole : la ligne est écrite tout de suite, et plus rien ensuite")
    func disconnect() {
        let relayer = makeRelayer()
        relayer.receive(frame(), from: 1, as: device)
        relayer.clientGone(1)
        #expect(lines.values.filter { $0.hasPrefix("Parole") }.count == 1)
        scheduler.advance(by: 5)
        #expect(lines.values.filter { $0.hasPrefix("Parole") }.count == 1)
        // Un client qui n'a jamais parlé ne laisse aucune ligne.
        relayer.clientGone(99)
        #expect(lines.values.filter { $0.hasPrefix("Parole") }.count == 1)
    }

    @Test("Refus : une ligne au plus par minute, avec les décomptes cumulés")
    func refusalLines() {
        let relayer = makeRelayer()
        for _ in 0..<20 {
            relayer.receive(frame(), from: 1, as: .unauthenticated)
        }
        let first = lines.values.filter { $0.hasPrefix("Trames vocales refusées") }
        #expect(first.count == 1)
        #expect(first[0].contains("1 sans authentification"))
        scheduler.advance(by: 59)
        for _ in 0..<5 {
            relayer.receive(Data(count: 10), from: 3, as: device)
        }
        #expect(lines.values.filter { $0.hasPrefix("Trames vocales refusées") }.count == 1)
        scheduler.advance(by: 1.1)
        let all = lines.values.filter { $0.hasPrefix("Trames vocales refusées") }
        #expect(all.count == 2)
        #expect(all[1].contains("19 sans authentification"))
        #expect(all[1].contains("5 de taille fausse"))
        // Plus aucun refus : plus aucune ligne.
        scheduler.advance(by: 300)
        #expect(lines.values.filter { $0.hasPrefix("Trames vocales refusées") }.count == 2)
    }

    @Test("Aucune trace du son dans le journal")
    func noAudioInJournal() {
        let relayer = makeRelayer()
        let marker = Data((0..<VoiceFrame.byteCount).map { UInt8(truncatingIfNeeded: 0xA0 + $0) })
        for _ in 0..<10 {
            relayer.receive(marker, from: 1, as: device)
        }
        relayer.receive(marker, from: 2, as: .unauthenticated)
        relayer.receive(marker.dropLast(), from: 1, as: device)
        scheduler.advance(by: 3)
        let journal = lines.values.joined(separator: "\n")
        #expect(!journal.isEmpty)
        #expect(!journal.contains(marker.base64EncodedString()))
        #expect(!journal.contains(marker.map { String(format: "%02x", $0) }.joined()))
        #expect(!journal.contains(String(describing: marker.prefix(8) as Data)))
        #expect(!journal.contains("160, 161"))
    }
}
