import Foundation

public enum RelayError: Error, Equatable {
    /// Réponse de go2rtc autre que `201` avec un SDP.
    case badResponse(status: Int)
}

/// Négociation WebRTC relayée à go2rtc pour un client authentifié (spec accès local § 6.5).
public protocol WebRTCRelay: Sendable {
    /// Le SDP de réponse à cette offre.
    func answer(offer: String) async throws -> String
}

/// `POST <api>/api/webrtc?src=<flux>` sur l'API locale de go2rtc, `application/sdp`, 10 s au plus.
public struct Go2rtcRelay: WebRTCRelay {
    public static let timeout: TimeInterval = 10

    let endpoint: URL
    private let session: URLSession

    /// Nil si l'adresse de l'API ne donne pas d'URL.
    public init?(api: String, stream: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        guard var components = URLComponents(string: api) else { return nil }
        components.path = "/api/webrtc"
        components.queryItems = [URLQueryItem(name: "src", value: stream)]
        guard let endpoint = components.url else { return nil }
        self.endpoint = endpoint
        self.session = session
    }

    public func answer(offer: String) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let sdp = String(data: data, encoding: .utf8), sdp.hasPrefix("v=0") else {
            throw RelayError.badResponse(status: status)
        }
        return sdp
    }
}
