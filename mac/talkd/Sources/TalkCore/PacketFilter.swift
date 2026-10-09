import Foundation

/// Le verdict sur un paquet reçu (spec haut-parleur § 5.2).
public enum PacketVerdict: Equatable, Sendable {
    case accepted
    /// L'adresse source n'est pas dans `allowedSources`.
    case unauthorizedSource
    /// Vide, de taille impaire (des échantillons de 16 bits) ou de plus de 4 Ko.
    case badSize
}

/// Le filtre des sources et des tailles. La source est jugée avant la taille.
public struct PacketFilter: Sendable {
    public static let maxPacketSize = 4096

    private let allowed: Set<String>

    public init(allowedSources: [String]) {
        allowed = Set(allowedSources)
    }

    public func verdict(size: Int, from source: String) -> PacketVerdict {
        guard allowed.contains(source) else { return .unauthorizedSource }
        guard size > 0, size.isMultiple(of: 2), size <= Self.maxPacketSize else { return .badSize }
        return .accepted
    }
}
