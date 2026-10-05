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
}
