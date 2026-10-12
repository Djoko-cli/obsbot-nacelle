import PTZBotKit
import SwiftUI

/// La fenêtre « Réglages » (spec distribution § 8, spec B3 § 6.2) : deux onglets, « Général » et « Caméra ».
struct SettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel
    let camera: Go2RTCSettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, language: language)
                .tabItem { Label(AppText.text("Général"), systemImage: "gearshape") }
            CameraSettingsView(model: camera)
                .tabItem { Label(AppText.text("Caméra"), systemImage: "video") }
        }
        .frame(width: 460)
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
