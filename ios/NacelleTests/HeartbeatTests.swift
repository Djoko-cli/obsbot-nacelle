import Foundation
import Testing
@testable import Nacelle

@MainActor
@Suite("Vivacité du WebSocket")
struct HeartbeatTests {
    let scheduler = FakeScheduler()

    /// Un ping simulé : retient les réponses en attente ; le test répond quand il veut.
    final class Pings {
        var replies: [Heartbeat.Pong] = []
        var lost = 0
    }

    private func makeHeartbeat(_ pings: Pings, autoReply: Bool? = nil) -> Heartbeat {
        Heartbeat(
            scheduler: scheduler,
            ping: { reply in
                pings.replies.append(reply)
                if let autoReply {
                    reply(autoReply)
                }
            },
            onLost: { pings.lost += 1 }
        )
    }

    @Test("Pong reçu à chaque fois : un ping toutes les 5 s, jamais de perte")
    func pongs() {
        let pings = Pings()
        let heartbeat = makeHeartbeat(pings, autoReply: true)
        heartbeat.start()
        scheduler.advance(by: Heartbeat.interval - 0.01)
        #expect(pings.replies.isEmpty)
        scheduler.advance(by: 0.01)
        #expect(pings.replies.count == 1)
        scheduler.advance(by: 4 * Heartbeat.interval)
        #expect(pings.replies.count == 5)
        #expect(pings.lost == 0)
        heartbeat.stop()
    }

    @Test("Sans pong avant le ping suivant : connexion perdue, une seule fois, et plus de ping")
    func missingPong() {
        let pings = Pings()
        let heartbeat = makeHeartbeat(pings)
        heartbeat.start()
        scheduler.advance(by: Heartbeat.interval)
        #expect(pings.replies.count == 1)
        scheduler.advance(by: Heartbeat.interval - 0.01)
        #expect(pings.lost == 0)
        scheduler.advance(by: 0.01)
        #expect(pings.lost == 1)
        scheduler.advance(by: 30)
        #expect(pings.lost == 1)
        #expect(pings.replies.count == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Pong tardif mais avant le ping suivant : la connexion tient")
    func latePong() {
        let pings = Pings()
        let heartbeat = makeHeartbeat(pings)
        heartbeat.start()
        scheduler.advance(by: Heartbeat.interval)
        scheduler.advance(by: 3)
        pings.replies[0](true)
        scheduler.advance(by: 2)
        #expect(pings.replies.count == 2)
        #expect(pings.lost == 0)
        heartbeat.stop()
    }

    @Test("Échec du ping : connexion perdue tout de suite")
    func pingError() {
        let pings = Pings()
        let heartbeat = makeHeartbeat(pings, autoReply: false)
        heartbeat.start()
        scheduler.advance(by: Heartbeat.interval)
        #expect(pings.lost == 1)
        scheduler.advance(by: 30)
        #expect(pings.lost == 1)
        #expect(pings.replies.count == 1)
    }

    @Test("Arrêté : plus de ping, et une réponse tardive est ignorée")
    func stopped() {
        let pings = Pings()
        let heartbeat = makeHeartbeat(pings)
        heartbeat.start()
        scheduler.advance(by: Heartbeat.interval)
        heartbeat.stop()
        pings.replies[0](false)
        scheduler.advance(by: 30)
        #expect(pings.lost == 0)
        #expect(pings.replies.count == 1)
        #expect(scheduler.pendingCount == 0)
    }
}
