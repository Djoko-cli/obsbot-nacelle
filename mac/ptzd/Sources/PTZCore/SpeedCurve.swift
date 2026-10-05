/// Réglages du mouvement, issus de config.json (spec § 6.7).
public struct MotionSettings: Equatable, Sendable {
    public var panMaxSpeed: Int
    public var tiltMaxSpeed: Int
    /// +1 ou -1 : sens UVC correspondant à une consigne positive.
    public var panDirection: Int
    public var tiltDirection: Int

    public init(panMaxSpeed: Int = 40, tiltMaxSpeed: Int = 60, panDirection: Int = 1, tiltDirection: Int = 1) {
        self.panMaxSpeed = panMaxSpeed
        self.tiltMaxSpeed = tiltMaxSpeed
        self.panDirection = panDirection
        self.tiltDirection = tiltDirection
    }
}

/// Conversion d'une consigne de joystick en commande UVC (spec § 6.2).
public enum SpeedCurve {
    /// vitesse = round(|x|² × max), au moins 1 dès que x ≠ 0 ; sens = signe(x) × direction.
    public static func axis(_ value: Double, maxSpeed: Int, direction: Int) -> (direction: Int8, speed: UInt8) {
        guard value.isFinite else { return (0, 1) }
        let clamped = min(max(value, -1), 1)
        guard clamped != 0 else { return (0, 1) }
        let raw = Int((clamped * clamped * Double(maxSpeed)).rounded())
        let speed = min(max(raw, 1), Int(UInt8.max))
        let sign: Int8 = clamped > 0 ? 1 : -1
        let flip: Int8 = direction < 0 ? -1 : 1
        return (sign * flip, UInt8(speed))
    }

    public static func command(pan: Double, tilt: Double, settings: MotionSettings) -> PanTiltRelative {
        let p = axis(pan, maxSpeed: settings.panMaxSpeed, direction: settings.panDirection)
        let t = axis(tilt, maxSpeed: settings.tiltMaxSpeed, direction: settings.tiltDirection)
        return PanTiltRelative(panDirection: p.direction, panSpeed: p.speed, tiltDirection: t.direction, tiltSpeed: t.speed)
    }
}
