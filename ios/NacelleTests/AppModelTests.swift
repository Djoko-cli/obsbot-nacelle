import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Modèle de l'app")
struct AppModelTests {
    let transports = FakeTransports()
    let scheduler = FakeScheduler()
    let defaults = UserDefaults(suiteName: "nacelle-appmodel-\(UUID().uuidString)")!
    let complete = ConnectionSettings(host: "mac.exemple.ts.net")

    private func makeModel() -> AppModel {
        let transports = transports
        let keys = FakeKeyStore()
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        return AppModel(
            store: SettingsStore(defaults: defaults),
            ptz: PTZClient(
                makeTransport: { _ in transports.make() },
                browser: FakeBrowser(),
                keys: keys,
                pairingRecord: PairingRecord(defaults: defaults),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler)
        )
    }

    /// Ports des connexions ouvertes vers le nom Tailscale.
    private var openedPorts: [Int?] {
        transports.all.flatMap(\.opened).compactMap { if case let .url(url) = $0 { url.port } else { nil } }
    }

    @Test("Premier lancement : les réglages enregistrés au premier plan connectent tout de suite")
    func firstLaunch() {
        let model = makeModel()
        model.activate()
        #expect(openedPorts.isEmpty)
        #expect(model.bannerText == nil)
        model.settings = complete
        #expect(openedPorts.count == 1)
        #expect(model.isActive)
        model.deactivate()
    }

    @Test("Déjà actif : un nouveau passage au premier plan ne relance rien")
    func activateIsIdempotent() {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        model.activate()
        #expect(openedPorts.count == 1)
        model.deactivate()
    }

    @Test("En arrière-plan, de nouveaux réglages sont enregistrés sans connecter")
    func settingsInBackground() {
        let model = makeModel()
        model.activate()
        model.deactivate()
        model.settings = complete
        #expect(openedPorts.isEmpty)
        #expect(SettingsStore(defaults: defaults).load() == complete)
    }

    @Test("Réglages modifiés une fois connecté : reconnexion à la nouvelle adresse")
    func settingsChangeReconnects() {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        model.settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
        #expect(openedPorts == [1985, 1999])
        model.deactivate()
    }

    @Test("Inactif (Centre de contrôle, appel) : la nacelle s'arrête, la connexion reste ouverte")
    func pauseStopsMovement() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        let transport = try #require(transports.last)
        transport.emit(.opened)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.authenticated)))
        model.ptz.setJoystick(JoystickVector(pan: 1, tilt: 0))
        model.pause()
        let sentAtPause = transport.sent.count
        scheduler.advance(by: 1)
        let sent = transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
        #expect(sent.last == .move(pan: 0, tilt: 0))
        #expect(transport.sent.count == sentAtPause)
        #expect(transport.closeCount == 0)
        #expect(model.isActive)
        #expect(model.ptz.link == .connected)
        model.deactivate()
    }
}
