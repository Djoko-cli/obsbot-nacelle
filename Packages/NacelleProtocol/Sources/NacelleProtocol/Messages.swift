import Foundation

/// Message de l'app vers ptzd (spec § 5).
public enum ClientMessage: Equatable, Sendable {
    /// Coupe le suivi IA de la caméra (spec § 6.4).
    case takeControl
    /// Consigne de vitesse, de -1 à 1 sur chaque axe. 0,0 arrête le mouvement.
    case move(pan: Double, tilt: Double)
    /// Zoom absolu, de 0 à 100.
    case zoom(value: Int)
    /// Entre en vie privée (true) ou en sort (false).
    case privacy(on: Bool)
    /// Enregistre la clé de l'appareil avec le code affiché par `ptzd pair` (spec accès local § 6.4).
    case pair(code: String, publicKey: Data, name: String)
    /// Répond au défi : signature DER de `NacelleAuth.signedPayload` (spec accès local § 6.3).
    case auth(deviceID: String, signature: Data)
    /// Offre WebRTC à relayer à go2rtc ; `id` croît à chaque offre (spec accès local § 6.5).
    case webrtcOffer(id: Int, sdp: String)
}

/// Présence de la caméra côté Mac.
public enum CameraPresence: String, Codable, Sendable {
    case connected
    case absent
}

/// Avancement de la prise en main, c'est-à-dire de la coupure du suivi IA.
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
    /// Code d'appairage faux.
    case badCode
    /// Aucun code d'appairage en cours, ou code expiré.
    case pairingClosed
    /// Message refusé avant l'authentification.
    case notAuthenticated
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

    public init(
        camera: CameraPresence,
        control: ControlState,
        privacy: Bool,
        pan: Double?,
        tilt: Double?,
        zoom: Int?,
        moving: Bool
    ) {
        self.camera = camera
        self.control = control
        self.privacy = privacy
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
        self.moving = moving
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
    /// L'appareil vient d'être enregistré.
    case paired(deviceID: String)
    /// Réponse de go2rtc à l'offre `id`.
    case webrtcAnswer(id: Int, sdp: String)
    /// go2rtc injoignable ou en erreur pour l'offre `id`.
    case webrtcError(id: Int, message: String)
}
