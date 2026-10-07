import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2) : explication, choix, vérifications, autorisation.
struct SDKView: View {
    let model: SDKWindowModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Labels.sdkExplanation)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Ouvrir obsbot.com/sdk") {
                    if let url = URL(string: "https://www.obsbot.com/sdk") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Choisir l'archive ou le dossier…", action: choose)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.phase == .inspecting || model.phase == .installing)

            switch model.phase {
            case .choosing:
                EmptyView()
            case .inspecting:
                ProgressView("Vérification du fichier…")
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
                Button("Autoriser ce SDK") {
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
            case let .rejected(message), let .failed(message):
                Text(message).foregroundStyle(.red)
            case .installing:
                ProgressView("Installation du SDK…")
            case .installed:
                Text("SDK installé : le suivi IA est disponible.").foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("Autoriser ce SDK ?", isPresented: $confirming) {
            Button("Autoriser") {
                Task { await model.authorize() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(Labels.sdkConfirmation)
        }
        .onDisappear {
            model.reset()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "dylib") ?? .data]
        panel.message = "Choisissez l'archive du SDK OBSBOT (.zip), son dossier décompressé ou libdev.dylib."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.choose(url) }
    }
}
