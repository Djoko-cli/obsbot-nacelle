import SwiftUI

/// Réglages de connexion : saisis au premier lancement, modifiables ensuite.
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    // Ports saisis en texte : un champ lié à un Int ne se met à jour qu'à la validation (Retour ou perte
    // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
    @State private var go2rtcPortText = ""
    @State private var ptzdPortText = ""

    /// Les réglages tels que saisis, ports compris.
    private var edited: ConnectionSettings {
        var settings = draft
        settings.go2rtcPort = ConnectionSettings.port(from: go2rtcPortText)
        settings.ptzdPort = ConnectionSettings.port(from: ptzdPortText)
        return settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mon-mac.tailnet.ts.net", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Le nom Tailscale du Mac (MagicDNS) ou son adresse IPv4 Tailscale. Tailscale doit être actif sur l'iPhone.")
                }
                Section("Vidéo (go2rtc)") {
                    LabeledContent("Port") {
                        TextField("1984", text: $go2rtcPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Flux") {
                        TextField("obsbot", text: $draft.streamName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Nacelle (ptzd)") {
                    LabeledContent("Port") {
                        TextField("1985", text: $ptzdPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        settings = edited
                        dismiss()
                    }
                    .disabled(!edited.isComplete)
                }
            }
        }
        .onAppear {
            draft = settings
            go2rtcPortText = String(settings.go2rtcPort)
            ptzdPortText = String(settings.ptzdPort)
        }
    }
}
