import Foundation

/// Les codes de sortie propres au gardien ; ceux du programme sont rendus tels quels.
public enum GardienExit {
    /// Options refusées (EX_USAGE).
    public static let usage: Int32 = 64
    /// Le parent avait déjà disparu : rien n'est lancé (EX_UNAVAILABLE).
    public static let parentGone: Int32 = 69
    /// kqueue refusé par le système, avant tout lancement (EX_OSERR).
    public static let systemError: Int32 = 71
    /// Le programme n'a pas pu être lancé (la convention des shells).
    public static let launchFailed: Int32 = 127
}

/// La fin du programme, lue dans le statut de `waitpid`.
public enum ChildEnd: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// WIFEXITED, WEXITSTATUS et WTERMSIG, que Swift n'importe pas (le bit 0x80 dit seulement qu'un core a été écrit).
    public init(waitStatus status: Int32) {
        if status & 0x7f == 0 {
            self = .exited((status >> 8) & 0xff)
        } else {
            self = .signaled(status & 0x7f)
        }
    }
}
