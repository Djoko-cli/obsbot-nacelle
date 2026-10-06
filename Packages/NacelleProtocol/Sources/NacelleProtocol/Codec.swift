import Foundation

public enum NacelleProtocolError: Error, Equatable {
    case unknownType(String)
}

/// Encodage JSON des messages : un objet par trame WebSocket texte, avec un champ `type`.
public enum NacelleCodec {
    public static func encode(_ message: ClientMessage) throws -> String {
        try string(from: message)
    }

    public static func encode(_ message: ServerMessage) throws -> String {
        try string(from: message)
    }

    public static func decodeClient(_ text: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    }

    public static func decodeServer(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    private static func string(from value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, pan, tilt, value, on, pairingID, publicKey, name, proof, deviceID, signature, id, sdp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "takeControl":
            self = .takeControl
        case "move":
            self = .move(
                pan: Self.unit(try container.decode(Double.self, forKey: .pan)),
                tilt: Self.unit(try container.decode(Double.self, forKey: .tilt))
            )
        case "zoom":
            self = .zoom(value: min(max(try container.decode(Int.self, forKey: .value), 0), 100))
        case "privacy":
            self = .privacy(on: try container.decode(Bool.self, forKey: .on))
        case "pair":
            self = .pair(
                pairingID: try container.decode(String.self, forKey: .pairingID),
                publicKey: try container.decode(Data.self, forKey: .publicKey),
                name: try container.decode(String.self, forKey: .name),
                proof: try container.decode(Data.self, forKey: .proof)
            )
        case "openPairing":
            self = .openPairing
        case "auth":
            self = .auth(
                deviceID: try container.decode(String.self, forKey: .deviceID),
                signature: try container.decode(Data.self, forKey: .signature)
            )
        case "webrtcOffer":
            self = .webrtcOffer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .takeControl:
            try container.encode("takeControl", forKey: .type)
        case let .move(pan, tilt):
            try container.encode("move", forKey: .type)
            try container.encode(pan, forKey: .pan)
            try container.encode(tilt, forKey: .tilt)
        case let .zoom(value):
            try container.encode("zoom", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .privacy(on):
            try container.encode("privacy", forKey: .type)
            try container.encode(on, forKey: .on)
        case let .pair(pairingID, publicKey, name, proof):
            try container.encode("pair", forKey: .type)
            try container.encode(pairingID, forKey: .pairingID)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(name, forKey: .name)
            try container.encode(proof, forKey: .proof)
        case .openPairing:
            try container.encode("openPairing", forKey: .type)
        case let .auth(deviceID, signature):
            try container.encode("auth", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(signature, forKey: .signature)
        case let .webrtcOffer(id, sdp):
            try container.encode("webrtcOffer", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sdp, forKey: .sdp)
        }
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}

extension StateSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case camera, control, privacy, pan, tilt, zoom, moving
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            camera: try container.decode(CameraPresence.self, forKey: .camera),
            control: try container.decode(ControlState.self, forKey: .control),
            privacy: try container.decode(Bool.self, forKey: .privacy),
            pan: try container.decodeIfPresent(Double.self, forKey: .pan),
            tilt: try container.decodeIfPresent(Double.self, forKey: .tilt),
            zoom: try container.decodeIfPresent(Int.self, forKey: .zoom),
            moving: try container.decode(Bool.self, forKey: .moving)
        )
    }

    /// Les valeurs inconnues sont écrites `null` (spec § 5), pas omises.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(camera, forKey: .camera)
        try container.encode(control, forKey: .control)
        try container.encode(privacy, forKey: .privacy)
        try container.encode(pan, forKey: .pan)
        try container.encode(tilt, forKey: .tilt)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(moving, forKey: .moving)
    }
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, code, message, nonce, deviceID, id, sdp, lanKey, invitation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "state":
            self = .state(try StateSnapshot(from: decoder))
        case "error":
            self = .error(
                code: try container.decode(ErrorCode.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "challenge":
            self = .challenge(nonce: try container.decode(Data.self, forKey: .nonce))
        case "authenticated":
            self = .authenticated
        case "pairingOpened":
            self = .pairingOpened(try container.decode(PairingInvitation.self, forKey: .invitation))
        case "paired":
            self = .paired(deviceID: try container.decode(String.self, forKey: .deviceID), lanKey: try container.decode(Data.self, forKey: .lanKey))
        case "webrtcAnswer":
            self = .webrtcAnswer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
        case "webrtcError":
            self = .webrtcError(id: try container.decode(Int.self, forKey: .id), message: try container.decode(String.self, forKey: .message))
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .state(snapshot):
            try container.encode("state", forKey: .type)
            try snapshot.encode(to: encoder)
        case let .error(code, message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case let .challenge(nonce):
            try container.encode("challenge", forKey: .type)
            try container.encode(nonce, forKey: .nonce)
        case .authenticated:
            try container.encode("authenticated", forKey: .type)
        case let .pairingOpened(invitation):
            try container.encode("pairingOpened", forKey: .type)
            try container.encode(invitation, forKey: .invitation)
        case let .paired(deviceID, lanKey):
            try container.encode("paired", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(lanKey, forKey: .lanKey)
        case let .webrtcAnswer(id, sdp):
            try container.encode("webrtcAnswer", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sdp, forKey: .sdp)
        case let .webrtcError(id, message):
            try container.encode("webrtcError", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(message, forKey: .message)
        }
    }
}
