import NacelleProtocol
import PTZBotKit
import SwiftUI

/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B).
struct PanelView: View {
    let model: PanelModel
    let loginItem: LoginItemModel
    @Environment(\.openWindow) private var openWindow

    private var active: Bool {
        model.service == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PTZBot").font(.headline)
                Spacer()
                Text(Labels.service(model.service))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(active ? Color.green.opacity(0.25) : Color.secondary.opacity(0.2), in: Capsule())
            }
            if model.service == .unreachable {
                Button("Ouvrir le journal de ptzd") {
                    LogOpener.openPTZDLog()
                }
                .buttonStyle(.link)
            }
            if model.config.isFallback {
                Text("config.json illisible : port 1985 essayé.").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                LabeledContent("Caméra", value: model.state?.camera == .connected ? "branchée" : "débranchée")
                Toggle("Vie privée", isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Suivi IA", isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
                        .disabled(model.state?.privacy != false)
                    if model.state?.aiTracking == .unknown {
                        Text("État inconnu").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(!active)

            Text("Clients connectés · \(model.admin?.clients.count ?? 0)")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(model.admin?.clients ?? [], id: \.id) { client in
                ClientCard(client: client) {
                    if let deviceID = client.deviceID {
                        model.kick(deviceID)
                    }
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Appairer un iPhone…") {
                    model.openPairing()
                    openWindow.front(WindowID.pairing)
                }
                .buttonStyle(.borderedProminent)
                Button("Appareils…") {
                    openWindow.front(WindowID.devices)
                }
            }
            .disabled(!active)
            Divider()
            Toggle("Ouvrir à la connexion", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                .toggleStyle(.checkbox)
            if loginItem.needsApproval {
                Button("Autorisez PTZBot dans Réglages › Général › Ouverture") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.link)
            }
            if let error = loginItem.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Quitter") {
                    // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
                    model.closePairing()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Une carte de client connecté ; « Expulser » sauf pour les clients du Mac.
private struct ClientCard: View {
    let client: AdminClient
    let kick: () -> Void

    var body: some View {
        let label = Labels.client(client)
        HStack {
            VStack(alignment: .leading) {
                Text(label.title)
                Text(label.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if client.route != .mac {
                Button("Expulser", role: .destructive, action: kick)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Ouvre le journal de ptzd dans Console.
enum LogOpener {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle/ptzd.log")

    @MainActor
    static func openPTZDLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([logURL], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}
