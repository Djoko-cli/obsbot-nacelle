import Foundation
import NacelleProtocol

/// Issue d'un ordre donné à obsbot-ai (spec § 6.9, spec app Mac § 7.5).
public enum AIResult: Equatable, Sendable {
    case success
    case cameraNotFound
    case sdkError
    case timeout
    case launchFailed(String)
    case unexpectedExit(Int32)

    /// Le motif, en français, pour les messages montrés à l'utilisateur (le journal garde la forme brute).
    public var userDescription: String {
        switch self {
        case .success: "réussi"
        case .cameraNotFound: AIFailureText.cameraNotFound
        case .sdkError: AIFailureText.sdkError
        case .timeout: AIFailureText.timeout
        case .launchFailed: AIFailureText.launchFailed
        case let .unexpectedExit(status): AIFailureText.unexpectedExitPrefix + String(status)
        }
    }
}

/// Allume (`on`) ou coupe le suivi IA de la caméra.
@MainActor
public protocol AIRunner: AnyObject {
    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
    /// Un client pilote : l'utilitaire peut se préparer pour que le prochain ordre parte vite.
    func prewarm()
    /// La caméra a été branchée ou débranchée : l'utilitaire garde une session du SDK qui ne vaut plus.
    func reset()
}

extension AIRunner {
    public func prewarm() {}
    public func reset() {}
}
