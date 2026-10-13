import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// L'onglet « SDK OBSBOT » des Réglages (spec ptzd dans l'app § 6.2, spec distribution § 6, banc du 13/10 : il était une
/// fenêtre à part, et sa ligne du panneau y est passée) : l'état du SDK, puis l'explication, les outils de
/// développement s'ils manquent, le choix, les vérifications et l'autorisation.
struct SDKView: View {
    let model: SDKWindowModel
    let app: AppController
    @State private var confirming = false

    var body: some View {
        Form {
            statusSection
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert(AppText.text("Autoriser ce SDK ?"), isPresented: $confirming) {
            Button(AppText.text("Autoriser")) {
                Task { await model.authorize() }
            }
            Button(AppText.text("Annuler"), role: .cancel) {}
        } message: {
            Text(Labels.sdkConfirmation)
        }
        .task {
            await model.checkTools()
        }
        .onDisappear {
            // Changer d'onglet ne doit pas interrompre l'affichage d'une installation en cours.
            if model.phase != .installing {
                model.reset()
            }
        }
    }

    /// L'état du SDK, comme la ligne qu'il avait dans le panneau : état court et pastille, explication dessous, et
    /// l'installation des outils de développement quand c'est l'action proposée.
    private var statusSection: some View {
        let indicator = Labels.sdkIndicator(app.sdkStatus)
        let tools = app.toolsAvailable ?? true
        return Section {
            HStack(spacing: 8) {
                Text(AppText.text("SDK OBSBOT"))
                Spacer(minLength: 8)
                if let line = indicator.line {
                    Text(line)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                StatusDot(tone: indicator.tone)
            }
            if let detail = Labels.sdkDetail(app.sdkStatus, toolsAvailable: tools) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = Labels.sdkAction(app.sdkStatus, toolsAvailable: tools),
               Labels.sdkActionInstallsTools(app.sdkStatus, toolsAvailable: tools) {
                Button(action) {
                    app.installDeveloperTools()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Text(Labels.sdkExplanation)
            .fixedSize(horizontal: false, vertical: true)
        if model.toolsAvailable {
            choiceButtons
        } else {
            // Sans les outils d'Apple, obsbot-ai ne peut pas être compilé : ils passent avant le choix du SDK.
            Text(Labels.sdkToolsExplanation)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(Labels.installTools) {
                    model.installTools()
                }
                .buttonStyle(.borderedProminent)
                Button(Labels.checkToolsAgain) {
                    Task { await model.checkTools() }
                }
            }
        }

        switch model.phase {
        case .choosing:
            EmptyView()
        case .inspecting:
            ProgressView(AppText.text("Vérification du fichier…"))
        case let .candidate(candidate):
            Text(candidate.path.lastPathComponent).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Labels.sdkChecks(candidate), id: \.title) { check in
                    GridRow {
                        Text(check.title).foregroundStyle(.secondary)
                        Text(check.value).textSelection(.enabled)
                    }
                }
            }
            Button(AppText.text("Autoriser ce SDK")) {
                confirming = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.toolsAvailable)
        case let .rejected(message), let .failed(message):
            Text(message).foregroundStyle(.red)
        case .installing:
            ProgressView(AppText.text("Installation du SDK et compilation d'obsbot-ai…"))
        case .installed:
            Text(AppText.text("SDK installé : le suivi IA est disponible.")).foregroundStyle(.green)
        }
    }

    private var choiceButtons: some View {
        HStack {
            Button(AppText.text("Ouvrir obsbot.com/sdk")) {
                if let url = URL(string: "https://www.obsbot.com/sdk") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(AppText.text("Choisir l'archive ou le dossier…"), action: choose)
                .buttonStyle(.borderedProminent)
        }
        .disabled(model.phase == .inspecting || model.phase == .installing)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = AppText.text("Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.choose(url) }
    }
}
