import SwiftUI

/// Joystick : on tire le bouton au doigt ; il revient au centre au relâchement (spec § 7.2).
struct JoystickView: View {
    var isEnabled: Bool
    var onChange: (JoystickVector) -> Void
    var onRelease: () -> Void

    @State private var translation: CGSize = .zero
    @State private var isTouching = false
    @State private var touchCount = 0

    private let diameter: CGFloat = 150
    private let knobDiameter: CGFloat = 64

    private var radius: CGFloat {
        diameter / 2
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: knobDiameter, height: knobDiameter)
                .shadow(radius: 4)
                .offset(JoystickMath.knobOffset(translation: translation, radius: radius))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.4)
        .gesture(drag)
        .sensoryFeedback(.impact(weight: .light), trigger: touchCount)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                release()
            }
        }
        .accessibilityLabel("Joystick de la nacelle")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else { return }
                if !isTouching {
                    isTouching = true
                    touchCount += 1
                }
                translation = value.translation
                onChange(JoystickMath.vector(translation: value.translation, radius: radius))
            }
            .onEnded { _ in
                release()
            }
    }

    private func release() {
        guard isTouching else { return }
        isTouching = false
        withAnimation(.spring(duration: 0.2)) {
            translation = .zero
        }
        onRelease()
    }
}
