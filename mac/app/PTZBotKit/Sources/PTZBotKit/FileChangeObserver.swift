import Darwin
import Foundation

/// Prévient quand un fichier change (créé, remplacé, supprimé), derrière un protocole pour les tests. Sert à relire
/// `talkd-state.json` aussitôt que talkd l'écrit, sans attendre la relecture périodique.
@MainActor
public protocol FileChangeObserver: AnyObject {
    /// `onChange` est appelé sur le MainActor à chaque changement, jusqu'à l'annulation de la surveillance rendue.
    func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle : une source de dispatch sur le **dossier** du fichier. Un fichier écrit de façon atomique
/// (talkd : écriture dans un temporaire puis renommage) remplace son inode : une surveillance posée sur le fichier
/// lui-même perdrait la trace, alors que le dossier reçoit toujours l'événement (ajout, renommage, suppression).
/// Le dossier bouge aussi pour ses autres fichiers (journal…) : un événement n'est transmis que si le fichier suivi a
/// vraiment changé (inode, taille ou date de modification).
/// Dossier absent : aucune surveillance, la relecture périodique de l'appelant reste le filet de sécurité.
@MainActor
public final class DispatchFileChangeObserver: FileChangeObserver {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        FileWatch(url: url, onChange: onChange)
    }
}

/// La surveillance en cours. Hors de tout acteur : les rappels de dispatch tournent sur sa file privée, et le saut vers
/// le MainActor est explicite (une closure formée dans un type `@MainActor` et appelée d'un autre fil plante en Swift 6).
private final class FileWatch: Cancellable, @unchecked Sendable {
    /// Ce qui identifie une version du fichier.
    private struct Signature: Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    private let path: String
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.github.djoko-cli.ptzbot.file-watch")
    private var source: (any DispatchSourceFileSystemObject)?
    /// Touchée seulement par la file privée (et par l'init, avant le démarrage de la source).
    private var signature: Signature?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        path = url.path
        self.onChange = onChange
        signature = Self.signature(of: path)
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    func cancel() {
        source?.cancel()
    }

    /// Sur la file privée.
    private func directoryChanged() {
        let current = Self.signature(of: path)
        guard current != signature else { return }
        signature = current
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    private static func signature(of path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            inode: UInt64(info.st_ino), size: Int64(info.st_size),
            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
