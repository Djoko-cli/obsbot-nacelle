import Foundation
import NacelleProtocol
import Synchronization

/// Résultat d'un essai d'appairage.
public enum PairingAttempt: Equatable, Sendable {
    case accepted
    /// Preuve fausse ; l'appairage reste ouvert s'il reste des essais.
    case wrong
    /// Aucun appairage en cours, expiré, déjà utilisé, ou autre identifiant.
    case closed
}

/// L'appairage en cours, en mémoire (spec découverte et QR § 7.1) : identifiant, secret du QR code,
/// échéance et essais faux. Lu aussi par la file TLS des écoutes du réseau local, d'où le verrou.
public final class PairingWindow: Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailures = 3

    struct Open {
        var pairingID: String
        var secret: Data
        var expiresAt: Date
        var failures: Int
    }

    private let state = Mutex<Open?>(nil)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Ouvre un appairage neuf (remplace celui en cours) : identifiant de 8 caractères hexadécimaux,
    /// secret de 32 octets, valable 5 min.
    public func open() -> (pairingID: String, secret: Data, expiresAt: Date) {
        var generator = SystemRandomNumberGenerator()
        let pairingID = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        let secret = NacelleTLS.makeKey()
        let expiresAt = now() + Self.lifetime
        state.withLock { $0 = Open(pairingID: pairingID, secret: secret, expiresAt: expiresAt, failures: 0) }
        return (pairingID, secret, expiresAt)
    }

    /// L'appairage en cours et non expiré, ou nil.
    public var current: (pairingID: String, secret: Data)? {
        state.withLock { open in
            guard let open, now() < open.expiresAt else { return nil }
            return (open.pairingID, open.secret)
        }
    }

    /// Vérifie la preuve. Juste : l'appairage est consommé. Fausse : un essai de moins ; au 3e, fermé.
    public func attempt(pairingID: String, proof: Data, nonce: Data, publicKeyX963: Data) -> PairingAttempt {
        state.withLock { open in
            guard let current = open, current.pairingID == pairingID, now() < current.expiresAt else {
                return .closed
            }
            if NacelleAuth.verifyPairingProof(proof, secret: current.secret, nonce: nonce, publicKeyX963: publicKeyX963) {
                open = nil
                return .accepted
            }
            open?.failures += 1
            if (open?.failures ?? 0) >= Self.maxFailures {
                open = nil
            }
            return .wrong
        }
    }

    /// Ferme l'appairage en cours, s'il y en a un et s'il porte cet identifiant (nil : n'importe lequel).
    /// Retourne vrai s'il a fermé un appairage stocké, sans tenir compte de l'échéance.
    @discardableResult
    public func close(_ pairingID: String? = nil) -> Bool {
        state.withLock { open in
            guard let current = open, pairingID == nil || current.pairingID == pairingID else {
                return false
            }
            open = nil
            return true
        }
    }
}
