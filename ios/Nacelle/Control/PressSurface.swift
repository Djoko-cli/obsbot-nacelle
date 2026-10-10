import SwiftUI
import UIKit

/// Une surface qui reçoit le doigt posé et le doigt levé dès l'événement tactile, sans passer par la résolution des
/// gestes de SwiftUI. Au banc du 10/10, un `DragGesture(minimumDistance: 0)` n'arrivait à l'app que 0,3 à 0,7 s après
/// le toucher : trop lent pour un bouton qu'on maintient pour parler.
struct PressSurface: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onChange = onChange
    }

    final class TouchView: UIView {
        var onChange: ((Bool) -> Void)?
        private var pressed = false {
            didSet {
                guard pressed != oldValue else { return }
                onChange?(pressed)
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            pressed = true
        }

        // Le doigt qui glisse ne change rien (le bouton reste tenu jusqu'au relâchement), et ne remonte pas vers la vue
        // parente, comme le posé.
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            pressed = false
        }

        // Le système reprend le toucher (alerte de permission, Centre de contrôle, appel) : relâché.
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            pressed = false
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { pressed = false }
        }
    }
}
