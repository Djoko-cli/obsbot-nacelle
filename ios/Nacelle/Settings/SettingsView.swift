import SwiftUI

/// Réglages de connexion : saisis au premier lancement, modifiables ensuite.
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()

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
                        TextField("1984", value: $draft.go2rtcPort, format: .number.grouping(.never))
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
                        TextField("1985", value: $draft.ptzdPort, format: .number.grouping(.never))
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
                        settings = draft
                        dismiss()
                    }
                    .disabled(!draft.isComplete)
                }
            }
        }
        .onAppear {
            draft = settings
        }
    }
}
