import Foundation
import NacelleProtocol

/// `ptzd pair` (spec découverte et QR § 7.2) : demande un appairage au service par 127.0.0.1,
/// puis affiche le QR code, l'URL en texte et l'heure d'expiration.
public enum PairCommand {
    public static let timeout: TimeInterval = 5

    enum Outcome: Sendable {
        case opened(PairingInvitation)
        case refused(String)
        case noReply
    }

    /// Code de sortie et texte à afficher.
    public static func run(port: Int, timeout: TimeInterval = timeout) async -> (status: Int32, output: String) {
        switch await openPairing(port: port, timeout: timeout) {
        case .noReply:
            return (1, "ptzd ne répond pas : le service est-il lancé ?")
        case let .refused(message):
            return (1, "ptzd refuse l'appairage : \(message)")
        case let .opened(invitation):
            guard !invitation.hosts.isEmpty else {
                return (1, "Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet, puis relancez ptzd pair.")
            }
            let url = PairingLink(invitation).url.absoluteString
            guard let modules = QRCodeText.modules(for: url) else {
                return (1, "QR code impossible à produire pour \(url)")
            }
            let time = DateFormatter()
            time.dateFormat = "HH:mm:ss"
            return (0, """
            \(QRCodeText.render(modules))

            Dans PTZBot sur l'iPhone, touchez « Scanner le QR code » et visez ce code.
            \(url)
            Valable jusqu'à \(time.string(from: invitation.expiresAt)), une seule fois. Ne l'affiche que le temps du scan.
            """)
        }
    }

    /// `openPairing` par 127.0.0.1, puis attente de `pairingOpened` ou d'une erreur, `timeout` secondes au plus.
    static func openPairing(port: Int, timeout: TimeInterval) async -> Outcome {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await exchange(task) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .noReply
            }
            let first = await group.next() ?? .noReply
            // Débloque l'attente de réception restée en cours.
            task.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return first
        }
    }

    private static func exchange(_ task: URLSessionWebSocketTask) async -> Outcome {
        do {
            try await task.send(.string(try NacelleCodec.encode(.openPairing)))
            while true {
                guard case let .string(text) = try await task.receive() else { continue }
                switch try NacelleCodec.decodeServer(text) {
                case let .pairingOpened(invitation):
                    return .opened(invitation)
                case let .error(_, message):
                    return .refused(message)
                default:
                    continue
                }
            }
        } catch {
            return .noReply
        }
    }
}
