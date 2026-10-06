import Foundation

/// Le port de ptzd, lu dans son `config.json` (spec app Mac § 5) ; 1985 si le fichier manque ou est illisible.
public struct PTZDConfig: Equatable, Sendable {
    public static let defaultPort = 1985
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ObsbotNacelle/config.json")

    public var port: Int
    /// Le port n'a pas pu être lu : le panneau le signale.
    public var isFallback: Bool

    public static func load(from url: URL = defaultURL) -> PTZDConfig {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PTZDConfig(port: defaultPort, isFallback: true)
        }
        guard let port = object["port"] else {
            return PTZDConfig(port: defaultPort, isFallback: false)
        }
        guard let number = port as? Int, (1...65535).contains(number) else {
            return PTZDConfig(port: defaultPort, isFallback: true)
        }
        return PTZDConfig(port: number, isFallback: false)
    }

    /// `ws://127.0.0.1:<port>` : la connexion de confiance de ptzd.
    public var url: URL {
        URL(string: "ws://127.0.0.1:\(port)")!
    }
}
