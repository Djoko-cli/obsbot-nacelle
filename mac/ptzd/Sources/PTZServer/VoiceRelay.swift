import Darwin
import Foundation
import NacelleProtocol
import PTZCore

/// Là où partent les trames voix acceptées : en service, une socket UDP vers talkd.
@MainActor
public protocol VoiceSink: AnyObject {
    /// Ne signale jamais d'erreur : un talkd absent ne doit rien changer pour l'iPhone.
    func send(_ frame: Data)
}

/// Destination par défaut : les trames sont jetées (aucun talkd à joindre).
@MainActor
final class DiscardingVoiceSink: VoiceSink {
    func send(_ frame: Data) {}
}

/// Envoie chaque trame à `127.0.0.1:<port>` de talkd (spec parler § 5). Une seule socket, ouverte au premier envoi
/// et gardée pour la vie du process. Non bloquante : l'envoi ne fait jamais attendre la file principale. Un envoi
/// qui échoue (talkd absent, tampon plein) est ignoré, et seulement compté.
@MainActor
public final class UDPVoiceSink: VoiceSink {
    private let port: UInt16
    private var descriptor: Int32 = -1
    /// Envois échoués depuis le démarrage (diagnostic et tests).
    public private(set) var sendFailures = 0

    public init(port: UInt16) {
        self.port = port
    }

    deinit {
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    public func send(_ frame: Data) {
        guard openIfNeeded() else {
            sendFailures += 1
            return
        }
        let sent = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        if sent < 0 {
            sendFailures += 1
        }
    }

    /// Ouvre la socket UDP « connectée » à talkd, ou garde le descripteur déjà ouvert. Un échec est réessayé au
    /// prochain envoi.
    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        let candidate = socket(AF_INET, SOCK_DGRAM, 0)
        guard candidate >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected, fcntl(candidate, F_SETFL, O_NONBLOCK) == 0 else {
            close(candidate)
            return false
        }
        var on: Int32 = 1
        setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        descriptor = candidate
        return true
    }
}

/// Fenêtre glissante d'une seconde : au plus `limit` trames (spec parler § 5 : 50). Les trames refusées n'entrent
/// pas dans la fenêtre.
struct VoiceLimiter {
    static let window: TimeInterval = 1

    let limit: Int
    private var accepted: [TimeInterval] = []

    init(limit: Int = VoiceFrame.maxFramesPerSecond) {
        self.limit = limit
    }

    mutating func allow(at time: TimeInterval) -> Bool {
        // 1e-9 : l'arrondi des secondes en virgule flottante ne doit pas décider d'une trame.
        accepted.removeAll { time - $0 >= Self.window - 1e-9 }
        guard accepted.count < limit else { return false }
        accepted.append(time)
        return true
    }
}

/// Reçoit les trames binaires des clients, ne relaie que celles d'un iPhone authentifié (valides et dans la limite),
/// compte le reste et tient le journal. Aucun son n'est enregistré ni écrit nulle part (spec parler § 5).
@MainActor
final class VoiceRelayer {
    /// Qui envoie la trame, vu par le serveur.
    enum Sender: Equatable {
        /// Un iPhone qui s'est authentifié par sa clé d'appareil.
        case device(id: String, name: String)
        /// Pas encore authentifié, ou en cours d'appairage.
        case unauthenticated
        /// Le client de confiance 127.0.0.1 (app Mac, outils) : il ne parle pas.
        case trusted
    }

    struct Refusals: Equatable {
        var unauthorized = 0
        var badSize = 0
        var tooFast = 0

        var total: Int {
            unauthorized + badSize + tooFast
        }
    }

    /// Une prise de parole se termine après ce délai sans trame (le détecteur de voix de talkd garde le sien).
    static let turnGap: TimeInterval = 1
    /// Marge au-dessus des 50 trames par seconde de la spec. Un iPhone qui envoie pile 50 trames par seconde en
    /// dépasse la fenêtre de temps à autre : les trames arrivent par grappes (gigue du Wi-Fi ou de la 4G, TCP qui
    /// rattrape un retard). 10 trames = 200 ms de voix ; le débit soutenu reste plafonné à 60 par seconde.
    static let burstTolerance = 10
    /// Une ligne de refus au plus par minute.
    static let refusalLogInterval: TimeInterval = 60

    /// Refus depuis le démarrage.
    private(set) var refused = Refusals()

    private struct Turn {
        let deviceID: String
        let name: String
        let startedAt: Date
        let start: TimeInterval
        var last: TimeInterval
        var relayed = 0
        var refused = 0
        var timer: (any Cancellable)?
    }

    private let sink: any VoiceSink
    private let scheduler: any Scheduler
    private let now: @Sendable () -> Date
    private let log: LogSink
    private var turns: [ClientID: Turn] = [:]
    private var limiters: [ClientID: VoiceLimiter] = [:]
    /// Refus pas encore écrits dans le journal, et minuterie qui limite les lignes.
    private var pending = Refusals()
    private var refusalTimer: (any Cancellable)?

    init(sink: any VoiceSink, scheduler: any Scheduler, now: @escaping @Sendable () -> Date, log: @escaping LogSink) {
        self.sink = sink
        self.scheduler = scheduler
        self.now = now
        self.log = log
    }

    func receive(_ frame: Data, from client: ClientID, as sender: Sender) {
        guard case let .device(deviceID, name) = sender else {
            refuse(\.unauthorized)
            return
        }
        let time = scheduler.now
        touchTurn(client, deviceID: deviceID, name: name, at: time)
        guard VoiceFrame.isValid(frame) else {
            turns[client]?.refused += 1
            refuse(\.badSize)
            return
        }
        guard limiters[client, default: VoiceLimiter(limit: VoiceFrame.maxFramesPerSecond + Self.burstTolerance)].allow(at: time) else {
            turns[client]?.refused += 1
            refuse(\.tooFast)
            return
        }
        sink.send(frame)
        turns[client]?.relayed += 1
    }

    /// Le client est parti : sa prise de parole en cours est écrite tout de suite.
    func clientGone(_ client: ClientID) {
        limiters.removeValue(forKey: client)
        endTurn(client)
    }

    // MARK: - Prises de parole

    private func touchTurn(_ client: ClientID, deviceID: String, name: String, at time: TimeInterval) {
        if let turn = turns[client], time - turn.last >= Self.turnGap {
            // L'échéance n'a pas encore sonné (minuterie en retard) : la parole précédente se ferme ici.
            endTurn(client)
        }
        if turns[client] == nil {
            var turn = Turn(deviceID: deviceID, name: name, startedAt: now(), start: time, last: time)
            turn.timer = scheduler.schedule(after: Self.turnGap) { [weak self] in
                self?.turnTimerFired(client)
            }
            turns[client] = turn
        } else {
            turns[client]?.last = time
        }
    }

    private func turnTimerFired(_ client: ClientID) {
        guard let turn = turns[client] else { return }
        let remaining = turn.last + Self.turnGap - scheduler.now
        if remaining > 1e-9 {
            turns[client]?.timer = scheduler.schedule(after: remaining) { [weak self] in
                self?.turnTimerFired(client)
            }
        } else {
            endTurn(client)
        }
    }

    private func endTurn(_ client: ClientID) {
        guard let turn = turns.removeValue(forKey: client) else { return }
        turn.timer?.cancel()
        let duration = turn.last - turn.start + Double(VoiceFrame.durationMilliseconds) / 1000
        log("Parole de l'appareil \(Self.logID(turn.deviceID)) (\(turn.name)) : début \(Self.clock(turn.startedAt)), "
            + "durée \(Self.seconds(duration)) s, \(Self.count(turn.relayed, "trame relayée", "trames relayées")), "
            + "\(Self.count(turn.refused, "refusée", "refusées")).")
    }

    // MARK: - Refus

    private func refuse(_ counter: WritableKeyPath<Refusals, Int>) {
        refused[keyPath: counter] += 1
        pending[keyPath: counter] += 1
        if refusalTimer == nil {
            flushRefusals()
        }
    }

    /// Écrit les refus en attente, puis interdit toute autre ligne pendant `refusalLogInterval` ; à l'échéance,
    /// ce qui s'est accumulé entre-temps est écrit à son tour.
    private func flushRefusals() {
        if pending.total > 0 {
            log("Trames vocales refusées : \(pending.unauthorized) sans authentification, "
                + "\(pending.badSize) de taille fausse, \(pending.tooFast) au-delà de \(VoiceFrame.maxFramesPerSecond + Self.burstTolerance) par seconde.")
            pending = Refusals()
            refusalTimer = scheduler.schedule(after: Self.refusalLogInterval) { [weak self] in
                self?.flushRefusals()
            }
        } else {
            refusalTimer = nil
        }
    }

    // MARK: - Texte

    private static func logID(_ deviceID: String) -> String {
        String(deviceID.prefix(8))
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Une décimale, virgule française.
    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value > 1 ? many : one)"
    }
}
