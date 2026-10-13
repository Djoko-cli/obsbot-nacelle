import Foundation
import Observation

/// L'onglet « Caméra » des Réglages (spec B3 § 6.2) : les réglages en cours d'édition, les appareils et ffmpeg
/// détectés, l'import d'une configuration existante et « Appliquer ».
@MainActor
@Observable
public final class Go2RTCSettingsModel {
    /// Les réglages en cours d'édition.
    public var draft: Go2RTCSettings
    /// Les derniers réglages appliqués.
    public private(set) var applied: Go2RTCSettings
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var microphones: [CaptureDeviceInfo] = []
    /// ffmpeg trouvé ; nil : introuvable, ou pas encore cherché (`ffmpegChecked`).
    public private(set) var detectedFFmpeg: URL?
    public private(set) var ffmpegChecked = false
    /// Ce qu'un import reprendrait, montré avant d'être repris.
    public private(set) var importPreview: Go2RTCImport?
    /// Le résultat du dernier « Appliquer » ou import, en clair, quand il y a quelque chose à dire.
    public private(set) var message: String?
    public private(set) var isApplying = false

    @ObservationIgnored private let supervisor: Go2RTCSupervisor
    @ObservationIgnored private let preparer: any Go2RTCPreparing
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let locator: FFmpegLocator
    @ObservationIgnored private let catalog: any CaptureDeviceCatalog

    /// Part des réglages du superviseur (préférences et mot de passe du yaml, `Go2RTCSettings.restore`).
    public init(
        supervisor: Go2RTCSupervisor,
        preparer: any Go2RTCPreparing,
        store: any SettingsStore,
        locator: FFmpegLocator,
        catalog: any CaptureDeviceCatalog
    ) {
        self.supervisor = supervisor
        self.preparer = preparer
        self.store = store
        self.locator = locator
        self.catalog = catalog
        draft = supervisor.configuration
        applied = supervisor.configuration
    }

    public static func system(supervisor: Go2RTCSupervisor, preparer: any Go2RTCPreparing) -> Go2RTCSettingsModel {
        Go2RTCSettingsModel(supervisor: supervisor, preparer: preparer, store: UserDefaultsSettingsStore(defaults: .standard),
                            locator: .system(), catalog: AVFoundationDeviceCatalog())
    }

    public var hasChanges: Bool {
        draft != applied
    }

    /// « Appliquer » relancera go2rtc : l'avertissement est montré avant.
    public var applyRestartsGo2RTC: Bool {
        hasChanges && supervisor.isEnabled
    }

    /// Les caméras proposées : celles du Mac, plus le nom réglé s'il est débranché.
    public var cameraChoices: [String] {
        Self.choices(cameras, keeping: draft.cameraName)
    }

    public var microphoneChoices: [String] {
        Self.choices(microphones, keeping: draft.microphoneName)
    }

    static func choices(_ devices: [CaptureDeviceInfo], keeping name: String?) -> [String] {
        let names = devices.map(\.name)
        guard let name, !name.isEmpty, !names.contains(name) else { return names }
        return names + [name]
    }

    /// Les appareils et ffmpeg, relus hors du fil de l'interface (onglet ouvert, « Rechercher à nouveau »).
    public func refreshDetection() async {
        let catalog = catalog
        let locator = locator
        let configured = draft.ffmpegPath
        let found = await Task.detached {
            (catalog.cameras(), catalog.microphones(), locator.locate(configured: configured))
        }.value
        cameras = found.0
        microphones = found.1
        detectedFFmpeg = found.2
        ffmpegChecked = true
    }

    /// « Appliquer » : le yaml régénéré, les réglages retenus (sans le mot de passe), puis go2rtc relancé s'il est
    /// allumé. Un réglage qui ne change rien ne relance rien ; un yaml qui ne s'écrit pas ne retient rien.
    public func apply() async {
        guard hasChanges, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        message = nil
        let settings = draft
        let preparer = preparer
        if let block = await Task.detached(operation: { await preparer.writeConfig(settings) }).value {
            message = Labels.go2rtcBlock(block)
            return
        }
        settings.save(to: store)
        applied = settings
        supervisor.configuration = settings
        if supervisor.isEnabled {
            supervisor.restart()
        }
    }

    /// Revient aux réglages appliqués.
    public func revert() {
        draft = applied
        message = nil
    }

    /// « Importer une configuration existante… » : le fichier est lu et ce qui serait repris montré. Il n'est pas
    /// modifié.
    public func previewImport(_ url: URL) {
        do {
            importPreview = try Go2RTCConfigReader.read(contentsOf: url)
            message = nil
        } catch {
            importPreview = nil
            message = error.localizedDescription
        }
    }

    /// « Reprendre » : l'import passe dans les réglages en cours ; « Appliquer » l'écrira.
    public func acceptImport() {
        guard let importPreview else { return }
        draft = importPreview.applied(to: draft)
        self.importPreview = nil
    }

    public func cancelImport() {
        importPreview = nil
    }
}

extension Labels {
    /// Ce qu'un import reprendrait, une ligne par réglage ; le mot de passe n'est jamais montré.
    public static func go2rtcImportSummary(_ imported: Go2RTCImport) -> [String] {
        var lines: [String] = []
        if let username = imported.username { lines.append(Localization.text("Identifiant : \(username)")) }
        if imported.password != nil { lines.append(Localization.text("Mot de passe : repris")) }
        if let port = imported.rtspPort { lines.append(Localization.text("Port RTSP : \(String(port))")) }
        if let port = imported.webrtcPort { lines.append(Localization.text("Port WebRTC : \(String(port))")) }
        if let camera = imported.cameraName { lines.append(Localization.text("Caméra : \(camera)")) }
        if let microphone = imported.microphoneName { lines.append(Localization.text("Micro : \(microphone)")) }
        if let ffmpeg = imported.ffmpegPath { lines.append(Localization.text("ffmpeg : \(ffmpeg)")) }
        return lines
    }

    /// L'avertissement d'« Appliquer » quand go2rtc tourne (spec B3 § 6.2).
    public static var go2rtcApplyWarning: String { Localization.text("Le flux HomeKit sera coupé quelques secondes.") }
}
