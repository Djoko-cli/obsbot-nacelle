import CoreGraphics

/// Consigne du joystick, de -1 à 1 sur chaque axe. Vers la droite = pan positif, vers le haut = tilt positif.
struct JoystickVector: Equatable, Sendable {
    var pan: Double
    var tilt: Double

    static let zero = JoystickVector(pan: 0, tilt: 0)
}

/// Géométrie du joystick (spec § 7.2) : bornée au cercle, avec une zone morte de 0,1.
enum JoystickMath {
    static let deadZone = 0.1

    /// Déplacement du doigt depuis le centre → consigne. L'axe vertical d'écran est inversé.
    static func vector(translation: CGSize, radius: CGFloat) -> JoystickVector {
        guard radius > 0 else { return .zero }
        var pan = Double(translation.width / radius)
        var tilt = Double(-translation.height / radius)
        let length = (pan * pan + tilt * tilt).squareRoot()
        guard length >= deadZone else { return .zero }
        if length > 1 {
            pan /= length
            tilt /= length
        }
        return JoystickVector(pan: pan, tilt: tilt)
    }

    /// Position affichée du bouton : le déplacement du doigt, borné au cercle.
    static func knobOffset(translation: CGSize, radius: CGFloat) -> CGSize {
        let length = (translation.width * translation.width + translation.height * translation.height).squareRoot()
        guard length > radius, length > 0 else { return translation }
        return CGSize(width: translation.width * radius / length, height: translation.height * radius / length)
    }
}
