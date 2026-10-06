import SwiftUI

/// Réglages : l'adresse du Mac en repli et l'appairage (spec découverte et QR § 8.1).
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    let isPaired: Bool
    let onForget: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    // Port saisi en texte : un champ lié à un Int ne se met à jour qu'à la validation (Retour ou perte
    // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
    @State private var ptzdPortText = ""
    @State private var confirmForget = false

    /// Les réglages tels que saisis, port compris.
    private var edited: ConnectionSettings {
        var settings = draft
        settings.ptzdPort = ConnectionSettings.port(from: ptzdPortText)
        return settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse du Mac (repli)", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    LabeledContent("Port ptzd") {
                        TextField("1985", text: $ptzdPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Retenue à l'appairage. Une adresse locale sert à la maison, et en 4G par la route de sous-réseau du NAS (Tailscale actif sur l'iPhone). Vide : l'app cherche le Mac sur le Wi-Fi.")
                }
                Section {
                    LabeledContent("État", value: isPaired ? "Appairé" : "Non appairé")
                    if isPaired {
                        Button("Oublier cet appairage", role: .destructive) {
                            confirmForget = true
                        }
                    }
                } header: {
                    Text("Appairage")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal pour afficher un QR code, valable 5 min.")
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
                    .disabled(!edited.isValid)
                }
            }
            .confirmationDialog("Oublier l'appairage ?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Oublier", role: .destructive) {
                    onForget()
                }
            } message: {
                Text("Le Mac refusera cet iPhone jusqu'au prochain appairage.")
            }
        }
        .onAppear {
            draft = settings
            ptzdPortText = String(settings.ptzdPort)
        }
    }
}
