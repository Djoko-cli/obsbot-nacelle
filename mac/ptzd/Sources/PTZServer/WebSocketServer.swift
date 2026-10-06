import Foundation
import NacelleProtocol
import Network
import PTZAuth
import PTZCore

/// Serveur WebSocket de ptzd : quelques adresses précises (jamais 0.0.0.0),
/// 4 clients authentifiés au plus (spec § 6.1 et § 6.10). Chaque connexion s'authentifie, sauf sur
/// 127.0.0.1 (spec accès local § 6.3). Les connexions anonymes ont leurs propres réserves, bornées
/// en tout et par adresse : un appareil du Wi-Fi ne peut pas occuper les places des clients.
/// Une place n'est jamais gardée par une connexion morte ou anonyme : 10 s pour s'authentifier,
/// connexion en attente, ping toutes les 10 s. Sur le réseau local, tout passe en TLS à clé
/// pré-partagée (spec accès local § 14) et l'appairage est refusé.
@MainActor
public final class WebSocketServer {
    /// Clients authentifiés ou de confiance (127.0.0.1 compris).
    public nonisolated static let maxClients = 4
    /// Connexions anonymes en attente d'authentification, en tout.
    public nonisolated static let maxPending = 8
    /// Connexions anonymes en attente d'authentification, par adresse distante.
    public nonisolated static let maxPendingPerAddress = 2
    public static let retryDelay: TimeInterval = 5
    /// Une connexion acceptée qui n'est pas authentifiée après ce délai libère sa place.
    public static let authTimeout: TimeInterval = 10
    /// Intervalle des pings envoyés à chaque client prêt.
    public static let pingInterval: TimeInterval = 10
    /// Un client sans pong depuis ce délai libère sa place.
    public static let pongTimeout: TimeInterval = 25
    /// Marque une poignée de main refusée. Network n'envoie alors aucune réponse, garde la
    /// connexion ouverte et la signale même prête (constaté avec le SDK de macOS 27) : on
    /// retrouve la marque dans ses métadonnées pour la fermer nous-mêmes.
    nonisolated static let rejectionMarker = (name: "X-Nacelle-Refus", value: "origin")

    /// Appelé quand l'écoute sur une adresse est prête, avec le port réellement
    /// ouvert (utile quand on demande le port 0).
    public var onReady: ((_ host: String, _ port: UInt16) -> Void)?

    private let hosts: [String]
    private let port: UInt16
    private let controller: PTZController
    private let authority: DeviceAuthority
    private let relay: any WebRTCRelay
    private let scheduler: any Scheduler
    private let log: LogSink
    private let trustLoopback: Bool
    private let localNetwork: Bool
    /// Adresses écoutées comme le réseau local (TLS, pas d'appairage) : pour les tests seulement,
    /// le vrai réseau local passant par `LocalNetworkListeners`.
    private let localHosts: Set<String>
    private var listeners: [String: NWListener] = [:]
    private var localListeners: LocalNetworkListeners?
    /// Échéance de l'appairage en cours.
    private var expiry: (any Cancellable)?
    private var clients: [ClientID: Client] = [:]
    private var nextID: ClientID = 1

    /// Une place occupée : la connexion, son authentification et ses minuteries, toutes annulées par `drop`.
    private struct Client {
        let connection: NWConnection
        /// Arrivée par une écoute en boucle locale (127.0.0.1, ::1) : authentifiée d'office.
        let trusted: Bool
        /// Adresse distante, pour la réserve des connexions anonymes.
        let address: String
        /// Arrivée par le réseau local (canal TLS) : l'appairage y est refusé.
        let local: Bool
        var authenticated = false
        /// Défi en cours ; consommé par le premier `auth`.
        var nonce: Data?
        var deadline: (any Cancellable)?
        var ping: (any Cancellable)?
        var pongDeadline: (any Cancellable)?
        /// Négociation vidéo en cours ; une nouvelle offre la remplace.
        var negotiation: Task<Void, Never>?

        func cancelTimers() {
            deadline?.cancel()
            ping?.cancel()
            pongDeadline?.cancel()
            negotiation?.cancel()
        }
    }

    /// Nombre de places occupées (tests).
    var clientCount: Int {
        clients.count
    }

    /// Les adresses en double ne sont écoutées qu'une fois (config.json peut déjà contenir 127.0.0.1).
    /// `trustLoopback` à faux (tests) impose l'authentification aussi sur 127.0.0.1 ; `localHosts` (tests)
    /// fait écouter ces adresses comme le réseau local.
    public init(
        hosts: [String],
        port: UInt16,
        controller: PTZController,
        authority: DeviceAuthority,
        relay: any WebRTCRelay,
        scheduler: any Scheduler,
        log: @escaping LogSink,
        trustLoopback: Bool = true,
        localNetwork: Bool = false,
        localHosts: Set<String> = []
    ) {
        self.hosts = hosts.reduce(into: []) { unique, host in
            if !unique.contains(host) {
                unique.append(host)
            }
        }
        self.port = port
        self.controller = controller
        self.authority = authority
        self.relay = relay
        self.scheduler = scheduler
        self.log = log
        self.trustLoopback = trustLoopback
        self.localNetwork = localNetwork
        self.localHosts = localHosts
        controller.onStateChange = { [weak self] snapshot in
            self?.broadcast(.state(snapshot))
        }
    }

    /// Ouvre l'écoute sur chaque adresse. En cas d'échec (adresse Tailscale pas
    /// encore là), réessaie toutes les 5 s pour cette adresse. Puis, si demandé, sur le
    /// réseau local, où chaque connexion doit s'authentifier.
    public func start() {
        for host in hosts.filter({ !localHosts.contains($0) }) {
            listen(on: host)
        }
        for host in localHosts.sorted() {
            listen(on: host)
        }
        if localNetwork {
            let local = LocalNetworkListeners(
                port: port,
                makeParameters: { [unowned self] in self.makeParameters(tls: self.localTLS()) },
                onConnection: { [weak self] connection in self?.accept(connection, trusted: false, local: true) },
                scheduler: scheduler,
                log: log
            )
            localListeners = local
            local.start()
        }
    }

    /// TLS à clé pré-partagée du réseau local : les secrets des appareils appairés et de l'appairage en cours,
    /// et le veto d'un appareil retiré depuis, relu à chaque poignée de main. `devices.json` illisible :
    /// aucun appareil, et une ligne de journal (spec accès local § 9).
    private func localTLS() -> NWProtocolTLS.Options {
        let authority = authority
        let identities: [String]
        do {
            identities = try authority.tlsIdentities()
        } catch {
            log("devices.json illisible : aucun appareil sur le réseau local.")
            identities = []
        }
        return NacelleTLS.server(identities: identities) { authority.tlsKey(for: $0) }
    }

    /// Relance les écoutes du réseau local, pour qu'elles connaissent le secret d'un nouvel appareil.
    private func rebuildLocalListeners() {
        localListeners?.rebuild()
        for host in localHosts {
            listeners.removeValue(forKey: host)?.cancel()
            listen(on: host)
        }
    }

    /// TCP avec keepalive, TLS si donné, et WebSocket, sans adresse locale : chaque écoute ajoute la sienne.
    private func makeParameters(tls: NWProtocolTLS.Options? = nil) -> NWParameters {
        // Keepalive TCP : une connexion morte (iPhone suspendu, réseau coupé) est fermée
        // après environ 25 s au lieu de garder une des 4 places indéfiniment.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        // Un navigateur envoie toujours Origin, nos clients (app iOS, nacelle-ws) jamais :
        // une page web ouverte sur le Mac ou le tailnet ne peut donc pas piloter la caméra.
        webSocket.setClientRequestHandler(.main) { [weak self] _, headers in
            guard headers.contains(where: { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }) else {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            MainActor.assumeIsolated { self?.log("Connexion refusée : en-tête Origin (navigateur).") }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [Self.rejectionMarker])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    private func listen(on host: String) {
        let local = localHosts.contains(host)
        let parameters = makeParameters(tls: local ? localTLS() : nil)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            retryLater(host, after: error)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(host, state) }
        }
        let trusted = !local && trustLoopback && Self.isLoopback(host)
        // L'écoute Tailscale (ni boucle locale ni réseau local) n'admet que des adresses Tailscale :
        // l'appairage y est permis parce que WireGuard authentifie les pairs (spec accès local § 12).
        // Les écoutes en boucle locale en sont dispensées, même sans confiance (`trustLoopback` à
        // faux, tests) : seuls les programmes du Mac y arrivent, et les tests y jouent ce rôle.
        let tailscaleOnly = !local && !Self.isLoopback(host)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, trusted: trusted, local: local, tailscaleOnly: tailscaleOnly) }
        }
        listeners[host] = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ host: String, _ state: NWListener.State) {
        switch state {
        case .ready:
            let actual = listeners[host]?.port?.rawValue ?? port
            log("En écoute sur \(host):\(actual).")
            onReady?(host, actual)
        case let .failed(error), let .waiting(error):
            listeners.removeValue(forKey: host)?.cancel()
            retryLater(host, after: error)
        default:
            break
        }
    }

    private func retryLater(_ host: String, after error: any Error) {
        log("Écoute sur \(host):\(port) impossible (\(error)). Nouvel essai dans 5 s.")
        scheduler.schedule(after: Self.retryDelay) { [weak self] in
            self?.listen(on: host)
        }
    }

    /// Écoute en boucle locale : seuls les programmes du Mac y arrivent.
    nonisolated static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1"
    }

    /// Adresse Tailscale : 100.64.0.0/10 en IPv4, fd7a:115c:a1e0::/48 en IPv6 (zone `%…` ignorée).
    /// Un texte qui n'est pas une adresse IP n'en est pas une.
    nonisolated static func isTailscaleAddress(_ host: String) -> Bool {
        let address = String(host.prefix { $0 != "%" })
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        }
        return false
    }

    /// Adresse distante d'une connexion : l'hôte, sans le port.
    nonisolated static func address(of endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return "\(host)"
        }
        return "\(endpoint)"
    }

    /// Décide d'admettre une nouvelle connexion, sans toucher au réseau. `authenticated` compte
    /// les clients authentifiés ou de confiance, `pendingAddresses` les connexions anonymes en
    /// attente (une adresse par connexion). Une connexion de confiance ne dépend que de la
    /// première réserve ; une anonyme que de la seconde.
    nonisolated static func admits(trusted: Bool, address: String, authenticated: Int, pendingAddresses: [String]) -> Bool {
        if trusted {
            return authenticated < maxClients
        }
        return pendingAddresses.count < maxPending
            && pendingAddresses.filter { $0 == address }.count < maxPendingPerAddress
    }

    /// Un identifiant d'appareil reçu d'un client anonyme n'entre dans le journal que s'il est
    /// hexadécimal (32 caractères au plus) : jamais de saut de ligne ni de texte forgé.
    nonisolated static func logID(_ deviceID: String) -> String {
        guard deviceID.count <= 32, deviceID.allSatisfy(\.isHexDigit) else { return "invalide" }
        return String(deviceID.prefix(8))
    }

    /// Clients authentifiés ou de confiance : ceux qui occupent les `maxClients` places.
    private var reservedCount: Int {
        clients.values.filter { $0.authenticated || $0.trusted }.count
    }

    private func accept(_ connection: NWConnection, trusted: Bool, local: Bool = false, tailscaleOnly: Bool = false) {
        let address = Self.address(of: connection.endpoint)
        guard !tailscaleOnly || Self.isTailscaleAddress(address) else {
            log("Connexion refusée : adresse hors Tailscale (\(address)).")
            connection.cancel()
            return
        }
        let pending = clients.values.filter { !$0.authenticated && !$0.trusted }.map(\.address)
        guard Self.admits(trusted: trusted, address: address, authenticated: reservedCount, pendingAddresses: pending) else {
            if trusted {
                log("Connexion refusée : déjà \(Self.maxClients) clients.")
            } else {
                log("Connexion refusée : trop de connexions anonymes (\(address)).")
            }
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        var client = Client(connection: connection, trusted: trusted, address: address, local: local)
        client.deadline = scheduler.schedule(after: Self.authTimeout) { [weak self] in
            self?.release(id, reason: "pas authentifié en \(Int(Self.authTimeout)) s (\(address))")
        }
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(id, state) }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    func connectionChanged(_ id: ClientID, _ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let client = clients[id] else { return }
            if wasRejected(id) {
                drop(id)
                return
            }
            armPongDeadline(id)
            schedulePing(id)
            if client.trusted {
                authenticate(id)
            } else {
                let nonce = DeviceAuthority.makeNonce()
                clients[id]?.nonce = nonce
                send(.challenge(nonce: nonce), to: id)
            }
        case let .waiting(error):
            // Chemin réseau perdu (Wi-Fi/4G, Tailscale coupé) : une connexion entrante
            // n'atteint alors pas toujours .failed et garderait sa place.
            release(id, reason: "connexion en attente (\(error))")
        case .failed, .cancelled:
            drop(id)
        default:
            break
        }
    }

    private func wasRejected(_ id: ClientID) -> Bool {
        let metadata = clients[id]?.connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        return metadata?.additionalServerHeaders?.contains { $0 == Self.rejectionMarker } ?? false
    }

    private func receive(on connection: NWConnection, id: ClientID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.clients[id] != nil else { return }
                if error != nil || context?.isFinal == true {
                    self.drop(id)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.drop(id)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.process(text, from: id)
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    private func process(_ text: String, from id: ClientID) {
        let message: ClientMessage
        do {
            message = try NacelleCodec.decodeClient(text)
        } catch {
            send(.error(code: .badMessage, message: "Message illisible."), to: id)
            return
        }
        guard let client = clients[id] else { return }
        switch message {
        case .openPairing:
            // Seul un programme du Mac (ptzd pair) ouvre un appairage (spec découverte et QR § 7.1).
            guard client.trusted else {
                log("Client \(id) : ouverture d'appairage refusée hors du Mac (\(client.address)).")
                send(.error(code: .notLocal, message: "Ouverture d'appairage depuis le Mac seulement."), to: id)
                return
            }
            openPairing(id)
        case let .pair(pairingID, publicKey, name, proof):
            guard !client.authenticated else {
                send(.error(code: .badMessage, message: "Déjà authentifié."), to: id)
                return
            }
            // Le QR code ne sert que sur le réseau local, dans le canal TLS ouvert avec son secret.
            guard client.local else {
                log("Client \(id) : appairage refusé hors du réseau local (\(client.address)).")
                send(.error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."), to: id)
                return
            }
            pair(id, pairingID: pairingID, publicKey: publicKey, name: name, proof: proof)
        case let .auth(deviceID, signature):
            guard !client.authenticated else { return }
            verify(id, deviceID: deviceID, signature: signature)
        case let .webrtcOffer(offerID, sdp):
            guard client.authenticated else {
                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
                return
            }
            relayOffer(id, offerID: offerID, sdp: sdp)
        default:
            guard client.authenticated else {
                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
                return
            }
            if let failure = controller.handle(message, from: id) {
                send(.error(code: failure.code, message: failure.message), to: id)
            }
        }
    }

    /// Ouvre un appairage, l'annonce aux écoutes du réseau local et renvoie de quoi faire le QR code.
    private func openPairing(_ id: ClientID) {
        let opened = authority.pairing.open()
        expiry?.cancel()
        expiry = scheduler.schedule(after: PairingWindow.lifetime) { [weak self] in
            self?.pairingExpired(opened.pairingID)
        }
        log("Appairage ouvert (\(opened.pairingID)), valable \(Int(PairingWindow.lifetime / 60)) min.")
        let invitation = PairingInvitation(
            pairingID: opened.pairingID, secret: opened.secret, expiresAt: opened.expiresAt,
            hosts: (localListeners?.addresses ?? []) + localHosts.sorted(), port: Int(port)
        )
        send(.pairingOpened(invitation), to: id)
        rebuildLocalListeners()
    }

    private func pairingExpired(_ pairingID: String) {
        expiry = nil
        guard authority.pairing.close(pairingID) else { return }
        log("Appairage \(pairingID) expiré.")
        rebuildLocalListeners()
    }

    /// Preuve du QR code sur le défi de la connexion : une preuve fausse laisse la connexion ouverte.
    private func pair(_ id: ClientID, pairingID: String, publicKey: Data, name: String, proof: Data) {
        guard let nonce = clients[id]?.nonce else { return }
        let wasOpen = authority.pairing.current?.pairingID == pairingID
        switch authority.pair(pairingID: pairingID, publicKey: publicKey, name: name, proof: proof, nonce: nonce) {
        case let .paired(deviceID, lanKey):
            expiry?.cancel()
            expiry = nil
            log("Appareil appairé : \(deviceID.prefix(8)) (\(Self.logName(name))).")
            send(.paired(deviceID: deviceID, lanKey: lanKey), to: id)
            rebuildLocalListeners()
        case .badCode:
            log("Appairage \(Self.logID(pairingID)) : preuve fausse (\(clients[id]?.address ?? "?")).")
            send(.error(code: .badCode, message: "QR code refusé."), to: id)
            if wasOpen, authority.pairing.current == nil {
                rebuildLocalListeners()
            }
        case .closed:
            send(.error(code: .pairingClosed, message: "QR code expiré ou déjà utilisé : relancer ptzd pair."), to: id)
        case .invalidKey:
            send(.error(code: .badMessage, message: "Clé publique illisible."), to: id)
        }
    }

    /// Un nom d'appareil n'entre dans le journal que sans caractère de contrôle, 40 caractères au plus.
    nonisolated static func logName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))
    }

    /// Réponse au défi. Le défi ne sert qu'une fois ; un échec ferme la connexion.
    private func verify(_ id: ClientID, deviceID: String, signature: Data) {
        guard let nonce = clients[id]?.nonce else { return }
        clients[id]?.nonce = nil
        switch authority.check(deviceID: deviceID, signature: signature, nonce: nonce) {
        case let .accepted(device):
            // Les 4 places sont aux clients authentifiés : un anonyme qui s'authentifie
            // alors qu'elles sont prises est refusé.
            guard reservedCount < Self.maxClients else {
                log("Connexion refusée : déjà \(Self.maxClients) clients.")
                drop(id)
                return
            }
            log("Client \(id) authentifié : \(device.name) (\(Self.logID(deviceID))).")
            authenticate(id)
        case .unknownDevice:
            refuse(id, .unpaired, "Appareil inconnu : l'appairer avec ptzd pair.", reason: "appareil inconnu \(Self.logID(deviceID))")
        case .badSignature:
            refuse(id, .authFailed, "Signature refusée.", reason: "signature refusée pour \(Self.logID(deviceID))")
        case .registryUnreadable:
            log("devices.json illisible : aucun appareil accepté.")
            refuse(id, .unpaired, "Liste des appareils illisible sur le Mac.", reason: "devices.json illisible")
        }
    }

    /// Relaie l'offre à go2rtc ; la réponse ou l'erreur porte l'identifiant de l'offre.
    private func relayOffer(_ id: ClientID, offerID: Int, sdp: String) {
        clients[id]?.negotiation?.cancel()
        let relay = relay
        clients[id]?.negotiation = Task { [weak self] in
            let reply: ServerMessage
            do {
                reply = .webrtcAnswer(id: offerID, sdp: try await relay.answer(offer: sdp))
            } catch {
                guard !Task.isCancelled else { return }
                self?.log("Relais vidéo du client \(id) en échec : \(error).")
                reply = .webrtcError(id: offerID, message: "go2rtc ne répond pas.")
            }
            guard !Task.isCancelled else { return }
            self?.send(reply, to: id)
        }
    }

    private func authenticate(_ id: ClientID) {
        clients[id]?.authenticated = true
        clients[id]?.deadline?.cancel()
        clients[id]?.deadline = nil
        send(.authenticated, to: id)
        send(.state(controller.snapshot), to: id)
    }

    /// Envoie l'erreur, puis libère la place une fois l'envoi parti.
    private func refuse(_ id: ClientID, _ code: ErrorCode, _ message: String, reason: String) {
        guard let connection = clients[id]?.connection, let text = try? NacelleCodec.encode(ServerMessage.error(code: code, message: message)) else { return }
        log("Client \(id) refusé : \(reason) (\(endpoint(id))).")
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.drop(id) }
        })
    }

    private func endpoint(_ id: ClientID) -> String {
        clients[id].map { "\($0.connection.endpoint)" } ?? "?"
    }

    private func schedulePing(_ id: ClientID) {
        clients[id]?.ping = scheduler.schedule(after: Self.pingInterval) { [weak self] in
            self?.ping(id)
        }
    }

    /// Envoie un ping. Le client y répond seul : URLSessionWebSocketTask le fait tant qu'une
    /// réception est en attente, ce qui est toujours le cas dans l'app iOS et nacelle-ws.
    private func ping(_ id: ClientID) {
        guard let connection = clients[id]?.connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { [weak self] error in
            guard error == nil else { return }
            MainActor.assumeIsolated { self?.armPongDeadline(id) }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: sendCompletion(id))
        schedulePing(id)
    }

    /// (Ré)arme l'échéance du pong : à la connexion, puis à chaque pong reçu.
    private func armPongDeadline(_ id: ClientID) {
        guard clients[id] != nil else { return }
        clients[id]?.pongDeadline?.cancel()
        clients[id]?.pongDeadline = scheduler.schedule(after: Self.pongTimeout) { [weak self] in
            self?.release(id, reason: "pas de pong depuis \(Int(Self.pongTimeout)) s")
        }
    }

    /// Libération anormale : une ligne de journal avec la raison, puis `drop`.
    private func release(_ id: ClientID, reason: String) {
        guard clients[id] != nil else { return }
        log("Client \(id) libéré : \(reason).")
        drop(id)
    }

    /// Seul chemin de libération d'une place.
    private func drop(_ id: ClientID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.cancelTimers()
        client.connection.cancel()
        controller.clientDisconnected(id)
    }

    /// Aux seuls clients authentifiés.
    private func broadcast(_ message: ServerMessage) {
        for (id, client) in clients where client.authenticated {
            send(message, to: id)
        }
    }

    private func send(_ message: ServerMessage, to id: ClientID) {
        guard let connection = clients[id]?.connection, let text = try? NacelleCodec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: sendCompletion(id))
    }

    /// Un envoi qui échoue libère la place (sans effet si elle l'est déjà).
    private func sendCompletion(_ id: ClientID) -> NWConnection.SendCompletion {
        .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.release(id, reason: "échec d'envoi (\(error))") }
        }
    }
}
