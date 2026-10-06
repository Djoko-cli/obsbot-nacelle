import CryptoKit
import Foundation
import NacelleProtocol
import Network
import Testing
@testable import Nacelle

@MainActor
@Suite("Client ptzd")
struct PTZClientTests {
    let transports = FakeTransports()
    let browser = FakeBrowser()
    let keys = FakeKeyStore()
    let scheduler = FakeScheduler()
    let record = PairingRecord(defaults: UserDefaults(suiteName: "ptzclient-\(UUID().uuidString)")!)
    let client: PTZClient
    let url = URL(string: "ws://mac.exemple.ts.net:1985")!
    let service = NWEndpoint.service(name: "Nacelle", type: "_nacelle._tcp", domain: "local.", interface: nil)
    let nonce = Data(repeating: 7, count: 32)
    let lanKey = Data(repeating: 9, count: 32)

    init() {
        let transports = transports
        client = PTZClient(
            makeTransport: { _ in transports.make() },
            browser: browser,
            keys: keys,
            pairingRecord: record,
            scheduler: scheduler
        )
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
    }

    private var tailscale: FakeTransport {
        transports.to(.url(url))!
    }

    private func decoded(_ transport: FakeTransport) -> [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    private func emit(_ message: ServerMessage, on transport: FakeTransport) throws {
        transport.emit(.message(try NacelleCodec.encode(message)))
    }

    /// Ouverture, défi, signature, authentification, par Tailscale.
    private func connect() throws {
        client.start(url: url)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
    }

    /// Messages envoyés après l'authentification.
    private func commands(_ transport: FakeTransport) -> [ClientMessage] {
        decoded(transport).filter { if case .auth = $0 { false } else { true } }
    }

    // MARK: - Authentification

    @Test("Défi : réponse signée, vérifiable par ptzd")
    func answersChallenge() throws {
        client.start(url: url)
        tailscale.emit(.opened)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        guard case let .auth(deviceID, signature) = decoded(tailscale).first else {
            Issue.record("auth attendu")
            return
        }
        let key = try #require(keys.key)
        #expect(deviceID == key.deviceID)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: key.publicKeyX963))
    }

    @Test("Authentifié : connecté, prise en main envoyée, appairage retenu")
    func takeControlAfterAuth() throws {
        try connect()
        #expect(client.link == .connected)
        #expect(commands(tailscale) == [.takeControl])
        #expect(client.isPaired)
        #expect(record.isPaired)
    }

    @Test("Sans clé : « non appairé », plus de reconnexion")
    func noKey() throws {
        keys.key = nil
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    @Test("ptzd ne connaît pas l'iPhone : « non appairé », appairage oublié")
    func unpairedByServer() throws {
        record.isPaired = true
        try connect()
        client.stop()
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .unpaired, message: "x"), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(!client.isPaired)
        #expect(!record.isPaired)
        #expect(client.link == .idle)
    }

    @Test("Signature refusée : « refusé », plus de reconnexion")
    func rejected() throws {
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        tailscale.emit(.closed)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Appairage

    @Test("Appairage : clé créée, code et clé envoyés, puis auth sur le même défi")
    func pairing() throws {
        keys.key = nil
        client.start(url: url)
        client.pair(code: " 042917 ")
        try emit(.challenge(nonce: nonce), on: tailscale)
        let key = try #require(keys.key)
        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: tailscale)
        #expect(client.isPaired)
        guard case .auth = decoded(tailscale).last else {
            Issue.record("auth attendu après paired")
            return
        }
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
    }

    @Test("Code refusé : « code refusé », plus de reconnexion, le code n'est pas réessayé")
    func badCode() throws {
        client.start(url: url)
        client.pair(code: "000000")
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .badCode, message: "x"), on: tailscale)
        #expect(client.authIssue == .badCode)
        #expect(tailscale.closeCount >= 1)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("Pas d'appairage en cours sur le Mac : « code refusé » aussi")
    func pairingClosed() throws {
        client.start(url: url)
        client.pair(code: "123456")
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .pairingClosed, message: "x"), on: tailscale)
        #expect(client.authIssue == .badCode)
    }

    @Test("Oublier l'appairage : clé supprimée, puis « non appairé »")
    func forget() throws {
        try connect()
        client.forgetPairing()
        #expect(keys.key == nil)
        #expect(!client.isPaired)
        try emit(.challenge(nonce: nonce), on: try #require(transports.last))
        #expect(client.authIssue == .unpaired)
    }

    // MARK: - Choix du chemin

    @Test("Les deux chemins essayés ; le premier authentifié l'emporte, l'autre est fermé")
    func race() throws {
        client.start(url: url)
        #expect(browser.isRunning)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
        #expect(commands(local) == [.takeControl])
        #expect(tailscale.closeCount >= 1)
        #expect(!browser.isRunning)
        // Une authentification tardive du perdant est ignorée.
        try emit(.authenticated, on: tailscale)
        #expect(commands(tailscale).isEmpty)
    }

    @Test("Bonjour ne trouve rien : Tailscale seul, sans message")
    func noLocalService() throws {
        client.start(url: url)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(!browser.isRunning)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(!client.isUnreachable)
    }

    @Test("Tailscale coupé à la maison : pas d'échec tant que Bonjour cherche")
    func tailscaleDownAtHome() throws {
        client.start(url: url)
        tailscale.emit(.closed)
        #expect(client.link == .connecting)
        #expect(!client.isUnreachable)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
    }

    @Test("Un seul service local par tentative")
    func oneLocalCandidate() {
        client.start(url: url)
        browser.find(service)
        browser.find(.service(name: "Nacelle", type: "_nacelle._tcp", domain: "local.", interface: nil))
        #expect(transports.all.count == 2)
    }

    @Test("Appairage avec deux chemins : la locale, première au défi, n'envoie jamais le code ; elle s'authentifie après paired")
    func pairingWithTwoPaths() throws {
        keys.key = nil
        client.start(url: url)
        client.pair(code: "042917")
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.challenge(nonce: nonce), on: local)
        #expect(decoded(local).isEmpty)
        try emit(.challenge(nonce: nonce), on: tailscale)
        let key = try #require(keys.key)
        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
        #expect(decoded(local).isEmpty)
        // Un faux « paired » venu du réseau local ne compte pas.
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: local)
        #expect(decoded(local).isEmpty)
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: tailscale)
        #expect(decoded(local).contains { if case .auth = $0 { true } else { false } })
        #expect(decoded(tailscale).contains { if case .auth = $0 { true } else { false } })
    }

    @Test("Erreur « non appairé » d'un service local : seule sa connexion est fermée, Tailscale s'authentifie")
    func localErrorClosesOnlyLocal() throws {
        try connect()
        client.stop()
        client.start(url: url)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(local.closeCount >= 1)
        #expect(tailscale.closeCount == 0)
        #expect(client.isPaired)
        #expect(record.isPaired)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
        #expect(client.isPaired)
    }

    @Test("Erreur d'un service local seul : problème affiché, reconnexions espacées maintenues")
    func localErrorOnlyCandidate() throws {
        client.start(url: url)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        tailscale.emit(.closed)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(client.authIssue == nil)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
        #expect(client.link == .connecting)
    }

    @Test("Code en attente sans Tailscale : « active Tailscale », puis le code part dès que Tailscale répond")
    func needsTailscale() throws {
        client.start(url: url)
        client.pair(code: "042917")
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        tailscale.emit(.closed)
        try emit(.challenge(nonce: nonce), on: local)
        #expect(decoded(local).isEmpty)
        local.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .needsTailscale)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        let key = try #require(keys.key)
        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
    }

    @Test("« authenticated » d'une connexion qui n'a pas envoyé auth : fermée, Tailscale peut encore gagner")
    func unsolicitedAuthenticated() throws {
        client.start(url: url)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.authenticated, on: local)
        #expect(local.closeCount >= 1)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
        #expect(commands(local).isEmpty)
    }

    @Test("Service local muet : fermé après 10 s, la tentative échoue et une nouvelle est planifiée")
    func silentLocalService() throws {
        client.start(url: url)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        tailscale.emit(.closed)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        scheduler.advance(by: PTZClient.authTimeout - 0.01)
        #expect(local.closeCount == 0)
        #expect(client.link == .connecting)
        scheduler.advance(by: 0.01)
        #expect(local.closeCount >= 1)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Le délai d'authentification est annulé quand la connexion gagne")
    func deadlineCancelledOnSuccess() throws {
        try connect()
        scheduler.advance(by: PTZClient.authTimeout * 2)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
    }

    @Test("Problème d'une tentative précédente : effacé au début de la suivante, sauf s'il arrête les reconnexions")
    func authIssueClearedPerAttempt() throws {
        client.start(url: url)
        client.pair(code: "042917")
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        tailscale.emit(.closed)
        local.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .needsTailscale)
        scheduler.advance(by: 1)
        #expect(client.link == .connecting)
        #expect(client.authIssue == nil)
    }

    @Test("Problème qui arrête les reconnexions : conservé quand l'app relance une tentative")
    func blockingIssueKept() throws {
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        client.start(url: url)
        #expect(client.authIssue == .rejected)
    }

    // MARK: - Reconnexion

    @Test("Échec des deux chemins : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        for delay in [1.0, 2, 4, 8, 8] {
            let before = transports.all.count
            scheduler.advance(by: delay - 0.01)
            #expect(transports.all.count == before)
            scheduler.advance(by: 0.01)
            #expect(transports.all.count == before + 1)
            transports.last?.emit(.closed)
            scheduler.advance(by: PTZClient.discoveryWindow)
        }
    }

    @Test("Une connexion réussie efface « injoignable » et remet l'espacement à 1 s")
    func recovery() throws {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow + 1)
        let second = try #require(transports.last)
        second.emit(.opened)
        try emit(.challenge(nonce: nonce), on: second)
        try emit(.authenticated, on: second)
        #expect(!client.isUnreachable)
        second.emit(.closed)
        #expect(!client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Arrêt ou nouveau départ : « injoignable » est effacé jusqu'au prochain échec")
    func unreachableResetOnStopAndStart() {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        client.stop()
        #expect(!client.isUnreachable)
        client.start(url: url)
        #expect(!client.isUnreachable)
        #expect(client.link == .connecting)
    }

    @Test("Coupure : le mouvement s'arrête et l'état est oublié")
    func closeStopsRepeating() throws {
        try connect()
        try emit(.state(StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: true)), on: tailscale)
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        tailscale.emit(.closed)
        let sentAtClose = tailscale.sent.count
        scheduler.advance(by: 0.5)
        #expect(tailscale.sent.count == sentAtClose)
        #expect(client.state == nil)
    }

    @Test("Arrière-plan : move 0,0 si on pilotait, fermeture, aucune reconnexion")
    func stop() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        client.stop()
        #expect(commands(tailscale).last == .move(pan: 0, tilt: 0))
        #expect(tailscale.closeCount >= 1)
        #expect(client.link == .idle)
        #expect(!browser.isRunning)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Commandes

    @Test("Joystick hors du centre : move tout de suite, puis 10 fois par seconde")
    func repeatsMove() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        scheduler.advance(by: 0.35)
        #expect(commands(tailscale) == [.takeControl] + Array(repeating: .move(pan: 0.5, tilt: 0), count: 4))
    }

    @Test("Relâchement : move 0,0 une fois, puis plus rien")
    func releaseSendsStopOnce() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(.zero)
        client.setJoystick(.zero)
        scheduler.advance(by: 1)
        #expect(commands(tailscale) == [.takeControl, .move(pan: 0.5, tilt: 0), .move(pan: 0, tilt: 0)])
    }

    @Test("Un changement de consigne est envoyé sans attendre le prochain tic")
    func newVectorImmediately() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(JoystickVector(pan: 0, tilt: -1))
        #expect(commands(tailscale).last == .move(pan: 0, tilt: -1))
    }

    @Test("L'état reçu est publié ; une erreur est retenue")
    func receivesState() throws {
        try connect()
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 2, tilt: -1, zoom: 33, moving: false)
        try emit(.state(snapshot), on: tailscale)
        try emit(.error(code: .privacyActive, message: "x"), on: tailscale)
        tailscale.emit(.message("pas du json"))
        #expect(client.state == snapshot)
        #expect(client.lastError == .privacyActive)
    }

    @Test("Avant l'authentification, rien n'est envoyé")
    func noSendBeforeAuth() {
        client.start(url: url)
        tailscale.emit(.opened)
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(tailscale.sent.isEmpty)
    }

    // MARK: - Vidéo relayée

    /// Laisse les tâches lancées sur le MainActor avancer jusqu'à leur prochaine attente.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    @Test("Négociation : offre envoyée avec un identifiant, réponse rendue")
    func negotiation() async throws {
        try connect()
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("Négociation avant la connexion : l'offre part dès l'authentification")
    func negotiationWaitsForLink() async throws {
        client.start(url: url)
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(tailscale.sent.isEmpty)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("webrtcError : erreur de relais ; connexion perdue : connectionLost")
    func negotiationFailures() async throws {
        try connect()
        let first = Task { try await client.negotiate(offer: "a") }
        await settle()
        try emit(.webrtcError(id: 1, message: "go2rtc ne répond pas."), on: tailscale)
        await #expect(throws: PTZClient.NegotiationError.relay("go2rtc ne répond pas.")) { try await first.value }

        let second = Task { try await client.negotiate(offer: "b") }
        await settle()
        tailscale.emit(.closed)
        await #expect(throws: PTZClient.NegotiationError.connectionLost) { try await second.value }
    }

    @Test("Sans connexion ni réponse : échec après 10 s")
    func negotiationTimeouts() async throws {
        client.start(url: url)
        let waiting = Task { try await client.negotiate(offer: "a") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.notConnected) { try await waiting.value }
        // Le délai d'authentification (10 s) a aussi fermé la connexion muette : nouvelle tentative.
        scheduler.advance(by: 1)

        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        let silent = Task { try await client.negotiate(offer: "b") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.timeout) { try await silent.value }
    }

    @Test("Zoom et vie privée")
    func zoomAndPrivacy() throws {
        try connect()
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(commands(tailscale) == [.takeControl, .zoom(value: 40), .privacy(on: true)])
    }
}
