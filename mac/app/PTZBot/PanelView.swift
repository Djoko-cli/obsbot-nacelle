import NacelleProtocol
import PTZBotKit
import SwiftUI

/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B).
struct PanelView: View {
    let model: PanelModel
    let loginItem: LoginItemModel
    let app: AppController
    let network: LocalNetworkState
    @Environment(\.openWindow) private var openWindow

    private var supervisor: ServiceSupervisor {
        app.supervisor
    }

    private var legacy: Bool {
        app.legacy == .kept
    }

    /// Service actif et connexion de confiance établie (spec ptzd dans l'app § 6.1).
    private var active: Bool {
        Labels.controlsEnabled(supervisor.state, connection: model.service, legacy: legacy)
    }

    /// Un ordre de suivi IA est en cours (`control == .taking`).
    private var aiBusy: Bool {
        model.state?.control == .taking
    }

    private var aiNeedsSDK: Bool {
        Labels.aiNeedsSDK(app.sdkStatus, legacy: legacy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            serviceSection
            cameraSection
            iPhoneSection
            HStack(spacing: 8) {
                Button {
                    model.openPairing()
                    openWindow.front(WindowID.pairing)
                } label: {
                    Text("Appairer un iPhone…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    openWindow.front(WindowID.devices)
                } label: {
                    Text("Appareils…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(!active)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // Panneau ouvert : l'autorisation « Réseau local » a pu changer dans les Réglages.
            network.check()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            Text("PTZBot").font(.headline)
            Spacer()
            Text(Labels.service(supervisor.state, connection: model.service, legacy: legacy))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(active ? Color.green : Color.secondary)
                .background(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Service

    private var serviceSection: some View {
        PanelSection(Labels.serviceSection) {
            PanelRow(icon: "server.rack", title: "Service ptzd") {
                Toggle("Service ptzd", isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(app.legacy != .none)
            } notes: {
                if case let .failed(reason) = supervisor.state {
                    PanelNote(reason, color: .red)
                }
                if Labels.showsLog(supervisor.state, connection: model.service) {
                    Button("Ouvrir le journal de ptzd") {
                        LogOpener.openPTZDLog()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let error = app.migrationError {
                    PanelNote(error, color: .red)
                }
                if app.canReplaceLegacy {
                    Button(Labels.replaceLegacy) {
                        Task { await app.offerMigration() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                ForEach(app.migrationProblems + (app.configError.map { [$0] } ?? []), id: \.self) { problem in
                    PanelNote(problem)
                }
                if model.config.isFallback {
                    PanelNote("config.json illisible : port 1985 essayé.")
                }
            }
            Divider()
            PanelRow(icon: "shippingbox", title: "SDK OBSBOT") {
                HStack(spacing: 6) {
                    Text(Labels.sdk(app.sdkStatus)).foregroundStyle(.secondary)
                    if let action = Labels.sdkAction(app.sdkStatus) {
                        Button(action) {
                            openWindow.front(WindowID.sdk)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    // MARK: - Caméra

    private var cameraSection: some View {
        PanelSection(Labels.cameraSection(model.state?.camera)) {
            PanelRow(icon: "eye.slash", title: "Vie privée") {
                Toggle("Vie privée", isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            PanelRow(icon: "person.crop.square", title: "Suivi IA") {
                HStack(spacing: 6) {
                    if aiBusy {
                        // obsbot-ai démarre ou travaille : l'interrupteur attend la fin de l'ordre.
                        ProgressView().controlSize(.small)
                    }
                    Toggle("Suivi IA", isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(model.state?.privacy != false || aiBusy || aiNeedsSDK)
                }
            } notes: {
                if let note = Labels.aiNote(model.state?.aiTracking, needsSDK: aiNeedsSDK) {
                    PanelNote(note)
                }
            }
        } notes: {
            if let error = model.lastError {
                PanelNote(error, color: .red)
            }
        }
        .disabled(!active)
    }

    // MARK: - iPhone

    private var iPhoneSection: some View {
        let clients = model.iPhoneClients
        return PanelSection(Labels.iPhoneSection(count: clients.count)) {
            if clients.isEmpty {
                PanelRow(icon: "iphone", title: Labels.noIPhone, secondaryTitle: true) {
                    EmptyView()
                }
            }
            ForEach(Array(clients.enumerated()), id: \.element.id) { index, client in
                if index > 0 {
                    Divider()
                }
                let label = Labels.client(client)
                PanelRow(icon: "iphone", title: label.title, subtitle: label.detail) {
                    Button("Expulser", role: .destructive) {
                        if let deviceID = client.deviceID {
                            model.kick(deviceID)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!active)
                }
            }
        } notes: {
            if app.tailscaleMissing {
                PanelNote(Labels.tailscaleMissing)
            }
            if network.denied {
                PanelNote(Labels.localNetworkDenied, color: .orange)
                Button("Ouvrir les réglages de confidentialité") {
                    network.openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Ouvrir à la connexion", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quitter") {
                    // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
                    // La fin de l'app attend ensuite l'arrêt de ptzd, 5 s au plus (AppDelegate).
                    // Par la boucle d'exécution, jamais depuis un bloc de la file principale : voir
                    // AppDelegate.applicationShouldTerminate.
                    model.closePairing()
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3, inModes: [.common])
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if loginItem.needsApproval {
                Button("Autorisez PTZBot dans Réglages › Général › Ouverture") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let error = loginItem.lastError {
                PanelNote(error, color: .red)
            }
        }
    }
}

/// Une section du panneau : légende discrète, boîte arrondie, puis ses messages.
private struct PanelSection<Content: View, Notes: View>: View {
    let caption: String
    @ViewBuilder let content: Content
    @ViewBuilder let notes: Notes

    init(_ caption: String, @ViewBuilder content: () -> Content, @ViewBuilder notes: () -> Notes = { EmptyView() }) {
        self.caption = caption
        self.content = content()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            notes
        }
    }
}

/// Une ligne de boîte : icône, titre (et sous-titre), commande alignée à droite ; ses messages dessous,
/// sans déranger l'alignement.
private struct PanelRow<Trailing: View, Notes: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var secondaryTitle = false
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let notes: Notes

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        secondaryTitle: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder notes: () -> Notes = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.secondaryTitle = secondaryTitle
        self.trailing = trailing()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(secondaryTitle ? .secondary : .primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                notes
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Un petit message sous une ligne ou une section.
private struct PanelNote: View {
    let text: String
    let color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
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
