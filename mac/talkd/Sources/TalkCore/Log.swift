import Foundation

/// Une ligne de journal. Jamais de son : le journal dit ce qui se passe, pas ce qui se dit.
public typealias LogSink = @MainActor (String) -> Void
