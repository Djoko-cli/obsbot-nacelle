import PTZCore

/// Encodage des commandes du Camera Terminal (norme UVC 1.5).
enum UVCPayload {
    static let getCurrent: UInt8 = 0x81
    static let setCurrent: UInt8 = 0x01
    static let selectorZoomAbsolute: UInt8 = 0x0B
    static let selectorPanTiltAbsolute: UInt8 = 0x0D
    static let selectorPanTiltRelative: UInt8 = 0x0E

    /// Course réellement acceptée par la Tiny 2 (mesurée le 2026-10-05) : pan ±130°,
    /// tilt de -80° à +70°. Elle annonce ±90° en UVC, mais ignore en silence un ordre
    /// à -90° ou +89°, pan compris : on borne donc avant d'envoyer.
    static let panRange: ClosedRange<Double> = -130...130
    static let tiltRange: ClosedRange<Double> = -80...70

    /// 8 octets : pan puis tilt, en secondes d'arc, int32 petit-boutiste, par pas de 1°.
    static func panTiltAbsolute(panDegrees: Double, tiltDegrees: Double) -> [UInt8] {
        littleEndian(arcSeconds(panDegrees, range: panRange)) + littleEndian(arcSeconds(tiltDegrees, range: tiltRange))
    }

    static func decodePanTiltAbsolute(_ bytes: [UInt8]) -> PanTiltPosition {
        PanTiltPosition(pan: Double(int32(bytes, at: 0)) / 3600, tilt: Double(int32(bytes, at: 4)) / 3600)
    }

    /// 4 octets : sens pan, vitesse pan, sens tilt, vitesse tilt.
    static func panTiltRelative(_ command: PanTiltRelative) -> [UInt8] {
        [
            UInt8(bitPattern: command.panDirection), command.panSpeed,
            UInt8(bitPattern: command.tiltDirection), command.tiltSpeed,
        ]
    }

    /// 2 octets petit-boutistes, borné à 0…100.
    static func zoomAbsolute(_ value: Int) -> [UInt8] {
        let clamped = UInt16(min(max(value, 0), 100))
        return [UInt8(clamped & 0xFF), UInt8(clamped >> 8)]
    }

    static func decodeZoom(_ bytes: [UInt8]) -> Int {
        Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    }

    private static func arcSeconds(_ degrees: Double, range: ClosedRange<Double>) -> Int32 {
        guard degrees.isFinite else { return 0 }
        return Int32(min(max(degrees, range.lowerBound), range.upperBound).rounded()) * 3600
    }

    private static func littleEndian(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        let raw = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Int32(bitPattern: raw)
    }
}
