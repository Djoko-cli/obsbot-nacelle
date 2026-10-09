import PTZBotKit
import SwiftUI

/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app, spec distribution) : une icône dans la barre des menus,
/// un panneau, quatre fenêtres, ptzd lancé comme processus enfant, Talkback (l'agent talkd, indépendant de l'app) et les
/// mises à jour par Sparkle.
@main
struct PTZBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.panel, talkback: delegate.talkback, settings: delegate.settings, app: delegate.controller, network: delegate.network)
                .followsLanguage(delegate.language)
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .opacity(delegate.panel.service == .active ? 1 : 0.4)
                .onAppear { delegate.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Appairer un iPhone", id: WindowID.pairing) {
            PairingView(model: delegate.panel)
                .followsLanguage(delegate.language, title: "Appairer un iPhone")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Appareils appairés", id: WindowID.devices) {
            DevicesView(model: delegate.panel)
                .followsLanguage(delegate.language, title: "Appareils appairés")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("SDK OBSBOT", id: WindowID.sdk) {
            SDKView(model: delegate.sdkWindow)
                .followsLanguage(delegate.language, title: "SDK OBSBOT")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Réglages", id: WindowID.settings) {
            SettingsView(model: delegate.settings, language: delegate.language)
                .followsLanguage(delegate.language, title: "Réglages")
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// La langue choisie dans les Réglages, appliquée avant tout autre texte.
    let language = AppLanguageModel.system()
    let scheduler = MainScheduler()
    let panel: PanelModel
    let talkback: TalkbackModel
    let settings: SettingsModel
    let controller: AppController
    let sdkWindow: SDKWindowModel
    let network: LocalNetworkState
    private var started = false

    override init() {
        let paths = AppPaths.system()
        panel = PanelModel(config: .load(from: paths.config), transport: URLSessionAdminTransport(), scheduler: scheduler)
        talkback = TalkbackModel(
            service: TalkbackAgent(),
            state: FileTalkbackStateSource(url: paths.talkbackState),
            process: SystemProcessProbe(),
            scheduler: scheduler
        )
        let installer = SDKInstaller.system(paths: paths)
        controller = AppController(
            supervisor: .system(paths: paths.service, scheduler: scheduler),
            legacyAgent: .system(supportDirectory: paths.support),
            configURL: paths.config,
            interfaces: SystemInterfaceAddresses(),
            sdkInstaller: installer,
            scheduler: scheduler,
            confirmMigration: { MigrationAlert.ask() }
        )
        sdkWindow = SDKWindowModel(installer: installer)
        network = LocalNetworkState(scheduler: scheduler)
        // Sparkle ne démarre que dans une app publiée : jamais sous les tests ni dans une compilation de travail
        // (numéro de compilation 1).
        let info = Bundle.main.infoDictionary
        let bundleVersion = info?["CFBundleVersion"] as? String
        let usesSparkle = UpdaterPolicy.usesSparkle(bundleVersion: bundleVersion, environment: ProcessInfo.processInfo.environment)
        settings = SettingsModel(
            updater: usesSparkle ? SparkleUpdater() : NoUpdater(),
            updatesEnabled: usesSparkle,
            loginItem: LoginItemModel(service: MainAppLoginItem()),
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            bundleVersion: bundleVersion
        )
        super.init()
        controller.onConfigReady = { [panel] in
            panel.reloadConfig(.load(from: paths.config))
        }
        sdkWindow.onInstalled = { [controller] in
            Task { await controller.refreshSDK() }
        }
    }

    /// À la première apparition de l'icône : connexion à ptzd, ancienne installation, service, SDK, réseau local.
    func start() {
        guard !started else { return }
        started = true
        panel.start()
        talkback.refresh()
        network.check()
        Task { await controller.launch() }
    }

    /// Attend l'arrêt de ptzd (6 s au plus), puis répond. C'est aussi le chemin d'une mise à jour : Sparkle demande
    /// à l'app de quitter (événement Apple « quitter ») avant de la remplacer (voir `SparkleUpdater`).
    ///
    /// Ne jamais appeler `NSApp.terminate` depuis un bloc de la file principale (`DispatchQueue.main.async`,
    /// `asyncAfter`, `Task` sur le MainActor) : `.terminateLater` fait tourner la boucle d'exécution à l'intérieur
    /// de ce bloc, et la file principale, qui n'est pas réentrante, ne livre plus rien. Or la fin de ptzd
    /// (`FoundationProcessLauncher`) et le délai de sécurité (`MainScheduler`) passent par elle : l'app
    /// attendrait sans fin. « Quitter » passe donc par la boucle d'exécution (`perform(_:with:afterDelay:inModes:)`),
    /// et la réponse aussi.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.quit {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}

/// L'autorisation « Réseau local » de PTZBot, vérifiée au lancement et à chaque ouverture du panneau.
@MainActor
@Observable
final class LocalNetworkState {
    private(set) var denied = false
    @ObservationIgnored private let probe = LocalNetworkProbe()
    @ObservationIgnored private let scheduler: any Scheduler

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func check() {
        probe.check(scheduler: scheduler) { [weak self] denied in
            self?.denied = denied
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// L'alerte de migration (spec ptzd dans l'app § 5.6).
enum MigrationAlert {
    @MainActor
    static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = Labels.migrationMessage
        alert.addButton(withTitle: Labels.migrationReplace)
        alert.addButton(withTitle: Labels.migrationLater)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let devices = "devices"
    static let sdk = "sdk"
    static let settings = "settings"
}

extension OpenWindowAction {
    /// Ouvre la fenêtre au premier plan : l'app n'a pas d'icône dans le Dock pour l'y amener.
    @MainActor
    func front(_ id: String) {
        self(id: id)
        NSApp.activate()
    }
}
