import SwiftUI

/// Curseur de zoom vertical : 0 en bas, 100 en haut (spec § 7.2). Envoie chaque nouvelle valeur entière.
struct ZoomSlider: View {
    /// Zoom connu de ptzd, affiché quand le doigt n'est pas posé.
    var value: Int?
    var isEnabled: Bool
    var onChange: (Int) -> Void

    @State private var dragValue: Int?

    private let height: CGFloat = 200
    private let width: CGFloat = 44

    private var shown: Int {
        dragValue ?? value ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1.5))
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(height: max(width, height * CGFloat(shown) / 100))
        }
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.black.opacity(shown > 85 ? 0.7 : 0))
                .padding(.top, 10)
        }
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.4)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard isEnabled else { return }
                    let fraction = 1 - gesture.location.y / height
                    let next = Int((min(max(fraction, 0), 1) * 100).rounded())
                    if next != dragValue {
                        dragValue = next
                        onChange(next)
                    }
                }
                .onEnded { _ in
                    dragValue = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(shown)")
    }
}
