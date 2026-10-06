import Foundation
import NacelleProtocol
import Observation

/// Une fenêtre « Appairer un iPhone » (spec app Mac § 8.3) : attente de l'invitation, QR affiché, puis
/// appairé, expiré ou sans adresse. L'appairage réussi se lit dans l'état d'administration : l'appairage
/// en cours disparaît et un appareil nouveau apparaît.
@MainActor
@Observable
public final class PairingSession {
    public enum Phase: Equatable, Sendable {
        case waiting
        case showing(PairingInvitation)
        case paired(name: String, shortID: String)
        /// Expiré, annulé par ptzd ou fermé après trois preuves fausses.
        case expired
        /// Aucune adresse du réseau local dans l'invitation.
        case noAddress
    }

    /// Délai avant la fermeture de la fenêtre après un appairage réussi.
    public static let closeDelay: TimeInterval = 3

    public private(set) var phase: Phase = .waiting
    /// Appelé `closeDelay` après un appairage réussi : la fenêtre se ferme.
    @ObservationIgnored public var onFinished: (() -> Void)?
    @ObservationIgnored private let scheduler: any Scheduler
    /// Appareils connus à l'ouverture : un appareil absent de cette liste est le nouveau.
    @ObservationIgnored private var knownDevices: Set<String>
    @ObservationIgnored private var closing: (any Cancellable)?

    init(knownDevices: Set<String>, scheduler: any Scheduler) {
        self.knownDevices = knownDevices
        self.scheduler = scheduler
    }

    /// Le texte du QR code : le lien `nacelle://pair` de l'invitation.
    public var link: String? {
        guard case let .showing(invitation) = phase else { return nil }
        return PairingLink(invitation).url.absoluteString
    }

    func received(_ invitation: PairingInvitation) {
        guard phase == .waiting || phase == .expired else { return }
        phase = invitation.hosts.isEmpty ? .noAddress : .showing(invitation)
    }

    func adminChanged(_ state: AdminState) {
        guard case let .showing(invitation) = phase, state.pairing?.pairingID != invitation.pairingID else { return }
        if let device = state.devices.first(where: { !knownDevices.contains($0.deviceID) }) {
            phase = .paired(name: device.name, shortID: String(device.deviceID.prefix(8)))
            closing = scheduler.schedule(after: Self.closeDelay) { [weak self] in
                self?.onFinished?()
            }
        } else {
            phase = .expired
        }
    }

    /// « Recommencer » : nouvelle attente, appareils connus mis à jour.
    func restart(knownDevices: Set<String>) {
        self.knownDevices = knownDevices
        phase = .waiting
    }

    func cancel() {
        closing?.cancel()
        closing = nil
    }
}
