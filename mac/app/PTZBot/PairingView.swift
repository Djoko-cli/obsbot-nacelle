import PTZBotKit
import SwiftUI

/// La fenêtre « Appairer un iPhone » (spec app Mac § 8.3). La fermer annule l'appairage.
struct PairingView: View {
    let model: PanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var shownAt = Date()

    var body: some View {
        VStack(spacing: 12) {
            switch model.pairing?.phase {
            case .waiting, nil:
                ProgressView("Ouverture de l'appairage…")
            case let .showing(invitation):
                if let link = model.pairing?.link, let image = QRImage.make(link) {
                    Image(decorative: image, scale: 2)
                        .interpolation(.none)
                }
                Text("Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**.")
                    .multilineTextAlignment(.center)
                    .fixedSize()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let total = invitation.expiresAt.timeIntervalSince(shownAt)
                    let remaining = max(0, invitation.expiresAt.timeIntervalSince(context.date))
                    VStack(spacing: 8) {
                        if total > 0 {
                            ProgressView(value: remaining, total: total)
                        }
                        Text("Valable encore \(Labels.remaining(until: invitation.expiresAt, now: context.date)) · une seule fois")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(invitation.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                Text("Ne montrez ce code qu'à l'iPhone à appairer.").font(.caption).foregroundStyle(.secondary)
                Button("Annuler") {
                    model.closePairing()
                    dismiss()
                }
            case let .paired(name, shortID):
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("\(name) appairé").font(.headline)
                Text(shortID).font(.caption).foregroundStyle(.secondary)
            case .expired:
                Text("QR code expiré").font(.headline)
                Button("Recommencer") {
                    model.openPairing()
                }
            case .noAddress:
                Text("Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet.")
                Button("Recommencer") {
                    model.openPairing()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onChange(of: model.pairing == nil) { _, closed in
            if closed {
                dismiss()
            }
        }
        .onChange(of: model.pairing?.phase) { _, phase in
            if case .showing = phase {
                shownAt = Date()
            }
        }
        .onDisappear {
            model.closePairing()
        }
    }
}
