import Foundation

/// Verrou de service : un seul ptzd par dossier de travail (`<support>/ptzd.lock`, `flock` exclusif).
/// Le descripteur est ouvert avec `O_CLOEXEC` : obsbot-ai, lancé par ptzd, n'en hérite pas.
/// Le verrou tombe avec le processus, même tué par SIGKILL.
public final class ServiceLock: Sendable {
    public enum Failure: Error, Equatable {
        /// Un autre ptzd tient déjà le verrou.
        case held
        case unavailable(Int32)
    }

    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Prend le verrou sans attendre ; crée le fichier (et son dossier) au besoin.
    public static func acquire(at url: URL) throws(Failure) -> ServiceLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .unavailable(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? .held : .unavailable(code)
        }
        return ServiceLock(descriptor: descriptor)
    }
}
