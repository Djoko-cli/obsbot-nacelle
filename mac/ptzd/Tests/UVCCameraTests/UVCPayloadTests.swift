import PTZCore
import Testing
@testable import UVCCamera

@Suite("Encodage UVC")
struct UVCPayloadTests {
    @Test("PanTilt absolu : secondes d'arc, int32 petit-boutiste")
    func panTiltAbsolute() {
        // 30° = 108000 = 0x0001A5E0 ; -20° = -72000 = 0xFFFEE6C0
        #expect(UVCPayload.panTiltAbsolute(panDegrees: 30, tiltDegrees: -20)
            == [0xE0, 0xA5, 0x01, 0x00, 0xC0, 0xE6, 0xFE, 0xFF])
    }

    @Test("PanTilt absolu : borné à la course réellement acceptée, arrondi au degré")
    func panTiltAbsoluteClamped() {
        let low = UVCPayload.panTiltAbsolute(panDegrees: 500, tiltDegrees: -90)
        #expect(UVCPayload.decodePanTiltAbsolute(low) == PanTiltPosition(pan: 130, tilt: -80))
        let high = UVCPayload.panTiltAbsolute(panDegrees: -500, tiltDegrees: 89)
        #expect(UVCPayload.decodePanTiltAbsolute(high) == PanTiltPosition(pan: -130, tilt: 70))
        #expect(UVCPayload.decodePanTiltAbsolute(UVCPayload.panTiltAbsolute(panDegrees: 12.4, tiltDegrees: -69.6))
            == PanTiltPosition(pan: 12, tilt: -70))
        #expect(UVCPayload.decodePanTiltAbsolute(UVCPayload.panTiltAbsolute(panDegrees: .nan, tiltDegrees: 0))
            == PanTiltPosition(pan: 0, tilt: 0))
    }

    @Test("PanTilt absolu : décodage")
    func decodePanTilt() {
        #expect(UVCPayload.decodePanTiltAbsolute([0x20, 0x1C, 0x00, 0x00, 0xF0, 0xF1, 0xFF, 0xFF])
            == PanTiltPosition(pan: 2, tilt: -1))
    }

    @Test("PanTilt en vitesse : sens signés sur un octet")
    func panTiltRelative() {
        let command = PanTiltRelative(panDirection: -1, panSpeed: 40, tiltDirection: 1, tiltSpeed: 60)
        #expect(UVCPayload.panTiltRelative(command) == [0xFF, 40, 0x01, 60])
        #expect(UVCPayload.panTiltRelative(.stop) == [0, 1, 0, 1])
    }

    @Test("Zoom : 2 octets, borné à 0…100")
    func zoom() {
        #expect(UVCPayload.zoomAbsolute(33) == [33, 0])
        #expect(UVCPayload.zoomAbsolute(250) == [100, 0])
        #expect(UVCPayload.zoomAbsolute(-3) == [0, 0])
        #expect(UVCPayload.decodeZoom([0x64, 0x00]) == 100)
    }
}
