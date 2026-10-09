import Photos

/// Où en est l'accès à Photos en « ajout seulement ».
enum PhotoAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Le rangement dans Photos, derrière un protocole pour que les tests n'y touchent pas (spec enregistrement § 4.3).
protocol PhotoLibrarySaving: Sendable {
    /// L'état actuel, sans rien demander à l'utilisateur.
    var access: PhotoAccess { get }
    /// Demande l'accès « Ajouter à Photos » si on ne l'a pas encore demandé.
    func requestAccess() async -> PhotoAccess
    /// Ajoute la vidéo à Photos. Le fichier n'est ni déplacé ni effacé : c'est à l'appelant de le faire.
    func save(videoAt url: URL) async throws
}

/// L'implémentation réelle, avec l'autorisation `.addOnly` : l'app ne peut rien lire de la photothèque.
struct PhotoLibrarySaver: PhotoLibrarySaving {
    var access: PhotoAccess {
        Self.access(for: PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAccess() async -> PhotoAccess {
        Self.access(for: await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    func save(videoAt url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    private static func access(for status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized, .limited: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}
