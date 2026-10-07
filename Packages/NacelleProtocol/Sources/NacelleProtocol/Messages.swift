import Foundation

/// Message de l'app vers ptzd (spec § 5).
public enum ClientMessage: Equatable, Sendable {
    /// Prise en main ; ne coupe plus le suivi IA, gardé pour la compatibilité (spec app Mac § 7.5).
    case takeControl
    /// Consigne de vitesse, de -1 à 1 sur chaque axe. 0,0 arrête le mouvement.
    case move(pan: Double, tilt: Double)
    /// Zoom absolu, de 0 à 100.
    case zoom(value: Int)
    /// Entre en vie privée (true) ou en sort (false).
    case privacy(on: Bool)
    /// Enregistre la clé de l'appareil pour l'appairage `pairingID` du QR code ; `proof` prouve que
    /// l'app connaît le secret du QR (spec découverte et QR § 6).
    case pair(pairingID: String, publicKey: Data, name: String, proof: Data)
    /// Ouvre un appairage ; accepté seulement depuis 127.0.0.1 (`ptzd pair`).
    case openPairing
    /// Répond au défi : signature DER de `NacelleAuth.signedPayload` (spec accès local § 6.3).
    case auth(deviceID: String, signature: Data)
    /// Offre WebRTC à relayer à go2rtc ; `id` croît à chaque offre (spec accès local § 6.5).
    case webrtcOffer(id: Int, sdp: String)
    /// Allume (true) ou coupe (false) le suivi IA de la caméra (spec app Mac § 7.5).
    case aiTracking(on: Bool)
    /// Demande l'état d'administration, puis ses changements ; 127.0.0.1 seulement (spec app Mac § 6).
    case adminWatch
    /// Retire l'appareil et coupe ses connexions ; 127.0.0.1 seulement.
    case revoke(deviceID: String)
    /// Coupe les connexions de l'appareil et le bloque 10 min ; 127.0.0.1 seulement.
    case kick(deviceID: String)
    /// Lève le blocage de l'appareil ; 127.0.0.1 seulement.
    case unblock(deviceID: String)
    /// Annule l'appairage en cours ; 127.0.0.1 seulement.
    case closePairing
    /// L'iPhone oublie son appairage : ptzd retire cet appareil de sa liste et coupe ses connexions.
    /// Accepté d'un iPhone authentifié seulement.
    case forgetMe
}

/// Présence de la caméra côté Mac.
public enum CameraPresence: String, Codable, Sendable {
    case connected
    case absent
}

/// Dernier ordre de suivi IA envoyé par ptzd : l'état réel ne se lit pas (spec app Mac § 7.5).
public enum AITracking: String, Codable, Sendable {
    case on
    case off
    /// Au démarrage de ptzd et après un rebranchement de la caméra hors vie privée.
    case unknown
}

/// Avancement de la coupure du suivi IA (prise en main).
public enum ControlState: String, Codable, Sendable {
    case idle
    case taking
    case ready
    case failed
}

/// Codes d'erreur renvoyés à l'app.
public enum ErrorCode: String, Codable, Sendable {
    case privacyActive
    case cameraAbsent
    case uvcFailed
    case badMessage
    /// Appareil inconnu de ptzd.
    case unpaired
    /// Signature fausse.
    case authFailed
    /// Preuve d'appairage fausse.
    case badCode
    /// Aucun appairage en cours, expiré, déjà utilisé, ou autre identifiant.
    case pairingClosed
    /// Message refusé avant l'authentification.
    case notAuthenticated
    /// Message d'administration ou `openPairing` hors de 127.0.0.1, ou `pair` hors de l'écoute du réseau local.
    case notLocal
    /// Appareil expulsé par le Mac, pour quelques minutes (spec app Mac § 7.3).
    case blocked
}

/// État complet publié par ptzd.
public struct StateSnapshot: Equatable, Sendable {
    public var camera: CameraPresence
    public var control: ControlState
    public var privacy: Bool
    /// Degrés, ou nil si inconnus.
    public var pan: Double?
    /// Degrés, ou nil si inconnus.
    public var tilt: Double?
    /// De 0 à 100, ou nil si inconnu.
    public var zoom: Int?
    public var moving: Bool
    public var aiTracking: AITracking

    public init(
        camera: CameraPresence,
        control: ControlState,
        privacy: Bool,
        pan: Double?,
        tilt: Double?,
        zoom: Int?,
        moving: Bool,
        aiTracking: AITracking = .unknown
    ) {
        self.camera = camera
        self.control = control
        self.privacy = privacy
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
        self.moving = moving
        self.aiTracking = aiTracking
    }
}

/// Message de ptzd vers l'app.
public enum ServerMessage: Equatable, Sendable {
    case state(StateSnapshot)
    case error(code: ErrorCode, message: String)
    /// Défi envoyé à l'ouverture d'une connexion qui doit s'authentifier.
    case challenge(nonce: Data)
    /// Connexion authentifiée ; l'état suit aussitôt.
    case authenticated
    /// Appairage ouvert : ce que `ptzd pair` met dans le QR code.
    case pairingOpened(PairingInvitation)
    /// L'appareil vient d'être enregistré ; `lanKey` est son secret du canal chiffré du réseau local
    /// (spec accès local § 14), remis sur le réseau local à la connexion qui a fourni la preuve.
    case paired(deviceID: String, lanKey: Data)
    /// Réponse de go2rtc à l'offre `id`.
    case webrtcAnswer(id: Int, sdp: String)
    /// go2rtc injoignable ou en erreur pour l'offre `id`.
    case webrtcError(id: Int, message: String)
    /// État d'administration, aux connexions qui l'ont demandé par `adminWatch`.
    case adminState(AdminState)
}

/// Un appairage ouvert par ptzd : identifiant, secret, échéance, et où joindre le Mac.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public var pairingID: String
    /// 32 octets aléatoires ; clé TLS de l'appairage et clé de la preuve.
    public var secret: Data
    public var expiresAt: Date
    /// Adresses IPv4 du Mac sur le réseau local.
    public var hosts: [String]
    public var port: Int

    public init(pairingID: String, secret: Data, expiresAt: Date, hosts: [String], port: Int) {
        self.pairingID = pairingID
        self.secret = secret
        self.expiresAt = expiresAt
        self.hosts = hosts
        self.port = port
    }

    private enum CodingKeys: String, CodingKey {
        case pairingID, secret, expiresAt, hosts, port
    }

    /// `expiresAt` s'écrit en secondes depuis 1970 (spec découverte et QR § 6).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pairingID: try c.decode(String.self, forKey: .pairingID),
            secret: try c.decode(Data.self, forKey: .secret),
            expiresAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expiresAt)),
            hosts: try c.decode([String].self, forKey: .hosts),
            port: try c.decode(Int.self, forKey: .port)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(secret, forKey: .secret)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(port, forKey: .port)
    }
}
