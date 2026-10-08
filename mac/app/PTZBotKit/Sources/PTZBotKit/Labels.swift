import Foundation
import NacelleProtocol

/// Les textes du panneau et des fenêtres, au vouvoiement (spec app Mac § 8.7), traduits en anglais
/// (spec distribution § 7.1) : voir `Localization`.
public enum Labels {
    public static func route(_ route: ClientRoute) -> String {
        switch route {
        case .localNetwork: Localization.text("Réseau local")
        case .tailscale: Localization.text("Tailscale")
        case .mac: Localization.text("Ce Mac")
        }
    }

    public static func service(_ service: PanelModel.Service) -> String {
        switch service {
        case .connecting: Localization.text("Démarrage…")
        case .active: Localization.text("Actif")
        case .unreachable: Localization.text("Ne répond pas")
        }
    }

    /// « HH:mm », heure locale, sur 24 heures dans les deux langues.
    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
    }

    /// « m:ss » restant avant `deadline`, jamais négatif.
    public static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Une carte de client : nom (ou « PTZBot » pour le Mac), chemin et heure de connexion.
    public static func client(_ client: AdminClient) -> (title: String, detail: String) {
        (client.name ?? "PTZBot", Localization.text("\(route(client.route)) · depuis \(clock(client.since))"))
    }

    /// État d'un appareil dans la fenêtre « Appareils ».
    public static func device(_ device: AdminDevice, clients: [AdminClient], now: Date) -> String {
        if let until = device.blockedUntil, until > now {
            return Localization.text("expulsé jusqu'à \(clock(until))")
        }
        if let client = clients.first(where: { $0.deviceID == device.deviceID }) {
            return Localization.text("connecté · \(route(client.route))")
        }
        return Localization.text("hors ligne")
    }
}
