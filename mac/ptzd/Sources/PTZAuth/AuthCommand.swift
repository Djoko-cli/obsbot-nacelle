import Foundation

/// `ptzd devices` et `ptzd revoke` (spec accès local § 6.4), lancés à la main dans le Terminal pendant
/// que le service tourne : ils ne passent que par `devices.json`. `ptzd pair` parle au service (`PairCommand`).
public enum AuthCommand {
    public static let names: Set<String> = ["devices", "revoke"]
    public static let usage = """
    usage : ptzd devices                       liste les appareils appairés
            ptzd revoke <début d'identifiant>  retire un appareil (4 caractères au moins)
    """

    /// Code de sortie et texte à afficher.
    public static func run(_ arguments: [String], authority: DeviceAuthority) -> (status: Int32, output: String) {
        switch (arguments.first, arguments.count) {
        case ("devices", 1):
            do {
                let devices = try authority.devices.all()
                guard !devices.isEmpty else { return (0, "Aucun appareil appairé.") }
                let lines = devices.map { "\($0.deviceID.prefix(8))  \(day($0.pairedAt))  \($0.name)" }
                return (0, lines.joined(separator: "\n"))
            } catch {
                return (1, "devices.json illisible : \(error)")
            }
        case ("revoke", 2):
            do {
                let removed = try authority.devices.remove(prefix: arguments[1])
                return (0, "Retiré : \(removed.deviceID.prefix(8))  \(removed.name). Ses connexions ouvertes durent jusqu'à leur fin : pour les couper tout de suite, retirez-le plutôt depuis PTZBot sur le Mac.")
            } catch PairedDevicesError.ambiguous(let prefix) {
                return (1, "Plusieurs appareils commencent par « \(prefix) » : donner plus de caractères.")
            } catch PairedDevicesError.noMatch(let prefix) {
                return (1, "Aucun appareil ne commence par « \(prefix) » (4 caractères au moins).")
            } catch {
                return (1, "devices.json illisible : \(error)")
            }
        default:
            return (2, usage)
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
