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
        case type, pan, tilt, value, on
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
        case type, code, message
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
        }
    }
}
