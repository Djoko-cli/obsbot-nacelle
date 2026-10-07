import Foundation
import Observation

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2) : choix, vérifications, autorisation.
@MainActor
@Observable
public final class SDKWindowModel {
    public enum Phase: Equatable, Sendable {
        case choosing
        case inspecting
        case candidate(SDKCandidate)
        case rejected(String)
        case installing
        case installed
        case failed(String)
    }

    public private(set) var phase: Phase = .choosing
    @ObservationIgnored private let installer: SDKInstaller
    @ObservationIgnored private let inspect: @Sendable (URL) throws(SDKRejection) -> SDKCandidate
    /// Change à chaque choix et à chaque fermeture : un examen dépassé est jeté avec son dossier d'extraction.
    @ObservationIgnored private var generation = 0
    /// Appelé après une installation réussie (l'app relit l'état du SDK).
    @ObservationIgnored public var onInstalled: (@MainActor () -> Void)?

    public init(
        installer: SDKInstaller,
        inspect: @escaping @Sendable (URL) throws(SDKRejection) -> SDKCandidate = { url throws(SDKRejection) in try SDKInspector.inspect(url) }
    ) {
        self.installer = installer
        self.inspect = inspect
    }

    /// Examine le fichier ou le dossier choisi, hors du fil principal.
    public func choose(_ url: URL) async {
        discardCandidate()
        generation += 1
        let current = generation
        phase = .inspecting
        let inspect = inspect
        let result = await Task.detached { Result { () throws(SDKRejection) in try inspect(url) } }.value
        guard current == generation else {
            // Fenêtre fermée (ou autre choix) pendant l'examen : l'extraction ne sert plus.
            if case let .success(candidate) = result {
                SDKInspector.discard(candidate)
            }
            return
        }
        switch result {
        case let .success(candidate):
            phase = .candidate(candidate)
        case let .failure(rejection):
            phase = .rejected(rejection.message)
        }
    }

    /// « Autoriser ce SDK », après la confirmation : copie, quarantaine retirée de la copie, vérification.
    public func authorize() async {
        guard case let .candidate(candidate) = phase else { return }
        phase = .installing
        let installer = installer
        let result = await Task.detached { Result { () throws(SDKInstallError) in try installer.install(candidate) } }.value
        SDKInspector.discard(candidate)
        switch result {
        case .success:
            phase = .installed
            onInstalled?()
        case let .failure(error):
            phase = .failed(error.message)
        }
    }

    /// Fenêtre fermée ou nouveau choix : le dossier d'extraction est effacé.
    public func reset() {
        generation += 1
        discardCandidate()
        phase = .choosing
    }

    private func discardCandidate() {
        if case let .candidate(candidate) = phase {
            SDKInspector.discard(candidate)
        }
    }
}
