import AppKit
import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// L'onglet « Caméra » des Réglages (spec B3 § 6.2) : diffusion, appareils, ffmpeg, réglages avancés, journal,
/// interface web, et « Appliquer ».
struct CameraSettingsView: View {
    @Bindable var model: Go2RTCSettingsModel
    @State private var confirmingApply = false

    var body: some View {
        Form {
            streamSection
            devicesSection
            ffmpegSection
            advancedSection
            if let preview = model.importPreview {
                importSection(preview)
            }
            Section {
                HStack {
                    Button(AppText.text("Ouvrir le journal")) {
                        LogOpener.openGo2RTCLog()
                    }
                    Button(AppText.text("Ouvrir l'interface web")) {
                        if let url = URL(string: "http://127.0.0.1:\(Go2RTCSettings.apiPort)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Button(AppText.text("Appliquer")) {
                        if model.applyRestartsGo2RTC {
                            confirmingApply = true
                        } else {
                            Task { await model.apply() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || model.isApplying)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await model.refreshDetection()
        }
        .alert(Labels.go2rtcApplyWarning, isPresented: $confirmingApply) {
            Button(AppText.text("Appliquer")) {
                Task { await model.apply() }
            }
            Button(AppText.text("Annuler"), role: .cancel) {}
        }
    }

    private var streamSection: some View {
        Section(AppText.text("Diffusion")) {
            TextField(AppText.text("Identifiant"), text: $model.draft.username)
            SecureField(AppText.text("Mot de passe"), text: $model.draft.password)
            Picker(AppText.text("Résolution"), selection: $model.draft.resolution) {
                ForEach(Go2RTCSettings.resolutions, id: \.self) { resolution in
                    Text(verbatim: "\(resolution.width) × \(resolution.height)").tag(resolution)
                }
            }
            Picker(AppText.text("Cadence"), selection: $model.draft.framerate) {
                ForEach(Go2RTCSettings.framerates, id: \.self) { rate in
                    Text(AppText.text("\(String(rate)) i/s")).tag(rate)
                }
            }
            Picker(AppText.text("Débit"), selection: $model.draft.bitrate) {
                ForEach(Go2RTCSettings.bitrates, id: \.self) { rate in
                    Text(AppText.text("\(String(rate)) Mb/s")).tag(rate)
                }
            }
        }
    }

    private var devicesSection: some View {
        Section(AppText.text("Appareils")) {
            devicePicker(AppText.text("Caméra"), selection: $model.draft.cameraName, choices: model.cameraChoices)
            devicePicker(AppText.text("Micro"), selection: $model.draft.microphoneName, choices: model.microphoneChoices)
            Button(AppText.text("Rechercher à nouveau")) {
                Task { await model.refreshDetection() }
            }
        }
    }

    /// nil : « OBSBOT détectée », le choix par défaut (§ 3.6).
    private func devicePicker(_ title: String, selection: Binding<String?>, choices: [String]) -> some View {
        Picker(title, selection: selection) {
            Text(AppText.text("OBSBOT détecté d'office")).tag(String?.none)
            ForEach(choices, id: \.self) { name in
                Text(verbatim: name).tag(String?.some(name))
            }
        }
    }

    private var ffmpegSection: some View {
        Section(AppText.text("ffmpeg")) {
            LabeledContent(AppText.text("Chemin")) {
                Text(verbatim: model.draft.ffmpegPath ?? model.detectedFFmpeg?.path ?? "—")
                    .textSelection(.enabled)
            }
            HStack {
                Button(AppText.text("Choisir…")) {
                    if let url = Self.choose(directory: false, types: [.unixExecutable]) {
                        model.draft.ffmpegPath = url.path
                    }
                }
                if model.draft.ffmpegPath != nil {
                    Button(AppText.text("Chercher d'office")) {
                        model.draft.ffmpegPath = nil
                    }
                }
            }
            if model.ffmpegChecked, model.detectedFFmpeg == nil {
                Text(AppText.text("ffmpeg est introuvable. Installez-le avec Homebrew :")).font(.caption)
                Text(verbatim: FFmpegLocator.installCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var advancedSection: some View {
        Section(AppText.text("Avancé")) {
            TextField(AppText.text("Port RTSP"), value: $model.draft.rtspPort, format: .number.grouping(.never))
            TextField(AppText.text("Port WebRTC"), value: $model.draft.webrtcPort, format: .number.grouping(.never))
            Toggle(AppText.text("Utiliser un fichier de configuration personnalisé"), isOn: $model.draft.customConfigEnabled)
            if model.draft.customConfigEnabled {
                HStack {
                    Text(verbatim: model.draft.customConfigPath ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(AppText.text("Choisir…")) {
                        if let url = Self.choose(directory: false, types: [.yaml]) {
                            model.draft.customConfigPath = url.path
                        }
                    }
                }
            }
            Button(AppText.text("Importer une configuration existante…")) {
                if let url = Self.choose(directory: false, types: [.yaml]) {
                    model.previewImport(url)
                }
            }
        }
    }

    private func importSection(_ preview: Go2RTCImport) -> some View {
        Section(AppText.text("Repris de la configuration")) {
            ForEach(Labels.go2rtcImportSummary(preview), id: \.self) { line in
                Text(line).font(.caption)
            }
            HStack {
                Spacer()
                Button(AppText.text("Annuler")) {
                    model.cancelImport()
                }
                Button(AppText.text("Reprendre")) {
                    model.acceptImport()
                }
            }
        }
    }

    /// Un fichier choisi par l'utilisateur ; les dossiers cachés (`/opt/homebrew/etc`) restent atteignables par ⇧⌘G.
    @MainActor
    private static func choose(directory: Bool, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        panel.showsHiddenFiles = true
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
