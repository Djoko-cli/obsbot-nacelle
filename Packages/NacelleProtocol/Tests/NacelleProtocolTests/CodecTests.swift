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
    ])
    func roundTrip(_ message: ClientMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeClient(text) == message)
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

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("hello")) {
            try NacelleCodec.decodeServer(#"{"type":"hello"}"#)
        }
    }
}
