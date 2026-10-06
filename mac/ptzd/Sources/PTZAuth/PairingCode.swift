import CryptoKit
import Foundation

/// Résultat d'un essai de code d'appairage.
public enum PairingAttempt: Equatable, Sendable {
    case accepted
    /// Code faux ; le code en cours reste valable s'il reste des essais.
    case wrong
    /// Aucun code en cours, code expiré, ou code annulé après trop d'essais faux.
    case closed
}

/// `pairing.json` : le code en cours, haché avec un sel, son expiration et les essais faux
/// (spec accès local § 6.4). `ptzd pair` l'ouvre ; le service le lit et le supprime.
public struct PairingCode: Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailures = 3

    struct Stored: Codable {
        var salt: Data
        var hash: Data
        var expiresAt: Date
        var failures: Int
    }

    public let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// Ouvre un appairage : nouveau code à 6 chiffres, valable 5 min. Remplace un code en cours.
    public func open() throws -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let stored = Stored(salt: salt, hash: Self.hash(code, salt: salt), expiresAt: now() + Self.lifetime, failures: 0)
        try PrivateFile.write(try Self.encoder.encode(stored), to: url)
        return code
    }

    /// Essaie un code. Le bon code ferme l'appairage (usage unique) ; au 3e essai faux aussi.
    public func attempt(_ code: String) -> PairingAttempt {
        guard let data = try? Data(contentsOf: url), var stored = try? Self.decoder.decode(Stored.self, from: data) else {
            return .closed
        }
        guard now() < stored.expiresAt else {
            close()
            return .closed
        }
        if Self.hash(code, salt: stored.salt) == stored.hash {
            close()
            return .accepted
        }
        stored.failures += 1
        if stored.failures >= Self.maxFailures {
            close()
        } else {
            try? PrivateFile.write(try Self.encoder.encode(stored), to: url)
        }
        return .wrong
    }

    /// Supprime le code en cours, s'il y en a un.
    public func close() {
        try? FileManager.default.removeItem(at: url)
    }

    static func hash(_ code: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(code.utf8)))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}