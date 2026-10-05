import CoreGraphics
import Testing
@testable import Nacelle

@Suite("Joystick")
struct JoystickMathTests {
    @Test("À droite : pan positif ; vers le haut : tilt positif")
    func axes() {
        #expect(JoystickMath.vector(translation: CGSize(width: 75, height: 0), radius: 75) == JoystickVector(pan: 1, tilt: 0))
        #expect(JoystickMath.vector(translation: CGSize(width: 0, height: -75), radius: 75) == JoystickVector(pan: 0, tilt: 1))
    }

    @Test("Zone morte : moins de 0,1 du rayon donne l'arrêt")
    func deadZone() {
        #expect(JoystickMath.vector(translation: CGSize(width: 7, height: 0), radius: 75) == .zero)
        #expect(JoystickMath.vector(translation: CGSize(width: 8, height: 0), radius: 75).pan > 0.1)
    }

    @Test("Au-delà du cercle, la consigne reste de longueur 1")
    func clampedToCircle() {
        let vector = JoystickMath.vector(translation: CGSize(width: 300, height: -300), radius: 75)
        #expect(abs(vector.pan - 0.7071) < 0.001)
        #expect(abs(vector.tilt - 0.7071) < 0.001)
    }

    @Test("Le bouton affiché reste dans le cercle")
    func knob() {
        #expect(JoystickMath.knobOffset(translation: CGSize(width: 30, height: 40), radius: 75) == CGSize(width: 30, height: 40))
        #expect(JoystickMath.knobOffset(translation: CGSize(width: 150, height: 0), radius: 75) == CGSize(width: 75, height: 0))
    }

    @Test("Rayon nul : arrêt")
    func zeroRadius() {
        #expect(JoystickMath.vector(translation: CGSize(width: 10, height: 10), radius: 0) == .zero)
    }
}
