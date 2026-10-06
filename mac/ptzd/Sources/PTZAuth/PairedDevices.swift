import Foundation

/// Un appareil appairé : sa clé publique, et le secret du canal chiffré du réseau local
/// (spec accès local § 6.4 et § 14).
public struct PairedDevice: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    /// Clé publique P-256, format x963.
    public var publicKey: Data
    public var pairedAt: Date
    /// Secret TLS du réseau local ; absent pour un appareil appairé avant le canal chiffré.
    public var lanKey: Data?

    public init(deviceID: String, name: String, publicKey: Data, pairedAt: Date, lanKey: Data? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lanKey = lanKey
    }
}

public enum PairedDevicesError: Error, Equatable {
    /// Aucun appareil, ou plusieurs, ne correspond au début d'identifiant donné.
    case noMatch(String)
    case ambiguous(String)
}

/// `devices.json` : relu à chaque appel, pour qu'un `ptzd revoke` lancé à côté du service
/// prenne effet dès la connexion suivante. Écrit avec les droits 600.
public struct PairedDevices: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Fichier absent : aucun appareil. Fichier illisible : erreur.
    public func all() throws -> [PairedDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([PairedDevice].self, from: Data(contentsOf: url))
    }

    public func device(id: String) throws -> PairedDevice? {
        try all().first { $0.deviceID == id }
    }

    /// Ajoute l'appareil, ou remplace celui qui a le même identifiant.
    public func add(_ device: PairedDevice) throws {
        var devices = try all().filter { $0.deviceID != device.deviceID }
        devices.append(device)
        try write(devices)
    }

    /// Retire l'appareil dont l'identifiant commence par `prefix` (au moins 4 caractères).
    @discardableResult
    public func remove(prefix: String) throws -> PairedDevice {
        let devices = try all()
        let matches = prefix.count >= 4 ? devices.filter { $0.deviceID.hasPrefix(prefix.lowercased()) } : []
        guard let match = matches.first else { throw PairedDevicesError.noMatch(prefix) }
        guard matches.count == 1 else { throw PairedDevicesError.ambiguous(prefix) }
        try write(devices.filter { $0.deviceID != match.deviceID })
        return match
    }

    private func write(_ devices: [PairedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.write(try encoder.encode(devices), to: url)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Écriture atomique d'un fichier lisible par son seul propriétaire.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}