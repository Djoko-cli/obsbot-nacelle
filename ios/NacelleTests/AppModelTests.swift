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
            video: VideoSession(scheduler: scheduler),
            scheduler: scheduler
        )
    }

    /// Ports des connexions ouvertes vers le nom Tailscale.
    private var openedPorts: [Int?] {
        transports.all.flatMap(\.opened).compactMap { if case let .url(url) = $0 { url.port } else { nil } }
    }

    @Test("Champ vide : connexion lancée quand même (Bonjour) ; une adresse saisie reconnecte tout de suite")
    func emptyField() {
        let model = makeModel()
        model.activate()
        #expect(model.isActive)
        #expect(openedPorts.isEmpty)
        #expect(model.bannerText == "Connexion…")
        model.settings = complete
        #expect(openedPorts.count == 1)
        model.deactivate()
    }

    @Test("Appairage par QR : l'adresse du Mac va dans le champ vide, sans reconnexion")
    func addressRemembered() throws {
        let model = makeModel()
        model.activate()
        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.168.0.10&p=1990"))
        model.pair(with: link)
        let transport = try #require(transports.last)
        transport.remoteAddress = "192.0.2.30"
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
        #expect(model.settings.host == "192.0.2.30")
        #expect(model.settings.ptzdPort == 1990)
        #expect(SettingsStore(defaults: defaults).load() == ConnectionSettings(host: "192.0.2.30", ptzdPort: 1990))
        #expect(transport.closeCount == 0)
        #expect(transports.all.count == 1)
        model.deactivate()
    }

    @Test("Écran d'appairage : tant que l'iPhone n'est pas appairé ; « Appairage… », puis « QR code refusé »")
    func pairingScreen() throws {
        let model = makeModel()
        model.activate()
        #expect(model.needsPairing)
        #expect(model.pairingStatus == nil)
        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.168.0.10&p=1985"))
        model.pair(with: link)
        #expect(model.pairingStatus == "Appairage…")
        let transport = try #require(transports.last)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.error(code: .pairingClosed, message: "x"))))
        #expect(model.pairingStatus == "QR code refusé : relancez l'appairage sur le Mac")
        #expect(model.needsPairing)
        model.pair(with: link)
        let second = try #require(transports.last)
        second.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        second.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
        #expect(!model.needsPairing)
        #expect(model.pairingStatus == nil)
        model.deactivate()
    }

    @Test("Appairage par QR : un champ déjà rempli n'est pas modifié")
    func addressKept() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.168.0.10&p=1985"))
        model.pair(with: link)
        let transport = try #require(transports.last)
        transport.remoteAddress = "192.0.2.30"
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
        #expect(model.settings == complete)
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

    /// Connexion authentifiée par la dernière connexion ouverte, puis cet état de ptzd.
    private func connect(privacy: Bool) throws -> FakeTransport {
        let transport = try #require(transports.last)
        transport.emit(.opened)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.authenticated)))
        try send(privacy: privacy, on: transport)
        return transport
    }

    private func send(privacy: Bool, aiTracking: AITracking = .unknown, on transport: FakeTransport) throws {
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false, aiTracking: aiTracking)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(snapshot))))
    }

    @Test("QR refusé alors que l'iPhone est appairé : avis 5 s dans le bandeau, puis le bandeau normal")
    func refusedQRNotice() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        _ = try connect(privacy: false)
        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.168.0.10&p=1985"))
        model.pair(with: link)
        let qr = try #require(transports.all.last { $0.opened.contains { if case .tls = $0 { true } else { false } } })
        qr.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        qr.emit(.message(try NacelleCodec.encode(ServerMessage.error(code: .pairingClosed, message: "x"))))
        #expect(model.bannerText == "QR code refusé : relancez l'appairage sur le Mac")
        #expect(!model.needsPairing)
        scheduler.advance(by: AppModel.noticeDuration)
        #expect(model.bannerText != "QR code refusé : relancez l'appairage sur le Mac")
        model.deactivate()
    }

    @Test("Suivi IA : bouton selon le dernier ordre, grisé en vie privée ; il envoie l'ordre inverse")
    func aiTrackingButton() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        #expect(!model.aiToggleEnabled)
        let transport = try connect(privacy: false)
        #expect(model.aiToggleEnabled)
        #expect(!model.aiTrackingOn)
        model.toggleAITracking()
        try send(privacy: false, aiTracking: .on, on: transport)
        #expect(model.aiTrackingOn)
        model.toggleAITracking()
        let sent = transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
        #expect(sent.filter { if case .aiTracking = $0 { true } else { false } } == [.aiTracking(on: true), .aiTracking(on: false)])
        try send(privacy: true, aiTracking: .off, on: transport)
        #expect(!model.aiToggleEnabled)
        model.deactivate()
    }

    @Test("Son : coupé au premier lancement ; le choix est retenu et joué une fois l'état de ptzd connu")
    func soundPreference() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        #expect(!model.soundWanted)
        model.activate()
        _ = try connect(privacy: false)
        #expect(!model.video.playsAudio)
        model.soundWanted = true
        #expect(model.video.playsAudio)
        #expect(SettingsStore(defaults: defaults).soundOn)
        model.deactivate()
        let again = makeModel()
        #expect(again.soundWanted)
        again.activate()
        #expect(!again.video.playsAudio)
        _ = try connect(privacy: false)
        #expect(again.video.playsAudio)
        again.deactivate()
    }

    @Test("Vie privée : son coupé et bouton grisé sans autre action ; à la sortie, le choix revient")
    func soundInPrivacy() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.soundWanted = true
        model.activate()
        let transport = try connect(privacy: true)
        #expect(!model.soundPlaying)
        #expect(!model.soundToggleEnabled)
        #expect(!model.video.playsAudio)
        #expect(model.soundWanted)
        try send(privacy: false, on: transport)
        #expect(model.soundPlaying)
        #expect(model.soundToggleEnabled)
        #expect(model.video.playsAudio)
        model.deactivate()
    }

    @Test("Connexion à ptzd perdue pendant que le son joue : coupé, car la vie privée n'est plus connue")
    func soundCutWhenStateLost() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.soundWanted = true
        model.activate()
        let transport = try connect(privacy: false)
        #expect(model.video.playsAudio)
        transport.emit(.closed)
        #expect(!model.video.playsAudio)
        #expect(!model.soundToggleEnabled)
        model.deactivate()
    }

    @Test("Connexion à ptzd perdue en vie privée : le son reste coupé, la vidéo continuant sans ptzd")
    func soundWhenStateLost() throws {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.soundWanted = true
        model.activate()
        let transport = try connect(privacy: true)
        transport.emit(.closed)
        #expect(model.ptz.state == nil)
        #expect(!model.soundPlaying)
        #expect(!model.soundToggleEnabled)
        #expect(!model.video.playsAudio)
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
