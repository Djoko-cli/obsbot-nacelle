import Foundation

/// Ce que PTZBot reprend d'une configuration go2rtc existante (spec B3 § 4) : l'identifiant, le mot de passe RTSP, les
/// ports et, s'ils sont reconnus, les noms des appareils et le chemin de ffmpeg. Le fichier lu n'est jamais modifié.
public struct Go2RTCImport: Equatable, Sendable {
    public var username: String?
    public var password: String?
    public var rtspPort: Int?
    public var webrtcPort: Int?
    public var cameraName: String?
    public var microphoneName: String?
    public var ffmpegPath: String?

    public init(
        username: String? = nil, password: String? = nil, rtspPort: Int? = nil, webrtcPort: Int? = nil,
        cameraName: String? = nil, microphoneName: String? = nil, ffmpegPath: String? = nil
    ) {
        self.username = username
        self.password = password
        self.rtspPort = rtspPort
        self.webrtcPort = webrtcPort
        self.cameraName = cameraName
        self.microphoneName = microphoneName
        self.ffmpegPath = ffmpegPath
    }

    /// Rien de reconnu.
    public var isEmpty: Bool {
        self == Go2RTCImport()
    }

    /// Les réglages avec ce qui a été repris ; le reste est gardé. Une configuration importée devient celle que PTZBot
    /// écrit : le fichier personnalisé est coupé.
    public func applied(to settings: Go2RTCSettings) -> Go2RTCSettings {
        var result = settings
        if let username { result.username = username }
        if let password { result.password = password }
        if let rtspPort { result.rtspPort = rtspPort }
        if let webrtcPort { result.webrtcPort = webrtcPort }
        if let cameraName { result.cameraName = cameraName }
        if let microphoneName { result.microphoneName = microphoneName }
        if let ffmpegPath { result.ffmpegPath = ffmpegPath }
        result.customConfigEnabled = false
        return result
    }
}

/// Pourquoi une configuration n'a pas pu être importée.
public enum Go2RTCImportError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case nothingRecognized

    public var errorDescription: String? {
        switch self {
        case let .unreadable(reason): Localization.text("Ce fichier n'a pas pu être lu : \(reason)")
        case .nothingRecognized: Localization.text("Rien de reconnu dans ce fichier : est-ce une configuration go2rtc ?")
        }
    }
}

/// Un lecteur minimal du yaml de go2rtc, sans dépendance : il ne comprend que ce que PTZBot reprend (sections `rtsp`,
/// `webrtc`, `ffmpeg` et `streams`), ignore les commentaires et tout le reste.
public enum Go2RTCConfigReader {
    public static func read(contentsOf url: URL) throws(Go2RTCImportError) -> Go2RTCImport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw .nothingRecognized }
        let result = read(text)
        guard !result.isEmpty else { throw .nothingRecognized }
        return result
    }

    public static func read(_ text: String) -> Go2RTCImport {
        var result = Go2RTCImport()
        var section = ""
        var streamLines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            if indent == 0 {
                section = key(content) ?? ""
                continue
            }
            if section == "streams" {
                streamLines.append(content)
                continue
            }
            guard let key = key(content), let value = value(content) else { continue }
            switch (section, key) {
            case ("rtsp", "username"): result.username = value
            case ("rtsp", "password"): result.password = value
            case ("rtsp", "listen"): result.rtspPort = port(value)
            case ("webrtc", "listen"): result.webrtcPort = port(value)
            case ("ffmpeg", "bin"): result.ffmpegPath = value
            default: break
            }
        }
        let tokens = tokens(streamLines.joined(separator: " "))
        readDevices(tokens, into: &result)
        if result.ffmpegPath == nil {
            result.ffmpegPath = tokens.lazy.compactMap(execProgram).first
        }
        return result
    }

    /// La clé d'une ligne `clé: valeur` ou `clé:` ; nil pour un élément de liste ou du texte.
    static func key(_ content: String) -> String? {
        guard !content.hasPrefix("-"), let colon = content.firstIndex(of: ":") else { return nil }
        let key = content[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let after = content[content.index(after: colon)...]
        guard after.isEmpty || after.first == " " else { return nil }
        return key
    }

    /// La valeur après `clé:` : entre guillemets doubles (`\"` et `\\` échappés), simples (`''` pour `'`), ou nue
    /// jusqu'à un commentaire (` #`). nil si elle est vide ou si un guillemet ne se ferme pas.
    static func value(_ content: String) -> String? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let raw = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let first = raw.first else { return nil }
        var result = ""
        if first == "\"" {
            var escaped = false
            for character in raw.dropFirst() {
                if escaped {
                    result.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return result
                } else {
                    result.append(character)
                }
            }
            return nil
        }
        if first == "'" {
            let characters = Array(raw.dropFirst())
            var index = 0
            while index < characters.count {
                if characters[index] == "'" {
                    guard index + 1 < characters.count, characters[index + 1] == "'" else { return result }
                    result.append("'")
                    index += 2
                } else {
                    result.append(characters[index])
                    index += 1
                }
            }
            return nil
        }
        let plain = raw.range(of: " #").map { String(raw[..<$0.lowerBound]) } ?? raw
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Le port d'une adresse d'écoute (« :8554 », « 0.0.0.0:8554 », « 8554 »).
    static func port(_ listen: String) -> Int? {
        let digits = listen.lastIndex(of: ":").map { listen[listen.index(after: $0)...] } ?? Substring(listen)
        guard let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }

    /// Les mots d'une commande, comme les découpe go2rtc (`shell.QuoteSplit`), en plus tolérant : un guillemet qui ne
    /// se ferme pas prend le reste du texte.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first == " " || first == "\t" {
                rest = rest.dropFirst()
            } else if first == "\"" || first == "'" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: first) ?? body.endIndex
                result.append(String(body[..<end]))
                rest = end == body.endIndex ? "" : body[body.index(after: end)...]
            } else {
                let end = rest.firstIndex { $0 == " " || $0 == "\t" } ?? rest.endIndex
                result.append(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        return result
    }

    /// Après chaque `-f avfoundation`, l'entrée `-i` : « :micro », « caméra » ou « caméra:micro ». Un numéro (« 0 »),
    /// « none » ou « default » n'est pas un nom : non reconnu. Le premier de chaque sorte est gardé.
    static func readDevices(_ tokens: [String], into result: inout Go2RTCImport) {
        var index = 0
        while index + 1 < tokens.count {
            defer { index += 1 }
            guard tokens[index] == "-f", tokens[index + 1] == "avfoundation",
                  let input = tokens[(index + 2)...].firstIndex(of: "-i"), input + 1 < tokens.count else { continue }
            let parts = tokens[input + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if result.cameraName == nil, isName(parts[0]) {
                result.cameraName = parts[0]
            }
            if result.microphoneName == nil, parts.count > 1, isName(parts[1]) {
                result.microphoneName = parts[1]
            }
        }
    }

    static func isName(_ text: String) -> Bool {
        !text.isEmpty && Int(text) == nil && text != "none" && text != "default"
    }

    /// `exec:/chemin/ffmpeg` : le chemin, s'il est absolu et finit par ffmpeg.
    static func execProgram(_ token: String) -> String? {
        guard token.hasPrefix("exec:") else { return nil }
        let program = String(token.dropFirst(5))
        return program.hasPrefix("/") && (program as NSString).lastPathComponent == "ffmpeg" ? program : nil
    }
}

extension Go2RTCSettings {
    /// Les réglages au lancement : les préférences, et le mot de passe relu du yaml de PTZBot (`config`). Sans yaml
    /// lisible, un mot de passe neuf : le premier yaml écrit le retiendra.
    @MainActor
    public static func restore(from store: any SettingsStore, config: URL) -> Go2RTCSettings {
        var settings = load(from: store)
        if let password = (try? Go2RTCConfigReader.read(contentsOf: config))?.password, !password.isEmpty {
            settings.password = password
        } else {
            settings.password = randomPassword()
        }
        return settings
    }
}
