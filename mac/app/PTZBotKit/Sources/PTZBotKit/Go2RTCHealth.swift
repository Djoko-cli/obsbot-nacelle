import Foundation

/// Le blocage de coreaudiod (spec B3 § 5) : plus d'un ffmpeg vidéo sous go2rtc, ou un `exec: timeout` dans le journal
/// depuis moins de 2 min. PTZBot ne le répare jamais lui-même (il faudrait les droits root) : il donne la commande.
public enum CoreAudioDetector {
    public static let timeoutWindow: TimeInterval = 120
    public static let repairCommand = "sudo killall -9 coreaudiod"

    /// Une ligne de `ps -A -ww -o pid=,ppid=,command=`.
    struct Entry {
        var pid: pid_t
        var parent: pid_t
        var command: String
    }

    static func entries(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: fields[2].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Les ffmpeg vidéo (avfoundation, sans `-vn`) parmi les descendants de `root`, le gardien : ceux de go2rtc
    /// seulement, pas ceux d'un autre programme.
    public static func videoFFmpegCount(psOutput: String, root: pid_t) -> Int {
        let all = entries(psOutput)
        var descendants: Set<pid_t> = [root]
        var grew = true
        while grew {
            grew = false
            for entry in all where !descendants.contains(entry.pid) && descendants.contains(entry.parent) {
                descendants.insert(entry.pid)
                grew = true
            }
        }
        return all.filter { entry in
            guard entry.pid != root, descendants.contains(entry.pid) else { return false }
            let program = entry.command.split(separator: " ").first.map(String.init) ?? ""
            return (program as NSString).lastPathComponent == "ffmpeg" && entry.command.contains("avfoundation")
                && !entry.command.contains(" -vn")
        }.count
    }

    public static func isStuck(videoFFmpegs: Int, lastTimeout: TimeInterval?, now: TimeInterval) -> Bool {
        if videoFFmpegs > 1 {
            return true
        }
        guard let lastTimeout else { return false }
        return now - lastTimeout < timeoutWindow
    }
}

/// Ce qu'une lecture du journal de go2rtc a trouvé.
public struct Go2RTCLogScan: Equatable, Sendable {
    public var sawTimeout = false
    public var sawAccessDenied = false

    public init(sawTimeout: Bool = false, sawAccessDenied: Bool = false) {
        self.sawTimeout = sawTimeout
        self.sawAccessDenied = sawAccessDenied
    }
}

/// Les lignes du journal de go2rtc que PTZBot reconnaît (spec B3 § 5).
public enum Go2RTCLogPatterns {
    /// go2rtc 1.9.14 : `[exec] timeout` dans le journal, `exec: timeout` dans l'erreur rendue.
    static let timeout = ["[exec] timeout", "exec: timeout"]
    /// ffmpeg refusé par macOS (avfoundation), tel que go2rtc le rapporte : `exec/rtsp` suivi de la sortie d'ffmpeg.
    static let accessDenied = ["not authorized", "denied", "failed to create av capture input device"]

    public static func scan(_ text: String) -> Go2RTCLogScan {
        var result = Go2RTCLogScan()
        for line in text.split(separator: "\n") {
            if timeout.contains(where: { line.contains($0) }) {
                result.sawTimeout = true
            }
            let lowered = line.lowercased()
            if lowered.contains("avfoundation") || lowered.contains("exec"),
               accessDenied.contains(where: { lowered.contains($0) }) {
                result.sawAccessDenied = true
            }
        }
        return result
    }
}

/// Lit la suite d'un journal depuis un point donné, sans jamais tout relire.
public struct Go2RTCLogReader: Sendable {
    public let url: URL
    public private(set) var offset: UInt64

    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    public mutating func reset(to offset: UInt64) {
        self.offset = offset
    }

    /// Ce qui a été ajouté depuis la dernière lecture : au plus les `maxBytes` derniers octets. Un journal raccourci
    /// (remplacé) se relit du début.
    public mutating func readNew(maxBytes: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset {
            offset = 0
        }
        let start = max(offset, end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        guard (try? handle.seek(toOffset: start)) != nil else { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        offset = start + UInt64(data.count)
        return String(decoding: data, as: UTF8.self)
    }
}

/// La liste des processus, derrière un protocole pour les tests. Bloquant : hors du fil de l'interface.
public protocol ProcessListing: Sendable {
    /// `ps -A -ww -o pid=,ppid=,command=` ; nil si ps échoue.
    func psOutput() -> String?
}

public struct SystemProcessListing: ProcessListing {
    public init() {}

    public func psOutput() -> String? {
        guard let result = ChildProcess.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-A", "-ww", "-o", "pid=,ppid=,command="],
                                            timeout: 5, captureOutput: true),
              result.exited, result.status == 0 else { return nil }
        return result.output
    }
}

/// Les alertes de go2rtc pour le panneau.
public struct Go2RTCHealth: Equatable, Sendable {
    public var accessDenied = false
    public var coreAudioStuck = false
    public var cameraMissing = false

    public init(accessDenied: Bool = false, coreAudioStuck: Bool = false, cameraMissing: Bool = false) {
        self.accessDenied = accessDenied
        self.coreAudioStuck = coreAudioStuck
        self.cameraMissing = cameraMissing
    }
}
