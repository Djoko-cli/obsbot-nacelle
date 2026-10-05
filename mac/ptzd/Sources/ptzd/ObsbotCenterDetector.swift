import Darwin

/// Détecte OBSBOT Center par la liste des processus (libproc), sans AppKit :
/// AppKit chargerait CoreAudio et AudioToolbox dans ptzd (contraire aux contraintes).
enum ObsbotCenterDetector {
    static let bundleMarker = "/OBSBOT_Center.app/"

    static func isRunning() -> Bool {
        // Sans tampon, proc_listallpids renvoie le nombre de processus ; marge pour ceux
        // qui naissent entre les deux appels.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let bytes = path.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            if String(decoding: bytes, as: UTF8.self).contains(bundleMarker) {
                return true
            }
        }
        return false
    }
}
