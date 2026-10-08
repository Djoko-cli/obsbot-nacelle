import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2, spec distribution § 6) : explication, outils de
/// développement s'ils manquent, choix, vérifications, autorisation.
struct SDKView: View {
    let model: SDKWindowModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(20)
        .frame(width: 460)
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
            model.reset()
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
