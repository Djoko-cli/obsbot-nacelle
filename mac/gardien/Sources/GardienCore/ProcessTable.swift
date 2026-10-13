import Foundation

/// Un processus reconnu par son pid **et** son heure de démarrage : un pid réutilisé par un autre programme n'est pas
/// le même processus.
public struct ProcessIdentity: Equatable, Sendable {
    public var pid: pid_t
    var startSeconds: Int64
    var startMicroseconds: Int64
    var groupID: pid_t
    var name: String
}

/// Ce que le gardien lit de la table des processus (libproc).
public enum ProcessTable {
    /// Le processus `pid`, s'il existe ; nil sinon.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return ProcessIdentity(
            pid: pid, startSeconds: Int64(info.pbi_start_tvsec), startMicroseconds: Int64(info.pbi_start_tvusec),
            groupID: pid_t(info.pbi_pgid), name: withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        )
    }

    /// Les enfants directs de `pid`, tels qu'ils sont à cet instant.
    public static func children(of pid: pid_t) -> [ProcessIdentity] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, min(count, pids.count))).filter { $0 > 0 }.compactMap { identity(of: $0) }
    }

    /// Les membres du groupe de processus `group` qui ne sont pas des zombies (un zombie est déjà mort : il attend
    /// seulement d'être lu par son parent).
    public static func liveMembers(ofGroup group: pid_t) -> [ProcessIdentity] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = Int(proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let count = max(0, min(bytes / MemoryLayout<pid_t>.size, pids.count))
        return pids.prefix(count).filter { $0 > 0 }.compactMap { pid in
            guard let info = bsdInfo(of: pid), info.pbi_status != UInt32(SZOMB) else { return nil }
            return identity(of: pid)
        }
    }

    /// Ce processus-là vit-il encore ? Même pid, même heure de démarrage, et pas zombie.
    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(of: identity.pid), info.pbi_status != UInt32(SZOMB) else { return false }
        return Int64(info.pbi_start_tvsec) == identity.startSeconds && Int64(info.pbi_start_tvusec) == identity.startMicroseconds
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
