import Foundation
import UIKit

/// Une tâche de fond : iOS laisse finir un travail commencé même si l'app passe en arrière-plan.
@MainActor
protocol BackgroundTasking: AnyObject {
    /// Demande du temps de plus ; `onExpiry` est appelé si iOS le reprend avant la fin. Nil si refusé.
    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int?
    func end(_ id: Int)
}

@MainActor
final class UIKitBackgroundTasks: BackgroundTasking {
    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { onExpiry() }
        }
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ id: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
    }
}

/// Tout ce dont `AppModel` a besoin pour enregistrer, injecté pour que les tests n'utilisent ni caméra, ni
/// disque réel, ni Photos.
struct RecordingServices {
    var makeRecorder: @MainActor () -> any ClipRecording
    var photos: any PhotoLibrarySaving
    var files: RecordingFiles
    /// Octets disponibles pour l'usage important (`volumeAvailableCapacityForImportantUsage`).
    var freeSpace: @MainActor () -> Int64
    var background: any BackgroundTasking
    var now: @MainActor () -> Date

    @MainActor
    static func live() -> RecordingServices {
        RecordingServices(
            makeRecorder: { ClipRecorder() },
            photos: PhotoLibrarySaver(),
            files: .live(),
            freeSpace: {
                let values = try? FileManager.default.temporaryDirectory
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                // Mesure impossible : on n'empêche pas d'enregistrer.
                return values?.volumeAvailableCapacityForImportantUsage ?? .max
            },
            background: UIKitBackgroundTasks(),
            now: { Date() }
        )
    }
}
