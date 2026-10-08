import AppKit
import PTZBotKit
import Sparkle

/// Les mises à jour par Sparkle 2 (spec distribution § 8) : flux, clé et rythme dans Info.plist (project.yml).
/// Créé seulement pour une app publiée (`UpdaterPolicy`) : jamais sous les tests ni dans une compilation de travail.
///
/// Installer une mise à jour quitte l'app par le même chemin que « Quitter » : le programme d'installation de
/// Sparkle envoie à l'app l'événement Apple « quitter » (`NSRunningApplication.terminate`, dans
/// `InstallerProgressAppController.sendTerminationSignal`), donc `applicationShouldTerminate`, qui arrête ptzd
/// d'abord ; Sparkle attend la fin de l'app avant de la remplacer, puis la relance.
@MainActor
final class SparkleUpdater: Updater {
    private let controller: SPUStandardUpdaterController
    private let userDriverDelegate = MenuBarUserDriverDelegate()
    private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: userDriverDelegate)
    }

    func checkForUpdates() {
        // Sans icône dans le Dock, la fenêtre de Sparkle doit être amenée au premier plan.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }

    /// KVO sur `canCheckForUpdates`, comme l'exemple SwiftUI de Sparkle : le bouton du panneau suit l'état en direct.
    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in handler(canCheck) }
        }
    }
}

/// Une app de la barre des menus, sans icône dans le Dock : les rappels « discrets » de Sparkle. Quand
/// « Installer automatiquement » est décoché, une mise à jour trouvée au fil des recherches est montrée par la
/// fenêtre de Sparkle, amenée au premier plan, au lieu de rester derrière les autres apps.
final class MenuBarUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    // Sparkle appelle son délégué sur le fil principal.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated {
            NSApp.activate()
        }
    }
}
