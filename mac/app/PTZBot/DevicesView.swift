import NacelleProtocol
import PTZBotKit
import SwiftUI

/// La fenêtre « Appareils appairés » (spec app Mac § 8.4).
struct DevicesView: View {
    let model: PanelModel
    @Environment(\.openWindow) private var openWindow
    @State private var toRevoke: AdminDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let devices = model.admin?.devices, !devices.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text(AppText.text("Appareil"))
                        Text(AppText.text("Appairé le"))
                        Text(AppText.text("État"))
                        Text(verbatim: "")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(devices, id: \.deviceID) { device in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(String(device.deviceID.prefix(8))).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(device.pairedAt.formatted(date: .abbreviated, time: .omitted))
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Labels.device(device, clients: model.admin?.clients ?? [], now: context.date))
                            }
                            HStack {
                                if let until = device.blockedUntil, until > .now {
                                    Button(AppText.text("Débloquer")) {
                                        model.unblock(device.deviceID)
                                    }
                                }
                                Button(AppText.text("Retirer…"), role: .destructive) {
                                    toRevoke = device
                                }
                            }
                        }
                    }
                }
            } else {
                Text(model.service == .active ? AppText.text("Aucun appareil appairé.") : AppText.text("ptzd ne répond pas."))
                    .foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppText.text("Appairer un iPhone…")) {
                    model.openPairing()
                    openWindow.front(WindowID.pairing)
                }
                .disabled(model.service != .active)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .confirmationDialog(
            AppText.text("Retirer \(toRevoke?.name ?? AppText.text("l'appareil")) ?"),
            isPresented: Binding(get: { toRevoke != nil }, set: { if !$0 { toRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppText.text("Retirer"), role: .destructive) {
                if let device = toRevoke {
                    model.revoke(device.deviceID)
                }
                toRevoke = nil
            }
        } message: {
            Text(AppText.text("L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite."))
        }
    }
}
