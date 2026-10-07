import Foundation

/// Ce que l'app Mac montre de ptzd (spec app Mac § 6) : appareils appairés, clients connectés et
/// appairage en cours, sans jamais le secret. Dates en secondes depuis 1970 ; les absences s'écrivent `null`.
public struct AdminState: Codable, Equatable, Sendable {
    public var devices: [AdminDevice]
    public var clients: [AdminClient]
    public var pairing: AdminPairing?

    public init(devices: [AdminDevice], clients: [AdminClient], pairing: AdminPairing?) {
        self.devices = devices
        self.clients = clients
        self.pairing = pairing
    }

    private enum CodingKeys: String, CodingKey {
        case devices, clients, pairing
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(devices, forKey: .devices)
        try c.encode(clients, forKey: .clients)
        try c.encode(pairing, forKey: .pairing)
    }
}

/// Un appareil appairé.
public struct AdminDevice: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public var pairedAt: Date
    /// Fin de l'expulsion en cours, ou nil.
    public var blockedUntil: Date?

    public init(deviceID: String, name: String, pairedAt: Date, blockedUntil: Date?) {
        self.deviceID = deviceID
        self.name = name
        self.pairedAt = pairedAt
        self.blockedUntil = blockedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, name, pairedAt, blockedUntil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deviceID: try c.decode(String.self, forKey: .deviceID),
            name: try c.decode(String.self, forKey: .name),
            pairedAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .pairedAt)),
            blockedUntil: try c.decodeIfPresent(Double.self, forKey: .blockedUntil).map(Date.init(timeIntervalSince1970:))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(name, forKey: .name)
        try c.encode(pairedAt.timeIntervalSince1970, forKey: .pairedAt)
        try c.encode(blockedUntil?.timeIntervalSince1970, forKey: .blockedUntil)
    }
}

/// Par où un client est arrivé.
public enum ClientRoute: String, Codable, Sendable {
    /// Écoute TLS du réseau local.
    case localNetwork
    /// Écoute Tailscale.
    case tailscale
    /// Boucle locale (127.0.0.1, ::1) : un programme du Mac.
    case mac
}

/// Un client connecté, authentifié ou de confiance.
public struct AdminClient: Codable, Equatable, Sendable {
    public var id: Int
    /// L'appareil authentifié ; nil pour un client du Mac.
    public var deviceID: String?
    public var name: String?
    public var route: ClientRoute
    public var address: String
    /// Heure de l'authentification.
    public var since: Date

    public init(id: Int, deviceID: String?, name: String?, route: ClientRoute, address: String, since: Date) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.route = route
        self.address = address
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case id, deviceID, name, route, address, since
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int.self, forKey: .id),
            deviceID: try c.decodeIfPresent(String.self, forKey: .deviceID),
            name: try c.decodeIfPresent(String.self, forKey: .name),
            route: try c.decode(ClientRoute.self, forKey: .route),
            address: try c.decode(String.self, forKey: .address),
            since: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .since))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(name, forKey: .name)
        try c.encode(route, forKey: .route)
        try c.encode(address, forKey: .address)
        try c.encode(since.timeIntervalSince1970, forKey: .since)
    }
}

/// L'appairage en cours, sans son secret.
public struct AdminPairing: Codable, Equatable, Sendable {
    public var pairingID: String
    public var expiresAt: Date

    public init(pairingID: String, expiresAt: Date) {
        self.pairingID = pairingID
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case pairingID, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pairingID: try c.decode(String.self, forKey: .pairingID),
            expiresAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expiresAt))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
    }
}
