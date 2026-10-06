import Foundation

/// Dossier temporaire propre à un test.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ptzauth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Horloge réglable pour les tests d'expiration.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}