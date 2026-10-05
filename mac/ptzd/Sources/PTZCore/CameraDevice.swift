/// Identifiant d'une connexion cliente, attribué par le serveur.
public typealias ClientID = Int

/// Destination des lignes de journal.
public typealias LogSink = @MainActor (String) -> Void

/// Commande PanTilt en vitesse (UVC CT_PANTILT_RELATIVE_CONTROL, sélecteur 0x0E).
public struct PanTiltRelative: Equatable, Sendable {
    /// -1, 0 (arrêt) ou 1.
    public var panDirection: Int8
    public var panSpeed: UInt8
    /// -1, 0 (arrêt) ou 1.
    public var tiltDirection: Int8
    public var tiltSpeed: UInt8

    public init(panDirection: Int8, panSpeed: UInt8, tiltDirection: Int8, tiltSpeed: UInt8) {
        self.panDirection = panDirection
        self.panSpeed = panSpeed
        self.tiltDirection = tiltDirection
        self.tiltSpeed = tiltSpeed
    }

    /// Arrêt : sens 0 sur les deux axes, avec la vitesse minimale valide (1).
    public static let stop = PanTiltRelative(panDirection: 0, panSpeed: 1, tiltDirection: 0, tiltSpeed: 1)
}

/// Position absolue de la nacelle, en degrés.
public struct PanTiltPosition: Equatable, Sendable {
    public var pan: Double
    public var tilt: Double

    public init(pan: Double, tilt: Double) {
        self.pan = pan
        self.tilt = tilt
    }
}

public enum CameraError: Error, Equatable {
    /// La caméra n'est pas branchée.
    case absent
    /// Requête USB refusée, avec le code IOKit.
    case ioKit(Int32)
}

/// Ce que PTZCore attend de la caméra. Les appels sont synchrones et courts
/// (une requête de contrôle USB prend quelques millisecondes).
@MainActor
public protocol CameraDevice: AnyObject {
    var isPresent: Bool { get }
    func setPanTiltRelative(_ command: PanTiltRelative) throws
    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws
    func setZoom(_ value: Int) throws
    func readPanTilt() throws -> PanTiltPosition
    func readZoom() throws -> Int
}
