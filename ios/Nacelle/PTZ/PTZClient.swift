import Foundation
import NacelleProtocol
import Network
import Observation
import os

/// Dialogue avec ptzd (spec § 7.2, spec accès local § 8) : à chaque connexion, le nom Tailscale
/// et le service Bonjour du réseau local sont essayés ensemble ; la première connexion
/// authentifiée l'emporte. Puis prise en main, `move` répété 10 fois par seconde tant que le
/// joystick est hors du centre, reconnexion espacée.
@MainActor
@Observable
final class PTZClient {
    enum Link: Equatable {
        case idle
        case connecting
        case connected
        case waitingToRetry
    }

    /// Ce qui empêche l'authentification. Un verdict de ptzd par Tailscale (`unpaired`, `rejected`,
    /// `badCode`) arrête les reconnexions jusqu'à ce que l'utilisateur agisse. `needsTailscale` et les
    /// verdicts reçus d'un service du réseau local les laissent continuer ; effacés à chaque nouvelle tentative.
    enum AuthIssue: Equatable {
        /// Pas de clé, ou ptzd ne connaît pas cet iPhone.
        case unpaired
        /// Signature refusée.
        case rejected
        /// Code d'appairage faux, expiré ou déjà utilisé.
        case badCode
        /// Un code attend, mais Tailscale n'a pas répondu : l'appairage ne passe que par Tailscale
        /// (spec accès local § 8.3). Les reconnexions continuent.
        case needsTailscale
    }

    /// Pourquoi une négociation vidéo n'a pas abouti.
    enum NegotiationError: Error, Equatable {
        /// Pas de connexion authentifiée dans le délai.
        case notConnected
        /// Connexion perdue ou fermée pendant la négociation.
        case connectionLost
        /// Pas de réponse de ptzd dans le délai.
        case timeout
        /// go2rtc n'a pas répondu à ptzd (`webrtcError`).
        case relay(String)
    }

    static let repeatInterval: TimeInterval = 0.1
    /// Délai d'une négociation vidéo, attente de la connexion comprise.
    static let negotiationTimeout: TimeInterval = 10
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]
    /// Temps laissé à Bonjour pour trouver ptzd sur le réseau local, à chaque tentative.
    static let discoveryWindow: TimeInterval = 3
    /// Temps laissé à chaque connexion pour s'authentifier, comme ptzd côté serveur.
    static let authTimeout: TimeInterval = 10
    private static let logger = Logger(subsystem: "io.github.djoko-cli.nacelle", category: "ptz")

    private(set) var link: Link = .idle
    /// Dernier état reçu de ptzd ; nil hors connexion.
    private(set) var state: StateSnapshot?
    /// Dernière erreur renvoyée par ptzd.
    private(set) var lastError: ErrorCode?
    /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
    /// Remis à faux par `start(url:)` et `stop()` : le bandeau revient à « Connexion… ».
    private(set) var isUnreachable = false
    private(set) var authIssue: AuthIssue?
    /// Cet iPhone s'est déjà authentifié, ou vient d'être appairé (enregistré).
    private(set) var isPaired: Bool

    @ObservationIgnored private let makeTransport: (WebSocketEndpoint) -> any WebSocketTransport
    @ObservationIgnored private let browser: any ServiceBrowser
    @ObservationIgnored private let keys: any DeviceKeyStoring
    @ObservationIgnored private let pairingRecord: PairingRecord
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var openedThisAttempt = false
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var active: Candidate?
    @ObservationIgnored private var nextCandidateID = 0
    @ObservationIgnored private var foundLocal = false
    /// La connexion Tailscale de la tentative en cours s'est ouverte.
    @ObservationIgnored private var tailscaleOpened = false
    /// Verdict d'un service du réseau local pour la tentative en cours : affiché si la tentative
    /// échoue sans autre verdict, sans arrêter les reconnexions.
    @ObservationIgnored private var localIssue: AuthIssue?
    /// `authIssue` vient d'un verdict qui arrête les reconnexions (`giveUp`) : conservé d'une tentative à l'autre.
    @ObservationIgnored private var authIssueBlocks = false
    @ObservationIgnored private var discovery: (any Cancellable)?
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var repeater: (any Cancellable)?
    @ObservationIgnored private var currentMove = JoystickVector.zero
    /// Code saisi dans les réglages, envoyé au prochain défi.
    @ObservationIgnored private var pendingCode: String?
    @ObservationIgnored private var pairingCandidate: Candidate?
    @ObservationIgnored private var nextOfferID = 0
    /// Négociations vidéo en attente de `webrtcAnswer`, par identifiant d'offre.
    @ObservationIgnored private var negotiations: [Int: CheckedContinuation<String, any Error>] = [:]
    /// Négociations en attente d'une connexion authentifiée.
    @ObservationIgnored private var waitingForLink: [Int: CheckedContinuation<Void, any Error>] = [:]

    /// Une connexion en cours d'essai ou retenue.
    private final class Candidate {
        let id: Int
        let transport: any WebSocketTransport
        /// Ouverte vers un service Bonjour du réseau local (pas le nom Tailscale).
        let isLocal: Bool
        /// Défi reçu, en attente de réponse.
        var nonce: Data?
        /// `auth` envoyé : seule une telle connexion peut recevoir un `authenticated` valable.
        var authSent = false
        /// Échéance d'authentification.
        var deadline: (any Cancellable)?

        init(id: Int, transport: any WebSocketTransport, isLocal: Bool) {
            self.id = id
            self.transport = transport
            self.isLocal = isLocal
        }
    }

    init(
        makeTransport: @escaping (WebSocketEndpoint) -> any WebSocketTransport,
        browser: any ServiceBrowser,
        keys: any DeviceKeyStoring,
        pairingRecord: PairingRecord,
        scheduler: any Scheduler,
        deviceName: String = "iPhone"
    ) {
        self.makeTransport = makeTransport
        self.browser = browser
        self.keys = keys
        self.pairingRecord = pairingRecord
        self.scheduler = scheduler
        self.deviceName = deviceName
        isPaired = pairingRecord.isPaired
        browser.onFound = { [weak self] endpoint in
            self?.found(endpoint)
        }
    }

    func start(url: URL) {
        self.url = url
        attempt = 0
        isUnreachable = false
        retry?.cancel()
        retry = nil
        connect()
    }

    /// Passage en arrière-plan : arrêt de la nacelle, puis fermeture.
    func stop() {
        if currentMove != .zero {
            send(.move(pan: 0, tilt: 0))
        }
        currentMove = .zero
        stopRepeating()
        retry?.cancel()
        retry = nil
        url = nil
        closeAll()
        link = .idle
        state = nil
        isUnreachable = false
        failNegotiations(.connectionLost)
    }

    /// Négociation vidéo relayée par ptzd (spec accès local § 8.4) : attend la connexion
    /// authentifiée si besoin, puis envoie l'offre ; 10 s au plus en tout.
    func negotiate(offer: String) async throws -> String {
        nextOfferID += 1
        let id = nextOfferID
        let deadline = scheduler.schedule(after: Self.negotiationTimeout) { [weak self] in
            self?.expire(id)
        }
        defer { deadline.cancel() }
        if link != .connected {
            try await withCheckedThrowingContinuation { continuation in
                waitingForLink[id] = continuation
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            negotiations[id] = continuation
            send(.webrtcOffer(id: id, sdp: offer))
        }
    }

    private func expire(_ id: Int) {
        waitingForLink.removeValue(forKey: id)?.resume(throwing: NegotiationError.notConnected)
        negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.timeout)
    }

    private func failNegotiations(_ error: NegotiationError) {
        let waiting = waitingForLink
        let pending = negotiations
        waitingForLink = [:]
        negotiations = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
        pending.values.forEach { $0.resume(throwing: error) }
    }

    /// Appairage avec le code de `ptzd pair` : envoyé au prochain défi, connexion relancée.
    func pair(code: String) {
        pendingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        authIssue = nil
        authIssueBlocks = false
        restart()
    }

    /// Oublie la clé et l'appairage ; ptzd refusera cet iPhone jusqu'au prochain appairage.
    func forgetPairing() {
        keys.delete()
        setPaired(false)
        pendingCode = nil
        restart()
    }

    func setJoystick(_ vector: JoystickVector) {
        let wasMoving = currentMove != .zero
        currentMove = vector
        guard vector != .zero else {
            stopRepeating()
            if wasMoving {
                send(.move(pan: 0, tilt: 0))
            }
            return
        }
        send(.move(pan: vector.pan, tilt: vector.tilt))
        if repeater == nil {
            scheduleRepeat()
        }
    }

    func setZoom(_ value: Int) {
        send(.zoom(value: value))
    }

    func setPrivacy(_ on: Bool) {
        send(.privacy(on: on))
    }

    func takeControl() {
        send(.takeControl)
    }

    // MARK: - Connexions

    private func restart() {
        guard url != nil else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        connect()
    }

    /// Une tentative : le nom Tailscale tout de suite, le réseau local si Bonjour trouve ptzd.
    private func connect() {
        guard let url else { return }
        closeAll()
        link = .connecting
        openedThisAttempt = false
        tailscaleOpened = false
        foundLocal = false
        localIssue = nil
        if !authIssueBlocks {
            authIssue = nil
        }
        open(.url(url))
        // Le réseau local passe en TLS : sans secret remis à l'appairage, pas d'essai local.
        if keys.load() != nil, keys.lanKey() != nil {
            browser.start()
        }
        discovery = scheduler.schedule(after: Self.discoveryWindow) { [weak self] in
            self?.discoveryEnded()
        }
    }

    private func found(_ endpoint: NWEndpoint) {
        guard link == .connecting, active == nil, !foundLocal,
              let key = keys.load(), let lanKey = keys.lanKey() else { return }
        foundLocal = true
        open(.service(endpoint, LANCredentials(identity: key.deviceID, key: lanKey)))
    }

    private func discoveryEnded() {
        discovery = nil
        browser.stop()
        if candidates.isEmpty, active == nil {
            attemptFailed()
        }
    }

    private func open(_ endpoint: WebSocketEndpoint) {
        nextCandidateID += 1
        let isLocal: Bool
        if case .service = endpoint {
            isLocal = true
        } else {
            isLocal = false
        }
        let candidate = Candidate(id: nextCandidateID, transport: makeTransport(endpoint), isLocal: isLocal)
        candidates.append(candidate)
        candidate.transport.onEvent = { [weak self, weak candidate] event in
            guard let self, let candidate else { return }
            self.handle(event, from: candidate)
        }
        candidate.deadline = scheduler.schedule(after: Self.authTimeout) { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.close(candidate)
            self.failAttemptIfOver()
        }
        candidate.transport.open(endpoint)
    }

    private func closeAll() {
        discovery?.cancel()
        discovery = nil
        browser.stop()
        for candidate in candidates {
            candidate.deadline?.cancel()
            candidate.transport.onEvent = nil
            candidate.transport.close()
        }
        candidates = []
        active = nil
        pairingCandidate = nil
    }

    private func close(_ candidate: Candidate) {
        candidate.deadline?.cancel()
        candidate.transport.onEvent = nil
        candidate.transport.close()
        candidates.removeAll { $0 === candidate }
        if pairingCandidate === candidate {
            pairingCandidate = nil
        }
    }

    private func handle(_ event: TransportEvent, from candidate: Candidate) {
        switch event {
        case .opened:
            openedThisAttempt = true
            if !candidate.isLocal {
                tailscaleOpened = true
            }
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            if candidate === active {
                handleActive(message)
            } else {
                handleHandshake(message, from: candidate)
            }
        case .closed:
            candidate.deadline?.cancel()
            candidates.removeAll { $0 === candidate }
            if pairingCandidate === candidate {
                pairingCandidate = nil
            }
            if candidate === active {
                active = nil
                lost()
            } else {
                failAttemptIfOver()
            }
        }
    }

    /// La tentative échoue quand plus aucune connexion n'est en vie et que Bonjour a fini de chercher.
    private func failAttemptIfOver() {
        if active == nil, candidates.isEmpty, discovery == nil, link == .connecting {
            attemptFailed()
        }
    }

    private func handleHandshake(_ message: ServerMessage, from candidate: Candidate) {
        switch message {
        case let .challenge(nonce):
            answer(nonce, on: candidate)
        case let .paired(_, lanKey):
            // Seule la connexion qui a envoyé le code (Tailscale) peut confirmer l'appairage.
            guard candidate === pairingCandidate else { return }
            // Sans le secret, seul Tailscale reste : l'appairage est valable quand même.
            do {
                try keys.saveLANKey(lanKey)
            } catch {
                Self.logger.error("Secret du réseau local non enregistré : \(String(describing: error), privacy: .public)")
            }
            pendingCode = nil
            pairingCandidate = nil
            setPaired(true)
            for waiting in candidates where waiting.nonce != nil {
                authenticate(waiting)
            }
        case .authenticated:
            // Un `authenticated` sans `auth` envoyé n'est pas une réponse : connexion fermée.
            guard candidate.authSent else {
                close(candidate)
                failAttemptIfOver()
                return
            }
            becomeActive(candidate)
        case let .error(code, _):
            handleHandshakeError(code, from: candidate)
        default:
            break
        }
    }

    /// Un service du réseau local n'est pas authentifié : son verdict ne ferme que sa connexion
    /// et ne touche ni l'appairage ni le code. Seule la connexion Tailscale peut tout arrêter.
    private func handleHandshakeError(_ code: ErrorCode, from candidate: Candidate) {
        let issue: AuthIssue
        switch code {
        case .unpaired:
            issue = .unpaired
        case .authFailed:
            issue = .rejected
        case .badCode, .pairingClosed:
            issue = .badCode
        default:
            lastError = code
            return
        }
        if candidate.isLocal {
            localIssue = issue
            close(candidate)
            failAttemptIfOver()
            return
        }
        switch issue {
        case .unpaired:
            setPaired(false)
        case .badCode:
            pendingCode = nil
        default:
            break
        }
        giveUp(issue)
    }

    private func answer(_ nonce: Data, on candidate: Candidate) {
        candidate.nonce = nonce
        if let code = pendingCode {
            // Le code ne part que par Tailscale ; la connexion locale attend `paired`.
            guard !candidate.isLocal else { return }
            // Un seul appairage à la fois : les autres connexions attendent `paired`.
            guard pairingCandidate == nil else { return }
            guard let key = try? keys.loadOrCreate() else {
                giveUp(.unpaired)
                return
            }
            pairingCandidate = candidate
            send(.pair(code: code, publicKey: key.publicKeyX963, name: deviceName), on: candidate)
        } else if keys.load() != nil {
            authenticate(candidate)
        } else {
            setPaired(false)
            giveUp(.unpaired)
        }
    }

    private func authenticate(_ candidate: Candidate) {
        guard let nonce = candidate.nonce, let key = keys.load(), let signature = try? key.signChallenge(nonce) else { return }
        candidate.nonce = nil
        candidate.authSent = true
        send(.auth(deviceID: key.deviceID, signature: signature), on: candidate)
    }

    private func becomeActive(_ candidate: Candidate) {
        guard active == nil else {
            close(candidate)
            return
        }
        candidate.deadline?.cancel()
        candidate.deadline = nil
        active = candidate
        for other in candidates where other !== candidate {
            close(other)
        }
        discovery?.cancel()
        discovery = nil
        browser.stop()
        link = .connected
        attempt = 0
        isUnreachable = false
        authIssue = nil
        authIssueBlocks = false
        setPaired(true)
        send(.takeControl)
        let waiting = waitingForLink
        waitingForLink = [:]
        waiting.values.forEach { $0.resume() }
    }

    private func handleActive(_ message: ServerMessage) {
        switch message {
        case let .state(snapshot):
            state = snapshot
        case let .error(code, _):
            lastError = code
        case let .webrtcAnswer(id, sdp):
            negotiations.removeValue(forKey: id)?.resume(returning: sdp)
        case let .webrtcError(id, message):
            negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.relay(message))
        case .challenge, .authenticated, .paired:
            break
        }
    }

    /// Plus de reconnexion : l'utilisateur doit appairer l'iPhone (spec accès local § 8.5).
    private func giveUp(_ issue: AuthIssue) {
        authIssue = issue
        authIssueBlocks = true
        retry?.cancel()
        retry = nil
        closeAll()
        link = .idle
        failNegotiations(.notConnected)
    }

    private func lost() {
        stopRepeating()
        currentMove = .zero
        state = nil
        let pending = negotiations
        negotiations = [:]
        pending.values.forEach { $0.resume(throwing: NegotiationError.connectionLost) }
        scheduleRetry()
    }

    private func attemptFailed() {
        closeAll()
        if !openedThisAttempt {
            isUnreachable = true
        }
        if pendingCode != nil, !tailscaleOpened {
            authIssue = .needsTailscale
        } else if let localIssue {
            authIssue = localIssue
        }
        state = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard url != nil else {
            link = .idle
            return
        }
        closeAll()
        link = .waitingToRetry
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func setPaired(_ paired: Bool) {
        guard isPaired != paired else { return }
        isPaired = paired
        pairingRecord.isPaired = paired
    }

    // MARK: - Envoi

    private func send(_ message: ClientMessage) {
        guard link == .connected, let active else { return }
        send(message, on: active)
    }

    private func send(_ message: ClientMessage, on candidate: Candidate) {
        guard let text = try? NacelleCodec.encode(message) else { return }
        candidate.transport.send(text)
    }

    private func scheduleRepeat() {
        repeater = scheduler.schedule(after: Self.repeatInterval) { [weak self] in
            self?.repeatTick()
        }
    }

    private func repeatTick() {
        repeater = nil
        guard currentMove != .zero else { return }
        send(.move(pan: currentMove.pan, tilt: currentMove.tilt))
        scheduleRepeat()
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}

/// Mémoire de l'appairage, pour l'afficher dans les réglages.
final class PairingRecord {
    static let key = "paired"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isPaired: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
