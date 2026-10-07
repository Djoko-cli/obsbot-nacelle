import Foundation
import ServiceManagement
import Testing
@testable import PTZBotKit

@Suite("Port de ptzd")
struct PTZDConfigTests {
    private func load(_ json: String?) throws -> PTZDConfig {
        let url = FileManager.default.temporaryDirectory.appending(path: "ptzbot-\(UUID().uuidString).json")
        if let json {
            try Data(json.utf8).write(to: url)
        }
        return PTZDConfig.load(from: url)
    }

    @Test("Port de config.json ; absent du fichier : 1985")
    func port() throws {
        #expect(try load(#"{"listenAddress":"127.0.0.1","port":19870}"#) == PTZDConfig(port: 19870, isFallback: false))
        #expect(try load(#"{"listenAddress":"127.0.0.1"}"#) == PTZDConfig(port: 1985, isFallback: false))
        #expect(PTZDConfig(port: 19870, isFallback: false).url.absoluteString == "ws://127.0.0.1:19870")
    }

    @Test("Fichier absent, illisible ou port invalide : 1985, signalé")
    func fallback() throws {
        #expect(try load(nil) == PTZDConfig(port: 1985, isFallback: true))
        #expect(try load("pas du json") == PTZDConfig(port: 1985, isFallback: true))
        #expect(try load(#"{"port":70000}"#) == PTZDConfig(port: 1985, isFallback: true))
    }
}

@MainActor
@Suite("Ouverture à la connexion")
struct LoginItemModelTests {
    struct Failure: LocalizedError {
        var errorDescription: String? { "refusé" }
    }

    @Test("Case cochée : inscrite ; décochée : désinscrite")
    func toggle() {
        let service = FakeLoginItem()
        let model = LoginItemModel(service: service)
        #expect(!model.isEnabled)
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(!model.needsApproval)
        model.setEnabled(false)
        #expect(!model.isEnabled)
    }

    @Test("Accord demandé par macOS : signalé, Réglages ouvrables")
    func approval() {
        let service = FakeLoginItem()
        service.statusAfterRegister = .requiresApproval
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        #expect(model.needsApproval)
        model.openSystemSettings()
        #expect(service.settingsOpened == 1)
    }

    @Test("Échec : message, case inchangée")
    func failure() {
        let service = FakeLoginItem()
        service.failure = Failure()
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        #expect(!model.isEnabled)
        #expect(model.lastError == "Ouverture à la connexion impossible : refusé")
    }
}
