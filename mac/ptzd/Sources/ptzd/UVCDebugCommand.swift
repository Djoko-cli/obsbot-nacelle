import Foundation
import PTZCore
import UVCCamera

/// `ptzd uvc …` : commandes manuelles, pour l'étalonnage et les vérifications sur la vraie caméra.
@MainActor
enum UVCDebugCommand {
    static let usage = """
    usage : ptzd uvc get
            ptzd uvc pt <pan°> <tilt°>
            ptzd uvc rel <sens pan> <vitesse pan> <sens tilt> <vitesse tilt>   (rel 0 1 0 1 = arrêt)
            ptzd uvc zoom <0-100>
    """
    static let arity = ["get": 0, "pt": 2, "rel": 4, "zoom": 1]

    static func run(_ arguments: [String], log: @escaping LogSink) -> Int32 {
        let values = arguments.dropFirst().compactMap(Double.init)
        guard let command = arguments.first,
              let expected = arity[command],
              values.count == expected,
              arguments.count == expected + 1 else {
            log(usage)
            return 2
        }
        let camera = UVCCamera(log: log)
        camera.startWatching()
        guard camera.isPresent else {
            log("Tiny 2 introuvable ou inaccessible.")
            return 1
        }
        do {
            switch command {
            case "get":
                let position = try camera.readPanTilt()
                log("pan=\(position.pan)° tilt=\(position.tilt)° zoom=\(try camera.readZoom())")
            case "pt":
                try camera.setPanTiltAbsolute(panDegrees: values[0], tiltDegrees: values[1])
                log("PanTilt absolu envoyé : pan=\(values[0])° tilt=\(values[1])°")
            case "rel":
                let relative = PanTiltRelative(
                    panDirection: Int8(clamping: Int(values[0])),
                    panSpeed: UInt8(clamping: Int(values[1])),
                    tiltDirection: Int8(clamping: Int(values[2])),
                    tiltSpeed: UInt8(clamping: Int(values[3]))
                )
                try camera.setPanTiltRelative(relative)
                log("PanTilt en vitesse envoyé : \(relative)")
            default:
                try camera.setZoom(Int(values[0]))
                log("Zoom envoyé : \(Int(values[0]))")
            }
            return 0
        } catch {
            log("Commande refusée : \(error)")
            return 1
        }
    }
}
