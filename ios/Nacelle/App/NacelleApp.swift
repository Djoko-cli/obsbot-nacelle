import SwiftUI

@main
struct NacelleApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ControlScreen(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Spec § 7.4 : on coupe tout en arrière-plan, on reconnecte au retour.
            switch phase {
            case .active:
                model.activate()
            case .background:
                model.deactivate()
            default:
                break
            }
        }
    }
}
