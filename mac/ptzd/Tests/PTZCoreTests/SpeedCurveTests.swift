import Testing
@testable import PTZCore

@Suite("Courbe de vitesse")
struct SpeedCurveTests {
    @Test("0 donne l'arrêt")
    func zeroStops() {
        #expect(SpeedCurve.axis(0, maxSpeed: 40, direction: 1) == (0, 1))
    }

    @Test("Plein débattement : vitesse maximale, dans le sens du signe")
    func fullDeflection() {
        #expect(SpeedCurve.axis(1, maxSpeed: 40, direction: 1) == (1, 40))
        #expect(SpeedCurve.axis(-1, maxSpeed: 40, direction: 1) == (-1, 40))
    }

    @Test("Courbe quadratique : 0,5 donne un quart du maximum")
    func quadratic() {
        #expect(SpeedCurve.axis(0.5, maxSpeed: 40, direction: 1) == (1, 10))
    }

    @Test("Une petite consigne donne au moins la vitesse 1")
    func minimumSpeed() {
        #expect(SpeedCurve.axis(0.05, maxSpeed: 40, direction: 1) == (1, 1))
    }

    @Test("direction -1 inverse le sens")
    func directionFlips() {
        #expect(SpeedCurve.axis(1, maxSpeed: 40, direction: -1) == (-1, 40))
    }

    @Test("Hors bornes ou non fini")
    func outOfRange() {
        #expect(SpeedCurve.axis(3, maxSpeed: 40, direction: 1) == (1, 40))
        #expect(SpeedCurve.axis(.nan, maxSpeed: 40, direction: 1) == (0, 1))
    }

    @Test("Commande combinée ; 0,0 vaut stop")
    func command() {
        let settings = MotionSettings(panMaxSpeed: 40, tiltMaxSpeed: 60, panDirection: 1, tiltDirection: -1)
        #expect(SpeedCurve.command(pan: 1, tilt: 1, settings: settings)
            == PanTiltRelative(panDirection: 1, panSpeed: 40, tiltDirection: -1, tiltSpeed: 60))
        #expect(SpeedCurve.command(pan: 0, tilt: 0, settings: settings) == .stop)
    }
}
