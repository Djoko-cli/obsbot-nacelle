import Foundation

/// La recherche de ffmpeg (spec B3 § 3.5) : le chemin réglé dans l'onglet « Caméra », puis Homebrew sur Apple Silicon,
/// puis sur Intel. Il faut un exécutable qui répond à `-version`. ffmpeg n'est jamais fourni avec PTZBot : la version de
/// Homebrew est sous GPL.
public struct FFmpegLocator: Sendable {
    public static let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    /// La commande donnée quand ffmpeg manque.
    public static let installCommand = "brew install ffmpeg"
    /// Le délai de `ffmpeg -version`.
    public static let versionTimeout: TimeInterval = 5

    private let isExecutable: @Sendable (String) -> Bool
    private let respondsToVersion: @Sendable (String) -> Bool

    public init(isExecutable: @escaping @Sendable (String) -> Bool, respondsToVersion: @escaping @Sendable (String) -> Bool) {
        self.isExecutable = isExecutable
        self.respondsToVersion = respondsToVersion
    }

    /// Le premier candidat exécutable qui répond à `-version` ; un chemin réglé passe en premier s'il est absolu. nil :
    /// introuvable. Bloquant (`ffmpeg -version`) : hors du fil de l'interface.
    public func locate(configured: String?) -> URL? {
        var paths = Self.candidates
        if let configured, configured.hasPrefix("/") {
            paths.insert(configured, at: 0)
        }
        for path in paths where isExecutable(path) && respondsToVersion(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Les vrais fichiers, et un vrai `ffmpeg -version` (5 s au plus).
    public static func system() -> FFmpegLocator {
        FFmpegLocator(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            respondsToVersion: { path in
                let result = ChildProcess.run(URL(fileURLWithPath: path), arguments: ["-version"], timeout: versionTimeout)
                return result?.exited == true && result?.status == 0
            }
        )
    }
}
