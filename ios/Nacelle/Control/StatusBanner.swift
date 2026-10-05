import NacelleProtocol

/// Ce que le bandeau d'état doit connaître.
struct BannerInputs: Equatable {
    var macUnreachable: Bool
    /// WebSocket ou vidéo en cours de connexion.
    var connecting: Bool
    var state: StateSnapshot?
}

/// Texte du bandeau d'état (spec § 7.3). Ordre de priorité : Mac injoignable, caméra
/// débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
enum StatusBanner {
    static func text(for inputs: BannerInputs) -> String? {
        if inputs.macUnreachable {
            return "Mac injoignable : Tailscale est-il actif ?"
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
