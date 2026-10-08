import Foundation
import NacelleProtocol

/// Les textes du service, du SDK et de la migration (spec ptzd dans l'app § 5.6, § 6.1 et § 6.2), au vouvoiement.
extension Labels {
    /// L'état sous le titre : la supervision de ptzd, puis la connexion de confiance pour « Actif ».
    public static func service(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> String {
        if legacy {
            return "Ancienne installation"
        }
        switch state {
        case .stopped, .failed:
            return "Arrêté"
        case .starting:
            return "Démarrage…"
        case let .restarting(count):
            return "Relancé après un arrêt inattendu (\(count))"
        case .running:
            return service(connection)
        }
    }

    /// Service éteint ou en échec : tout est grisé sauf l'interrupteur, le SDK, « Ouvrir à la connexion »
    /// et « Quitter ». Ancienne installation : seule la connexion décide.
    public static func controlsEnabled(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> Bool {
        guard connection == .active else { return false }
        if legacy {
            return true
        }
        switch state {
        case .running: return true
        case .stopped, .starting, .restarting, .failed: return false
        }
    }

    /// Le journal est proposé quand ptzd ne répond pas ou s'arrête sans cesse.
    public static func showsLog(_ state: ServiceSupervisor.State, connection: PanelModel.Service) -> Bool {
        if case .failed = state {
            return true
        }
        return state == .running && connection == .unreachable
    }

    /// L'état court, à droite de la ligne « SDK OBSBOT » ; l'explication va dessous (`sdkDetail`).
    public static func sdk(_ status: SDKStatus?) -> String {
        switch status {
        case .ready: "Prêt"
        case .absent: "Absent"
        case .quarantined: "En quarantaine"
        case .incompatible: "Incompatible"
        case .unloadable: "Ne se charge pas"
        case .sourceMissing: "obsbot-ai introuvable"
        case .toolsRequired: "Outils requis"
        case .incomplete: "À compléter"
        case .recompiling: "Recompilation…"
        case .compileFailed: "Compilation impossible"
        case nil: "Vérification…"
        }
    }

    /// La petite ligne sous « SDK OBSBOT », sur toute la largeur : ce que l'état veut dire et quoi faire ; nil si
    /// l'état se suffit. Quand les outils manquent et que le bouton les installe, elle le dit aussi.
    public static func sdkDetail(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        var parts: [String] = []
        switch status {
        case .incomplete:
            parts.append(sdkIncompleteDetail)
        case let .toolsRequired(fallback):
            parts.append(sdkToolsDetail)
            if fallback {
                parts.append(sdkFallback)
            }
        case let .compileFailed(fallback):
            if fallback {
                parts.append(sdkFallback)
            }
            parts.append(compileLogHint)
        case .quarantined:
            parts.append(sdkQuarantinedDetail)
        case .incompatible:
            parts.append(sdkIncompatibleDetail)
        case .unloadable:
            parts.append(sdkUnloadableDetail)
        case .sourceMissing:
            parts.append(sdkSourceMissingDetail)
        case .ready, .absent, .recompiling, nil:
            break
        }
        if case .toolsRequired = status {
            // Déjà dit par sdkToolsDetail.
        } else if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            parts.append(sdkToolsFirst)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static let sdkFallback = "L'ancien obsbot-ai reste en service."
    public static let compileLogHint = "Le détail est dans le journal obsbot-ai-compilation.log."
    public static let sdkIncompleteDetail = "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent."
    public static let sdkToolsDetail = "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai."
    public static let sdkQuarantinedDetail = "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie."
    public static let sdkIncompatibleDetail = "Ce SDK n'a pas de version pour Apple Silicon."
    public static let sdkUnloadableDetail = "obsbot-ai ne charge pas ce SDK : réinstallez-le."
    public static let sdkSourceMissingDetail = "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot."
    public static let sdkToolsFirst = "Installez d'abord les outils de développement d'Apple."

    /// Le bouton de la ligne SDK : « Changer… » quand il est prêt (la fenêtre reste joignable), « Installer les
    /// outils de développement… » quand ils manquent (obsbot-ai ne pourrait pas être compilé), « Installer le SDK… »
    /// sinon ; aucun pendant la vérification ou la recompilation.
    public static func sdkAction(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            return installTools
        }
        switch status {
        case nil, .recompiling, .sourceMissing: return nil
        case .ready: return "Changer…"
        case .toolsRequired: return installTools
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed: return "Installer le SDK…"
        }
    }

    /// Le bouton de la ligne SDK lance `xcode-select --install` plutôt que d'ouvrir la fenêtre « SDK OBSBOT » :
    /// les outils manquent et le SDK est à installer (ou obsbot-ai à compiler). Sur le clic de l'utilisateur seulement.
    public static func sdkActionInstallsTools(_ status: SDKStatus?, toolsAvailable: Bool = true) -> Bool {
        switch status {
        case .toolsRequired:
            return true
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed:
            return !toolsAvailable
        case nil, .ready, .recompiling, .sourceMissing:
            return false
        }
    }

    /// La fenêtre « SDK OBSBOT » quand les outils manquent : elle propose de les installer avant de choisir le SDK.
    public static let sdkToolsExplanation = "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau."
    public static let checkToolsAgain = "Vérifier à nouveau"

    public static let installTools = "Installer les outils de développement…"

    public static let replaceLegacy = "Remplacer l'ancienne installation…"

    // MARK: - Sections du panneau

    public static let serviceSection = "Service"
    public static let noIPhone = "Aucun iPhone connecté"

    /// « Caméra · branchée » ou « Caméra · débranchée » (débranchée aussi hors connexion).
    public static func cameraSection(_ presence: CameraPresence?) -> String {
        "Caméra · \(presence == .connected ? "branchée" : "débranchée")"
    }

    /// « iPhone connectés · n ».
    public static func iPhoneSection(count: Int) -> String {
        "iPhone connectés · \(count)"
    }

    /// La petite ligne sous « Suivi IA » : le SDK manque, ou l'état ne se lit pas.
    public static func aiNote(_ tracking: AITracking?, needsSDK: Bool) -> String? {
        if needsSDK {
            return sdkRequired
        }
        return tracking == .unknown ? "État inconnu" : nil
    }

    /// Le suivi IA a besoin du SDK de l'app et d'un obsbot-ai qui le charge ; l'ancienne installation a le sien
    /// dans `lib/`.
    public static func aiNeedsSDK(_ status: SDKStatus?, legacy: Bool) -> Bool {
        !legacy && status?.aiUsable != true
    }

    public static let sdkRequired = "SDK OBSBOT requis"
    public static let tailscaleMissing = "Tailscale introuvable : accès depuis l'extérieur indisponible"
    public static let localNetworkDenied = "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale"

    public static let migrationMessage = "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés."
    public static let migrationReplace = "Remplacer"
    public static let migrationLater = "Plus tard"

    public static let sdkExplanation = "Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé."
    public static let sdkConfirmation = "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com."

    /// Une ligne des vérifications de la fenêtre « SDK OBSBOT ».
    public struct SDKCheck: Equatable, Sendable {
        public var title: String
        public var value: String
    }

    /// La ligne « Signature » : le signataire (et l'équipe) seulement si la signature est intacte et d'un
    /// certificat reconnu par Apple. Ces contrôles ne remplacent pas Gatekeeper.
    static func signatureText(_ candidate: SDKCandidate) -> String {
        switch candidate.signatureValid {
        case false:
            return "Signature invalide"
        case true:
            guard candidate.appleAnchored == true else { return "Signé, certificat non reconnu par Apple" }
            guard let signer = candidate.signer else { return "Signé" }
            return candidate.team.map { "\(signer) (équipe \($0))" } ?? signer
        case nil:
            return "non signé"
        }
    }

    /// Architecture, signature, provenance et quarantaine (§ 6.2).
    public static func sdkChecks(_ candidate: SDKCandidate) -> [SDKCheck] {
        let architecture = candidate.isArm64
            ? "Apple Silicon : ✓"
            : "Apple Silicon : ✗ (\(candidate.architectures.joined(separator: ", ")))"
        var origin = [String]()
        if let url = candidate.origin?.url {
            origin.append(url)
        }
        if let date = candidate.origin?.date {
            origin.append("le \(date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "fr_FR"))))")
        }
        var provenance = origin.isEmpty ? "inconnue" : origin.joined(separator: " · ")
        if !origin.isEmpty, candidate.origin?.fromInsideArchive == true {
            provenance += " (indiquée dans l'archive)"
        }
        let signature = signatureText(candidate)
        var checks = [
            SDKCheck(title: "Architecture", value: architecture),
            SDKCheck(title: "Signature", value: signature),
            SDKCheck(title: "Provenance", value: provenance),
            SDKCheck(title: "Quarantaine", value: candidate.quarantined ? "oui" : "non"),
        ]
        if !candidate.otherCopies.isEmpty {
            checks.append(SDKCheck(title: "Autres copies ignorées", value: candidate.otherCopies.joined(separator: ", ")))
        }
        return checks
    }
}
