import PTZBotKit
import SwiftUI

/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app) : une icône dans la barre des menus, un panneau,
/// trois fenêtres, et ptzd lancé comme processus enfant.
@main
struct PTZBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.panel, loginItem: delegate.loginItem, app: delegate.controller, network: delegate.network)
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .opacity(delegate.panel.service == .active ? 1 : 0.4)
                .onAppear { delegate.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Appairer un iPhone", id: WindowID.pairing) {
            PairingView(model: delegate.panel)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Appareils appairés", id: WindowID.devices) {
            DevicesView(model: delegate.panel)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("SDK OBSBOT", id: WindowID.sdk) {
            SDKView(model: delegate.sdkWindow)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let scheduler = MainScheduler()
    let panel: PanelModel
    let loginItem = LoginItemModel(service: MainAppLoginItem())
    let controller: AppController
    let sdkWindow: SDKWindowModel
    let network: LocalNetworkState
    private var started = false

    override init() {
        let paths = AppPaths.system()
        panel = PanelModel(config: .load(from: paths.config), transport: URLSessionAdminTransport(), scheduler: scheduler)
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
        network.check()
        Task { await controller.launch() }
    }

    /// Attend l'arrêt de ptzd (6 s au plus), puis répond.
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
}

extension OpenWindowAction {
    /// Ouvre la fenêtre au premier plan : l'app n'a pas d'icône dans le Dock pour l'y amener.
    @MainActor
    func front(_ id: String) {
        self(id: id)
        NSApp.activate()
    }
}
