import PTZBotKit
import SwiftUI

/// PTZBot pour Mac (spec app Mac) : une icône dans la barre des menus, un panneau, et deux fenêtres.
@main
struct PTZBotApp: App {
    @State private var panel = PanelModel(config: .load(), transport: URLSessionAdminTransport(), scheduler: MainScheduler())
    @State private var loginItem = LoginItemModel(service: MainAppLoginItem())

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: panel, loginItem: loginItem)
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .opacity(panel.service == .active ? 1 : 0.4)
                .onAppear { panel.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Appairer un iPhone", id: WindowID.pairing) {
            PairingView(model: panel)
        }
        .windowResizability(.contentSize)

        Window("Appareils appairés", id: WindowID.devices) {
            DevicesView(model: panel)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let devices = "devices"
}

extension OpenWindowAction {
    /// Ouvre la fenêtre au premier plan : l'app n'a pas d'icône dans le Dock pour l'y amener.
    @MainActor
    func front(_ id: String) {
        self(id: id)
        NSApp.activate()
    }
}
