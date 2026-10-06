import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Messages de l'app vers ptzd")
struct ClientMessageTests {
    @Test("Aller-retour de chaque message", arguments: [
        ClientMessage.takeControl,
        .move(pan: 0.5, tilt: -0.25),
        .zoom(value: 33),
        .privacy(on: true),
        .privacy(on: false),
        .pair(pairingID: "1a2b3c4d", publicKey: Data([4, 1, 2, 3]), name: "iPhone", proof: Data(repeating: 5, count: 32)),
        .openPairing,
        .auth(deviceID: "00112233445566778899aabbccddeeff", signature: Data([48, 69, 2, 1])),
        .webrtcOffer(id: 3, sdp: "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"),
    ])
    func roundTrip(_ message: ClientMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeClient(text) == message)
    }

    @Test("pair : identifiant, clé publique et preuve en base64")
    func pairFormat() throws {
        let text = try NacelleCodec.encode(ClientMessage.pair(pairingID: "1a2b3c4d", publicKey: Data([1, 2, 3]), name: "iPhone", proof: Data([9])))
        #expect(text == #"{"name":"iPhone","pairingID":"1a2b3c4d","proof":"CQ==","publicKey":"AQID","type":"pair"}"#)
    }

    @Test("takeControl s'écrit avec son seul type")
    func takeControlFormat() throws {
        #expect(try NacelleCodec.encode(ClientMessage.takeControl) == #"{"type":"takeControl"}"#)
    }

    @Test("move est borné à -1…1")
    func moveIsClamped() throws {
        let message = try NacelleCodec.decodeClient(#"{"type":"move","pan":3,"tilt":-7}"#)
        #expect(message == .move(pan: 1, tilt: -1))
    }

    @Test("zoom est borné à 0…100")
    func zoomIsClamped() throws {
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":250}"#) == .zoom(value: 100))
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":-5}"#) == .zoom(value: 0))
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("dance")) {
            try NacelleCodec.decodeClient(#"{"type":"dance"}"#)
        }
    }

    @Test("Un message mal formé est rejeté")
    func malformedIsRejected() {
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient("pas du json") }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"move","pan":0.5}"#) }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"zoom","value":"fort"}"#) }
    }
}

@Suite("Messages de ptzd vers l'app")
struct ServerMessageTests {
    static let known = StateSnapshot(
        camera: .connected, control: .ready, privacy: false,
        pan: 2, tilt: -1, zoom: 33, moving: true
    )
    static let unknown = StateSnapshot(
        camera: .absent, control: .idle, privacy: true,
        pan: nil, tilt: nil, zoom: nil, moving: false
    )

    @Test("Aller-retour de chaque message", arguments: [
        ServerMessage.state(known),
        .state(unknown),
        .error(code: .privacyActive, message: "Vie privée active : mouvement refusé."),
        .error(code: .unpaired, message: "Appareil inconnu."),
        .error(code: .notLocal, message: "Réseau local seulement."),
        .pairingOpened(PairingInvitation(
            pairingID: "1a2b3c4d", secret: Data(repeating: 1, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30", "192.0.2.43"], port: 1985
        )),
        .challenge(nonce: Data(repeating: 7, count: 32)),
        .authenticated,
        .paired(deviceID: "00112233445566778899aabbccddeeff", lanKey: Data(repeating: 9, count: 32)),
        .webrtcAnswer(id: 3, sdp: "v=0\r\n"),
        .webrtcError(id: 3, message: "go2rtc ne répond pas."),
    ])
    func roundTrip(_ message: ServerMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeServer(text) == message)
    }

    @Test("Les valeurs inconnues sont écrites null")
    func unknownValuesAreNull() throws {
        let text = try NacelleCodec.encode(ServerMessage.state(Self.unknown))
        #expect(text == #"{"camera":"absent","control":"idle","moving":false,"pan":null,"privacy":true,"tilt":null,"type":"state","zoom":null}"#)
    }

    @Test("pairingOpened : échéance en secondes depuis 1970")
    func pairingOpenedFormat() throws {
        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data([1]), expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30"], port: 1985)
        let text = try NacelleCodec.encode(ServerMessage.pairingOpened(invitation))
        #expect(text.contains(#""expiresAt":1791300000"#))
    }

    @Test("authenticated s'écrit avec son seul type")
    func authenticatedFormat() throws {
        #expect(try NacelleCodec.encode(ServerMessage.authenticated) == #"{"type":"authenticated"}"#)
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("hello")) {
            try NacelleCodec.decodeServer(#"{"type":"hello"}"#)
        }
    }
}
