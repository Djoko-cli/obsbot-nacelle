import Foundation
import Testing
@testable import Nacelle

@MainActor
@Suite("Modèle de l'app")
struct AppModelTests {
    let transport = FakeTransport()
    let scheduler = FakeScheduler()
    let defaults = UserDefaults(suiteName: "nacelle-appmodel-\(UUID().uuidString)")!
    let complete = ConnectionSettings(host: "mac.exemple.ts.net")

    private func makeModel() -> AppModel {
        AppModel(
            store: SettingsStore(defaults: defaults),
            ptz: PTZClient(transport: transport, scheduler: scheduler),
            video: VideoSession(scheduler: scheduler)
        )
    }

    @Test("Premier lancement : les réglages enregistrés au premier plan connectent tout de suite")
    func firstLaunch() {
        let model = makeModel()
        model.activate()
        #expect(transport.openedURLs.isEmpty)
        #expect(model.bannerText == nil)
        model.settings = complete
        #expect(transport.openedURLs.count == 1)
        #expect(model.isActive)
        model.deactivate()
    }

    @Test("Déjà actif : un nouveau passage au premier plan ne relance rien")
    func activateIsIdempotent() {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        model.activate()
        #expect(transport.openedURLs.count == 1)
        model.deactivate()
    }

    @Test("En arrière-plan, de nouveaux réglages sont enregistrés sans connecter")
    func settingsInBackground() {
        let model = makeModel()
        model.activate()
        model.deactivate()
        model.settings = complete
        #expect(transport.openedURLs.isEmpty)
        #expect(SettingsStore(defaults: defaults).load() == complete)
    }

    @Test("Réglages modifiés une fois connecté : reconnexion à la nouvelle adresse")
    func settingsChangeReconnects() {
        SettingsStore(defaults: defaults).save(complete)
        let model = makeModel()
        model.activate()
        model.settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
        #expect(transport.openedURLs.map(\.port) == [1985, 1999])
        model.deactivate()
    }
}
