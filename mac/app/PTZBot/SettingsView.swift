import PTZBotKit
import SwiftUI

/// La fenêtre « Réglages » (spec distribution § 8) : les mises à jour, l'ouverture à la connexion et la version.
struct SettingsView: View {
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
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginItem.refresh()
        }
    }
}
