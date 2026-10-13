import AppKit
import PTZBotKit
import SwiftUI

/// Les onglets de la fenêtre « Réglages », dans sa barre d'outils ; le dernier ouvert est retenu (`defaultsKey`).
enum SettingsTab: String, CaseIterable {
    case general
    case camera
    case sdk

    /// La clé, dans les préférences de l'app, du dernier onglet ouvert.
    static let defaultsKey = "settings.tab"

    /// Le libellé de l'onglet, dans la langue de l'app, et le titre de la fenêtre quand il est choisi.
    var title: String {
        switch self {
        case .general: AppText.text("Général")
        case .camera: AppText.text("Caméra")
        case .sdk: AppText.text("SDK OBSBOT")
        }
    }

    /// Le symbole SF de l'onglet.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .camera: "video"
        case .sdk: "shippingbox"
        }
    }

    fileprivate var image: NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}

/// La fenêtre « Réglages » (spec distribution § 8, spec B3 § 6.2), faite en AppKit sur le modèle des réglages de macOS
/// (banc du 13/10) :
/// - les onglets sont dans la barre d'outils (« Général », « Caméra », « SDK OBSBOT ») ;
/// - le titre de la fenêtre est celui de l'onglet ;
/// - la hauteur de la fenêtre s'ajuste d'un onglet à l'autre, en glissant.
///
/// Un `NSTabViewController` en style barre d'outils porte les onglets. La hauteur, elle, est animée ici
/// (`SettingsTabViewController.fit`) : le redimensionnement natif, par `preferredContentSize`, saute d'une hauteur à
/// l'autre. La scène `Window` de SwiftUI que cette fenêtre remplace n'avait pas de barre d'outils pour des onglets
/// (le sélecteur était dans le contenu), et sa hauteur ne suivait l'onglet qu'avec un `withAnimation`.
///
/// Créée une fois par l'`AppDelegate` et passée au panneau, qui l'ouvre par « Réglages… » et « Installer le SDK… ».
@MainActor
final class SettingsWindowController {
    private let settings: SettingsModel
    private let language: AppLanguageModel
    private let camera: Go2RTCSettingsModel
    private let app: AppController
    private let sdk: SDKWindowModel
    /// Créée à la première ouverture, puis gardée : elle rouvre sur le même onglet.
    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    init(settings: SettingsModel, language: AppLanguageModel, camera: Go2RTCSettingsModel, app: AppController,
         sdk: SDKWindowModel) {
        self.settings = settings
        self.language = language
        self.camera = camera
        self.app = app
        self.sdk = sdk
    }

    /// Montre la fenêtre au premier plan, sur le dernier onglet ouvert : l'app n'a pas d'icône dans le Dock pour l'y amener.
    func show() {
        makeWindowIfNeeded()
        present()
    }

    /// Montre la fenêtre sur cet onglet.
    func show(tab: SettingsTab) {
        makeWindowIfNeeded()
        tabs?.select(tab)
        present()
    }

    private func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let controller = SettingsTabViewController()
        controller.tabStyle = .toolbar
        // Lu avant d'ajouter les onglets : le choix d'un onglet écrase la valeur retenue.
        let saved = UserDefaults.standard.string(forKey: SettingsTab.defaultsKey).flatMap(SettingsTab.init(rawValue:))
        for tab in SettingsTab.allCases {
            // Contenu changé (installation du SDK, encart d'import, erreur affichée…) : la fenêtre suit, si la page est visible.
            let page = SettingsPage(tab: tab, settings: settings, language: language, camera: camera, app: app, sdk: sdk) {
                [weak controller] _ in
                controller?.contentChanged(of: tab)
            }
            // Sans `sizingOptions` : la page n'annonce pas de taille préférée, sinon le redimensionnement natif, sans
            // animation, prendrait le pas sur `fit`.
            let host = NSHostingController(rootView: page)
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = tab.image
            item.identifier = tab.rawValue
            controller.addTabViewItem(item)
        }
        controller.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: saved ?? .general) ?? 0
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        controller.fit(animated: false)
        window.center()
        self.window = window
        tabs = controller
        observeLanguage()
    }

    /// Un changement de langue s'applique tout de suite à l'app (`AppLanguageModel`) : les libellés des onglets et le titre de
    /// la fenêtre le suivent, sans qu'il faille fermer la fenêtre où se fait le choix.
    private func observeLanguage() {
        withObservationTracking {
            _ = language.language
        } onChange: { [weak self] in
            // Appelé juste avant le changement : la langue est relue au tour suivant.
            Task { @MainActor in
                self?.refreshTitles()
                self?.observeLanguage()
            }
        }
    }

    private func refreshTitles() {
        guard let tabs, let window else { return }
        for item in tabs.tabViewItems {
            guard let tab = (item.identifier as? String).flatMap(SettingsTab.init(rawValue:)) else { continue }
            item.label = tab.title
            item.image = tab.image
            item.viewController?.title = tab.title
        }
        // Le titre de la fenêtre suit l'onglet quand on en choisit un, pas quand le titre de l'onglet change.
        if let current = tabs.currentTab {
            window.title = current.title
        }
    }
}

/// Une page des Réglages, celle d'un onglet : la vue de l'onglet, à la largeur de la fenêtre, et sa hauteur annoncée à la
/// fenêtre (`SettingsWindowController`).
private struct SettingsPage: View {
    let tab: SettingsTab
    let settings: SettingsModel
    let language: AppLanguageModel
    let camera: Go2RTCSettingsModel
    let app: AppController
    let sdk: SDKWindowModel
    /// Appelé à chaque changement de hauteur de la page.
    let onHeight: @MainActor (CGFloat) -> Void

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsView(model: settings, language: language)
            case .camera:
                CameraSettingsView(model: camera)
            case .sdk:
                SDKView(model: sdk, app: app)
            }
        }
        .frame(width: 460)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        // Collée en haut : pendant que la fenêtre change de hauteur, la page ne bouge pas.
        .frame(maxHeight: .infinity, alignment: .top)
        // Sans titre de fenêtre : il vient de l'onglet.
        .followsLanguage(language)
    }
}

/// Les onglets des Réglages : garde le dernier onglet ouvert (`SettingsTab.defaultsKey`), et donne à la fenêtre la taille de
/// la page choisie, en l'animant, bord du haut fixe, comme les réglages de macOS.
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: SettingsTab.defaultsKey)
        }
        fit(animated: view.window?.isVisible == true)
    }

    /// L'onglet choisi, ou nil si le choix n'en est pas un.
    var currentTab: SettingsTab? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return (tabViewItems[selectedTabViewItemIndex].identifier as? String).flatMap(SettingsTab.init(rawValue:))
    }

    func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        selectedTabViewItemIndex = index
    }

    /// La page de cet onglet a changé de hauteur : la fenêtre suit, si c'est la page visible. Le changement est annoncé
    /// pendant la mise en page de SwiftUI, quand `fittingSize` rend (0, 0) ou une taille d'avant : la taille est donc lue
    /// au tour suivant de la boucle, une fois la mise en page finie.
    func contentChanged(of tab: SettingsTab) {
        guard currentTab == tab else { return }
        scheduleFit(attempts: Self.fitAttempts)
    }

    /// Nombre de relectures de la taille de la page, au tour suivant de la boucle, quand elle n'est pas encore connue.
    private static let fitAttempts = 5
    private var fitScheduled = false

    /// Un seul ajustement attend à la fois : les changements annoncés d'ici là le partagent.
    private func scheduleFit(attempts: Int) {
        guard !fitScheduled else { return }
        fitScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            fitScheduled = false
            let known = fit(animated: view.window?.isVisible == true)
            if !known && attempts > 1 { scheduleFit(attempts: attempts - 1) }
        }
    }

    /// Donne à la fenêtre la taille idéale de la page choisie (sa `fittingSize` : la page est collée en haut et peut
    /// s'étirer, mais sa taille idéale est celle de son contenu). Le bord du haut ne bouge pas ; l'animation prend la
    /// durée standard de macOS pour ce changement. Rend faux si la page n'a pas encore de taille (mise en page pas finie).
    @discardableResult
    func fit(animated: Bool) -> Bool {
        guard let window = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
              let page = tabViewItems[selectedTabViewItemIndex].viewController else { return true }
        let wanted = page.view.fittingSize
        let current = window.contentLayoutRect.size
        guard wanted.height > 0, wanted.width > 0 else { return false }
        guard abs(wanted.height - current.height) > 0.5 || abs(wanted.width - current.width) > 0.5 else { return true }
        var frame = window.frame
        frame.origin.y -= wanted.height - current.height
        frame.size.height += wanted.height - current.height
        frame.size.width += wanted.width - current.width
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = window.animationResizeTime(frame)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
        return true
    }
}
