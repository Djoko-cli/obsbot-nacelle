import Foundation

/// Le contenu du QR code : `nacelle://pair?v=1&id=<pairingID>&k=<secret base64url>&h=<adresse>[,…]&p=<port>`
/// (spec découverte et QR § 6).
public struct PairingLink: Equatable, Sendable {
    public static let version = "1"

    public var pairingID: String
    public var secret: Data
    public var hosts: [String]
    public var port: Int

    public init(pairingID: String, secret: Data, hosts: [String], port: Int) {
        self.pairingID = pairingID
        self.secret = secret
        self.hosts = hosts
        self.port = port
    }

    public init(_ invitation: PairingInvitation) {
        self.init(pairingID: invitation.pairingID, secret: invitation.secret, hosts: invitation.hosts, port: invitation.port)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "nacelle"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "id", value: pairingID),
            URLQueryItem(name: "k", value: Self.base64URL(secret)),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
        ]
        return components.url!
    }

    /// Nil pour un QR qui n'est pas un appairage Nacelle de cette version, ou incomplet.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nacelle", components.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        guard values["v"] == Self.version,
              let id = values["id"], !id.isEmpty, id.allSatisfy(\.isHexDigit),
              let key = values["k"].flatMap(Self.data(base64URL:)), key.count == 32,
              let hostList = values["h"], let portText = values["p"], let port = Int(portText),
              (1...65535).contains(port) else { return nil }
        let hosts = hostList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.init(pairingID: id, secret: key, hosts: hosts, port: port)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
