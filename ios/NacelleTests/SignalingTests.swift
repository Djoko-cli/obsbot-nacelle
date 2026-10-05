import Foundation
import Testing
@testable import Nacelle

@Suite("Signalisation WebRTC")
struct SignalingTests {
    let url = URL(string: "http://mac.exemple.ts.net:1984/api/webrtc?src=obsbot")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test("Requête : POST de l'offre, en application/sdp")
    func request() {
        let request = Signaling.request(url: url, offerSDP: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n")
        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
        #expect(request.httpBody == Data("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n".utf8))
        #expect(request.timeoutInterval == Signaling.timeout)
    }

    @Test("Réponse 201 avec un SDP : acceptée")
    func answer() throws {
        let sdp = "v=0\r\ns=-\r\n"
        #expect(try Signaling.answer(data: Data(sdp.utf8), response: response(201)) == sdp)
    }

    @Test("Autre statut ou corps non SDP : refusé")
    func badAnswer() {
        #expect(throws: SignalingError.badResponse(status: 500)) {
            try Signaling.answer(data: Data("v=0".utf8), response: response(500))
        }
        #expect(throws: SignalingError.badResponse(status: 201)) {
            try Signaling.answer(data: Data("{}".utf8), response: response(201))
        }
    }
}
