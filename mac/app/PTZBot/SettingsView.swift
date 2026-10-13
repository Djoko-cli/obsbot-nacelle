import PTZBotKit
import SwiftUI

/// Les onglets de la fenêtre « Réglages ».
enum SettingsTab: CaseIterable, Hashable {
    case general
    case camera
    case sdk

    /// Le libellé du segment, dans la langue de l'app.
    var title: String {
        switch self {
        case .general: AppText.text("Général")
        case .camera: AppText.text("Caméra")
        case .sdk: AppText.text("SDK OBSBOT")
        }
    }
}

/// L'onglet choisi des Réglages, partagé entre la fenêtre et le panneau : le lien « Installer le SDK… » du panneau
/// ouvre les Réglages directement sur l'onglet « SDK OBSBOT ». Premier onglet : « Général ».
@MainActor
@Observable
final class SettingsTabModel {
    var tab: SettingsTab = .general

    /// Tout changement d'onglet passe par ici, pour que la hauteur de la fenêtre glisse au lieu de sauter.
    func select(_ tab: SettingsTab) {
        withAnimation(.easeInOut(duration: 0.25)) {
            self.tab = tab
        }
    }
}

/// La fenêtre « Réglages » (spec distribution § 8, spec B3 § 6.2) : trois onglets, « Général », « Caméra » et
/// « SDK OBSBOT ».
///
/// Les onglets sont un sélecteur segmenté dans la barre de titre et un `switch`, non un `TabView` : avec
/// `.windowResizability(.contentSize)`, un `TabView` agrandit la fenêtre quand un onglet grandit (l'encart d'import de
/// l'onglet « Caméra ») mais ne la rétrécit jamais (banc du 13/10). Ici la fenêtre prend exactement la hauteur de
/// l'onglet affiché.
struct SettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel
    let camera: Go2RTCSettingsModel
    let app: AppController
    let sdk: SDKWindowModel
    let tabs: SettingsTabModel

    var body: some View {
        Group {
            switch tabs.tab {
            case .general:
                GeneralSettingsView(model: model, language: language)
            case .camera:
                CameraSettingsView(model: camera)
            case .sdk:
                SDKView(model: sdk, app: app)
            }
        }
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(AppText.text("Réglages"), selection: Binding(get: { tabs.tab }, set: { tabs.select($0) })) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// L'onglet « Général » : les mises à jour, l'ouverture à la connexion, la langue et la version.
private struct GeneralSettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel

    private var loginItem: LoginItemModel {
        model.loginItem
    }

    var body: some View {
        Form {
            Section {
                Toggle(Labels.automaticallyChecks, isOn: Binding(get: { model.automaticallyChecks }, set: { model.setAutomaticallyChecks($0) }))
                    .disabled(!model.updatesEnabled)
                Toggle(Labels.automaticallyInstalls, isOn: Binding(get: { model.automaticallyDownloads }, set: { model.setAutomaticallyDownloads($0) }))
                    .disabled(!model.canChangeDownloads)
                if !model.updatesEnabled {
                    Text(Labels.updatesDisabled).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(Labels.openAtLogin, isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    Button(Labels.loginApproval) {
                        loginItem.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                // « Français » et « English » sont toujours écrits dans leur langue.
                Picker(Labels.languageTitle, selection: Binding(get: { language.selection }, set: { language.select($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Text(Labels.languageChoice(choice)).tag(choice)
                    }
                }
                Text(Labels.languageUpdateNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(model.versionLine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginItem.refresh()
        }
    }
}
