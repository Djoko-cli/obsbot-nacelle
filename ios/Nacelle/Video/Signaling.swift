import Foundation

enum SignalingError: Error, Equatable {
    /// Réponse de go2rtc autre que `201` avec un SDP.
    case badResponse(status: Int)
}

/// Échange d'offre et de réponse avec go2rtc (spec § 7.2) : une seule requête, sans « trickle ».
enum Signaling {
    static let timeout: TimeInterval = 10

    /// `POST <url>` avec l'offre SDP, `Content-Type: application/sdp`.
    static func request(url: URL, offerSDP: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offerSDP.utf8)
        return request
    }

    /// Le SDP de réponse, si go2rtc a répondu `201` avec un corps SDP.
    static func answer(data: Data, response: URLResponse) throws -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let sdp = String(data: data, encoding: .utf8), sdp.hasPrefix("v=0") else {
            throw SignalingError.badResponse(status: status)
        }
        return sdp
    }
}
