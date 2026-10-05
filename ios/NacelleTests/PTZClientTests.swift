import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Client ptzd")
struct PTZClientTests {
    let transport = FakeTransport()
    let scheduler = FakeScheduler()
    let client: PTZClient
    let url = URL(string: "ws://mac.exemple.ts.net:1985")!

    init() {
        client = PTZClient(transport: transport, scheduler: scheduler)
    }

    private func decoded() -> [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    private func connect() {
        client.start(url: url)
        transport.emit(.opened)
    }

    @Test("À l'ouverture : connecté, et prise en main envoyée")
    func takeControlOnOpen() {
        connect()
        #expect(transport.openedURLs == [url])
        #expect(client.link == .connected)
        #expect(decoded() == [.takeControl])
    }

    @Test("Joystick hors du centre : move tout de suite, puis 10 fois par seconde")
    func repeatsMove() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        scheduler.advance(by: 0.35)
        #expect(decoded() == [.takeControl] + Array(repeating: .move(pan: 0.5, tilt: 0), count: 4))
    }

    @Test("Relâchement : move 0,0 une fois, puis plus rien")
    func releaseSendsStopOnce() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(.zero)
        client.setJoystick(.zero)
        scheduler.advance(by: 1)
        #expect(decoded() == [.takeControl, .move(pan: 0.5, tilt: 0), .move(pan: 0, tilt: 0)])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Un changement de consigne est envoyé sans attendre le prochain tic")
    func newVectorImmediately() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(JoystickVector(pan: 0, tilt: -1))
        #expect(decoded().last == .move(pan: 0, tilt: -1))
        scheduler.advance(by: 0.1)
        #expect(decoded().last == .move(pan: 0, tilt: -1))
    }

    @Test("L'état reçu est publié ; une erreur est retenue")
    func receivesState() throws {
        connect()
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 2, tilt: -1, zoom: 33, moving: false)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(snapshot))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.error(code: .privacyActive, message: "x"))))
        transport.emit(.message("pas du json"))
        #expect(client.state == snapshot)
        #expect(client.lastError == .privacyActive)
    }

    @Test("Échec de connexion : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(url: url)
        transport.emit(.closed)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        for delay in [1.0, 2, 4, 8, 8] {
            let before = transport.openedURLs.count
            scheduler.advance(by: delay - 0.01)
            #expect(transport.openedURLs.count == before)
            scheduler.advance(by: 0.01)
            #expect(transport.openedURLs.count == before + 1)
            transport.emit(.closed)
        }
    }

    @Test("Une connexion réussie efface « injoignable » et remet l'espacement à 1 s")
    func recovery() {
        client.start(url: url)
        transport.emit(.closed)
        scheduler.advance(by: 1)
        transport.emit(.opened)
        #expect(!client.isUnreachable)
        transport.emit(.closed)
        #expect(!client.isUnreachable)
        let before = transport.openedURLs.count
        scheduler.advance(by: 1)
        #expect(transport.openedURLs.count == before + 1)
    }

    @Test("Coupure : le mouvement s'arrête et l'état est oublié")
    func closeStopsRepeating() throws {
        connect()
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(
            StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: true)
        ))))
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        transport.emit(.closed)
        let sentAtClose = transport.sent.count
        scheduler.advance(by: 0.5)
        #expect(transport.sent.count == sentAtClose)
        #expect(client.state == nil)
    }

    @Test("Arrière-plan : move 0,0 si on pilotait, fermeture, aucune reconnexion")
    func stop() {
        connect()
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        client.stop()
        #expect(decoded().last == .move(pan: 0, tilt: 0))
        #expect(transport.closeCount >= 1)
        #expect(client.link == .idle)
        transport.emit(.closed)
        scheduler.advance(by: 10)
        #expect(transport.openedURLs.count == 1)
    }

    @Test("Hors connexion, rien n'est envoyé")
    func noSendWhileDisconnected() {
        client.start(url: url)
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(transport.sent.isEmpty)
    }

    @Test("Zoom et vie privée")
    func zoomAndPrivacy() {
        connect()
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(decoded() == [.takeControl, .zoom(value: 40), .privacy(on: true)])
    }
}
