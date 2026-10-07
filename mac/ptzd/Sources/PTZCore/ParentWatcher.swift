import Foundation

/// Surveille la fin d'un processus (PTZBot, le parent de ptzd ; spec ptzd dans l'app § 5.4).
/// La source de distribution `.exit` se déclenche aussi quand le parent est tué par SIGKILL.
@MainActor
public final class ParentWatcher {
    public let pid: pid_t
    private let onExit: @MainActor () -> Void
    private var source: (any DispatchSourceProcess)?
    private var fired = false

    public init(pid: pid_t, onExit: @escaping @MainActor () -> Void) {
        self.pid = pid
        self.onExit = onExit
    }

    /// Le processus n'existe plus (ESRCH). Un processus d'un autre utilisateur (EPERM) existe.
    public nonisolated static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// Commence la surveillance. Un parent déjà disparu appelle `onExit` aussitôt.
    public func start() {
        guard source == nil, !fired else { return }
        if Self.isGone(pid) {
            fire()
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        self.source = source
        source.resume()
        // Le parent a pu disparaître entre la vérification et l'inscription de la source.
        if Self.isGone(pid) {
            fire()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        stop()
        onExit()
    }
}
