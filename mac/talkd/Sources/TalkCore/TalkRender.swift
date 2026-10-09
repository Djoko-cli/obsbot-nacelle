import CoreAudioTypes
import Foundation

/// Un format PCM flottant (Float32) : ce que la sortie demande à l'AUHAL en entrée de son bus 0.
public struct PCMFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var interleaved: Bool

    public init(sampleRate: Double, channels: Int, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.interleaved = interleaved
    }
}

/// Le rendu temps réel de talkd : la fonction C que l'AUHAL appelle sur son fil d'E/S (défaut C1 et I1 de la relecture).
///
/// - **Hors de tout acteur.** `callback` désigne une fonction globale, non isolée : un pointeur de fonction C ne porte
///   aucune isolation, donc aucun contrôle d'exécuteur du MainActor (SE-0423) ne peut l'arrêter sur le fil audio,
///   même quand `HALOutput`, qui est @MainActor, le prend pour le donner à l'AUHAL. Les tests le vérifient depuis un
///   autre fil, et une sonde en processus à part montre la différence avec un bloc formé dans le MainActor.
/// - **Rien d'interdit sur le fil audio.** Aucune allocation, aucun appel isolé, aucun verrou propre : elle lit le
///   `JitterBuffer` existant (son verrou interne, `os_unfair_lock`, est tenu le temps d'une copie ; relecture M1).
/// - **Format : Float32, 16 kHz, deux canaux non entrelacés.** L'AUHAL convertit la fréquence vers celle du
///   périphérique. En mono, elle ne jouerait que sur le canal gauche ; avec deux canaux non entrelacés, chaque canal
///   a sa propre mémoire contiguë : le gauche est rempli directement par `JitterBuffer.pull`, puis recopié dans le
///   droit d'un seul bloc, sans tampon intermédiaire ni pas d'entrelacement. En entrelacé, il faudrait lire dans un
///   tampon à part (alloué d'avance) puis entrelacer échantillon par échantillon.
///
/// Ce fichier n'importe que `CoreAudioTypes` (les structures `AudioBufferList` et `AudioTimeStamp`) : aucun appel à
/// CoreAudio, donc aucun client coreaudiod. Le type du paramètre des drapeaux est `UInt32` (même représentation que
/// `AudioUnitRenderActionFlags`, d'AudioToolbox) : l'exécutable convertit le pointeur en `AURenderCallback`.
public enum TalkRender {
    /// La signature d'`AURenderCallback` : refCon (le `JitterBuffer`, non retenu), drapeaux, horodatage, bus, nombre
    /// d'images, tampons à remplir.
    public typealias Callback = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<UInt32>,
        UnsafePointer<AudioTimeStamp>,
        UInt32,
        UInt32,
        UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus

    public static let format = PCMFormat(sampleRate: Double(JitterBuffer.sampleRate), channels: 2, interleaved: false)

    /// Le pointeur de fonction à donner à l'AUHAL (`kAudioUnitProperty_SetRenderCallback`).
    public static var callback: Callback {
        talkRenderCallback
    }

    /// Remplit le premier canal depuis le tampon, au plus `frames` images et jamais plus que sa place, puis recopie ce
    /// canal dans les suivants. Un canal sans mémoire est ignoré.
    public static func fill(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, from buffer: JitterBuffer) {
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0, frames > 0 else { return }
        let buffers = buffersPointer(list)
        guard let first = buffers[0].mData else { return }
        let samples = min(frames, Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size)
        let left = first.assumingMemoryBound(to: Float.self)
        buffer.pull(into: left, count: samples)
        for index in 1..<count {
            guard let data = buffers[index].mData else { continue }
            let room = min(samples, Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size)
            data.assumingMemoryBound(to: Float.self).update(from: left, count: room)
        }
    }

    /// Les `AudioBuffer` d'une liste : un tableau de longueur variable qui suit `mNumberBuffers`.
    static func buffersPointer(_ list: UnsafeMutablePointer<AudioBufferList>) -> UnsafeMutablePointer<AudioBuffer> {
        UnsafeMutableRawPointer(list)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!)
            .assumingMemoryBound(to: AudioBuffer.self)
    }
}

/// La fonction appelée par l'AUHAL sur son fil d'E/S. Globale et non isolée : voir `TalkRender`.
private func talkRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    // Le tampon est gardé par `HALOutput` pour toute la vie du process : la référence n'est pas retenue ici.
    Unmanaged<JitterBuffer>.fromOpaque(refCon)._withUnsafeGuaranteedRef { buffer in
        TalkRender.fill(ioData, frames: Int(frames), from: buffer)
    }
    return noErr
}
