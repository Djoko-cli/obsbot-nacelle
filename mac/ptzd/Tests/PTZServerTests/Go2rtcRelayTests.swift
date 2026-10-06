import Foundation
import Testing
@testable import PTZServer

/// Réponses HTTP de test, sans réseau.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let (status, body) = Self.respond?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Relais vers go2rtc", .serialized)
struct Go2rtcRelayTests {
    private func makeRelay() throws -> Go2rtcRelay {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try #require(Go2rtcRelay(api: "http://127.0.0.1:1984", stream: "obsbot", session: URLSession(configuration: configuration)))
    }

    @Test("POST /api/webrtc?src=<flux>, en application/sdp, offre dans le corps")
    func request() async throws {
        StubURLProtocol.respond = { _ in (201, Data("v=0\r\nréponse".utf8)) }
        let answer = try await makeRelay().answer(offer: "v=0\r\noffre")
        #expect(answer == "v=0\r\nréponse")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "http://127.0.0.1:1984/api/webrtc?src=obsbot")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
        #expect(StubURLProtocol.lastBody == Data("v=0\r\noffre".utf8))
    }

    @Test("Autre statut que 201, ou corps qui n'est pas un SDP : erreur")
    func badResponses() async throws {
        let relay = try makeRelay()
        StubURLProtocol.respond = { _ in (500, Data("v=0".utf8)) }
        await #expect(throws: RelayError.badResponse(status: 500)) { try await relay.answer(offer: "v=0") }
        StubURLProtocol.respond = { _ in (201, Data("oups".utf8)) }
        await #expect(throws: RelayError.badResponse(status: 201)) { try await relay.answer(offer: "v=0") }
    }
}
