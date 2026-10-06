import SwiftUI

/// Réglages : le Mac et l'appairage (spec accès local § 8.1). Saisis au premier lancement,
/// modifiables ensuite.
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    let isPaired: Bool
    let onPair: (String) -> Void
    let onForget: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    // Port saisi en texte : un champ lié à un Int ne se met à jour qu'à la validation (Retour ou perte
    // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
    @State private var ptzdPortText = ""
    @State private var code = ""
    @State private var confirmForget = false

    /// Les réglages tels que saisis, port compris.
    private var edited: ConnectionSettings {
        var settings = draft
        settings.ptzdPort = ConnectionSettings.port(from: ptzdPortText)
        return settings
    }

    /// Un code d'appairage complet, ou rien.
    private var codeIsValid: Bool {
        code.isEmpty || PairingCodeInput.isValid(code)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mon-mac.tailnet.ts.net", text: $draft.host)
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
                    Text("Le nom Tailscale du Mac (MagicDNS), pour piloter de partout. À la maison, l'app trouve aussi le Mac sur le Wi-Fi, sans Tailscale.")
                }
                Section {
                    LabeledContent("État", value: isPaired ? "Appairé" : "Non appairé")
                    TextField("Code à 6 chiffres", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if isPaired {
                        Button("Oublier cet appairage", role: .destructive) {
                            confirmForget = true
                        }
                    }
                } header: {
                    Text("Appairage")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal, puis saisis le code affiché (valable 5 min) et touche Enregistrer.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        settings = edited
                        if !code.isEmpty {
                            onPair(code)
                        }
                        dismiss()
                    }
                    .disabled(!edited.isComplete || !codeIsValid)
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

/// Saisie du code d'appairage.
enum PairingCodeInput {
    /// Six chiffres, espaces aux bords ignorés.
    static func isValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isASCII) && trimmed.allSatisfy(\.isNumber)
    }
}
