import Foundation

/// Les clients d'un stream de go2rtc, par type (`format_name` : « rtsp », « webrtc »…), sans le préchargement
/// (« preload »), qui n'est pas un client.
public struct Go2RTCClients: Equatable, Sendable {
    public var byType: [String: Int]

    public init(byType: [String: Int] = [:]) {
        self.byType = byType
    }

    public var total: Int {
        byType.values.reduce(0, +)
    }
}

/// L'état d'un stream lu dans l'API.
public struct Go2RTCStreamStatus: Equatable, Sendable {
    public var clients: Go2RTCClients
    /// Au moins un producteur reçoit des données (un ffmpeg qui capture) ; sinon la caméra est absente ou refusée.
    public var hasActiveProducer: Bool

    public init(clients: Go2RTCClients, hasActiveProducer: Bool) {
        self.clients = clients
        self.hasActiveProducer = hasActiveProducer
    }
}

/// La réponse de `GET /api/streams` de go2rtc 1.9.14 : `{ "<stream>": { "producers": […], "consumers": […] } }`. Un
/// producteur actif porte `bytes_recv` et `medias` ; un producteur au repos (la source `ffmpeg:…#audio=opus` tant que
/// personne ne la demande) n'a que son `url`.
public enum Go2RTCStreams {
    /// nil : réponse illisible, ou stream absent.
    public static func status(of stream: String, in data: Data) -> Go2RTCStreamStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[stream] as? [String: Any] else { return nil }
        var byType: [String: Int] = [:]
        for consumer in entry["consumers"] as? [[String: Any]] ?? [] {
            let type = consumer["format_name"] as? String ?? ""
            guard type != "preload" else { continue }
            byType[type, default: 0] += 1
        }
        let active = (entry["producers"] as? [[String: Any]] ?? []).contains { producer in
            (producer["bytes_recv"] as? Int ?? 0) > 0 || !(producer["medias"] as? [Any] ?? []).isEmpty
        }
        return Go2RTCStreamStatus(clients: Go2RTCClients(byType: byType), hasActiveProducer: active)
    }
}

/// L'API locale de go2rtc, derrière un protocole pour les tests.
public protocol Go2RTCAPI: Sendable {
    /// Le corps de `GET /api/streams`.
    func streams() async throws -> Data
}

/// La vraie API, sur 127.0.0.1:1984 (fixe : spec B3 § 4).
public struct URLSessionGo2RTCAPI: Go2RTCAPI {
    public static let url = URL(string: "http://127.0.0.1:\(Go2RTCSettings.apiPort)/api/streams")!

    public init() {}

    public func streams() async throws -> Data {
        var request = URLRequest(url: Self.url, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
