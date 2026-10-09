import Foundation

/// La sortie audio, derrière un protocole : `HALOutput` (une AUHAL en sortie pure) dans le daemon, un faux dans les tests.
/// Elle lit le tampon (PCM 16 kHz) sur le périphérique donné ; l'AUHAL convertit vers la fréquence du
/// périphérique.
@MainActor
public protocol AudioOutput: AnyObject {
    var isRunning: Bool { get }
    /// Démarre la lecture du tampon sur le périphérique (`AudioOutputUnitStart`) ; lève si coreaudiod refuse.
    func start(device: DeviceID, feeding buffer: JitterBuffer) throws
    /// Arrête la lecture (`AudioOutputUnitStop`) ; le client CoreAudio reste le même (spec § 4.2).
    func stop()
}
