import NacelleProtocol

/// Ce que le bandeau d'état doit connaître.
struct BannerInputs: Equatable {
    var macUnreachable: Bool
    /// Ce qui empêche l'authentification auprès de ptzd.
    var authIssue: PTZClient.AuthIssue? = nil
    /// WebSocket ou vidéo en cours de connexion.
    var connecting: Bool
    var state: StateSnapshot?
}

/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5, spec découverte et QR § 8.4). Ordre de
/// priorité : Mac injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, connexion.
/// Un ordre de suivi IA en cours (`control == .taking`) n'a pas de bandeau : le bouton du suivi IA l'indique.
enum StatusBanner {
    static let qrRefused = "QR code refusé : relancez l'appairage sur le Mac"

    static func text(for inputs: BannerInputs) -> String? {
        if inputs.macUnreachable {
            return "Mac injoignable : Tailscale est-il actif ?"
        }
        switch inputs.authIssue {
        case .unpaired:
            return "iPhone non appairé : scannez le QR code affiché sur le Mac"
        case .badCode:
            return qrRefused
        case .rejected:
            return "Accès refusé par le Mac"
        case .blocked:
            return "Expulsé par le Mac : réessayez plus tard"
        case nil:
            break
        }
        if let state = inputs.state {
            if state.camera == .absent {
                return "Caméra débranchée"
            }
            if state.privacy {
                return "Vie privée"
            }
            if state.control == .failed {
                return "Suivi IA non coupé : les mouvements peuvent être contrés"
            }
        }
        return inputs.connecting ? "Connexion…" : nil
    }
}
