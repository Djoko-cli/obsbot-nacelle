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

/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5). Ordre de priorité : Mac
/// injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
enum StatusBanner {
    static func text(for inputs: BannerInputs) -> String? {
        if inputs.macUnreachable {
            return "Mac injoignable : Tailscale est-il actif ?"
        }
        switch inputs.authIssue {
        case .unpaired:
            return "iPhone non appairé : lance ptzd pair sur le Mac"
        case .badCode:
            return "Code d'appairage refusé"
        case .rejected:
            return "Accès refusé par le Mac"
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
            if state.control == .taking {
                return "Prise en main…"
            }
        }
        return inputs.connecting ? "Connexion…" : nil
    }
}
