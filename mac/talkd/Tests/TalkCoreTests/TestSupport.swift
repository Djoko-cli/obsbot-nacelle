import Foundation
@testable import TalkCore

/// Journal capturé pour les assertions.
@MainActor
final class LogRecorder {
    private(set) var lines: [String] = []

    var sink: LogSink {
        { [weak self] line in self?.lines.append(line) }
    }

    func contains(_ text: String) -> Bool {
        lines.contains { $0.contains(text) }
    }
}

/// Un paquet de 20 ms (320 échantillons à 16 kHz) de valeur constante : sa valeur efficace vaut `amplitude / 32768`.
func pcm(_ amplitude: Int16, samples: Int = 320) -> Data {
    var data = Data(capacity: samples * 2)
    for _ in 0..<samples {
        withUnsafeBytes(of: amplitude.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

/// Un paquet de voix (bien au-dessus du seuil par défaut, 0,01) et un paquet de silence.
let voice = pcm(8000)
let silence = pcm(0)

/// Un dossier temporaire neuf, supprimé par l'appelant (`defer`).
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "talkd-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
