import SwiftUI

/// L'écran unique : la vidéo en plein écran, les commandes par-dessus (spec § 7.2 et § 7.3).
struct ControlScreen: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    private var privacyOn: Bool {
        model.ptz.state?.privacy ?? false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoView(session: model.video)
                .ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    settingsButton
                    Spacer(minLength: 12)
                    if let text = model.bannerText {
                        BannerView(text: text)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        soundButton
                        aiButton
                        privacyButton
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    JoystickView(
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setJoystick($0) },
                        onRelease: { model.ptz.setJoystick(.zero) }
                    )
                    Spacer()
                    ZoomSlider(
                        value: model.ptz.state?.zoom,
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setZoom($0) }
                    )
                }
            }
            .padding(20)
        }
        .sensoryFeedback(.success, trigger: model.ptz.state?.privacy) { old, new in
            // Seulement entre deux états connus : pas à la coupure ni à la reconnexion.
            old != nil && new != nil && old != new
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $model.settings,
                isPaired: model.ptz.isPaired,
                onPair: { model.pair(with: $0) },
                onForget: { model.forgetPairing() }
            )
        }
        .fullScreenCover(isPresented: Binding(get: { model.needsPairing }, set: { _ in })) {
            PairingScreen(model: model)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Réglages")
    }

    private var soundButton: some View {
        Button {
            model.soundWanted.toggle()
        } label: {
            Image(systemName: model.soundPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.soundToggleEnabled)
        .opacity(model.soundToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(soundLabel)
    }

    private var soundLabel: String {
        if privacyOn {
            return "Son coupé en vie privée"
        }
        if !model.soundToggleEnabled {
            return "Son coupé"
        }
        return model.soundWanted ? "Couper le son" : "Activer le son"
    }

    private var aiButton: some View {
        Button {
            model.toggleAITracking()
        } label: {
            Image(systemName: model.aiTrackingOn ? "person.crop.square.fill" : "person.crop.square")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.aiToggleEnabled)
        .opacity(model.aiToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(model.aiTrackingOn ? "Couper le suivi IA" : "Allumer le suivi IA")
    }

    private var privacyButton: some View {
        Button {
            model.ptz.setPrivacy(!privacyOn)
        } label: {
            Image(systemName: privacyOn ? "eye.slash.fill" : "eye.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(privacyOn ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.privacyToggleEnabled)
        .opacity(model.privacyToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(privacyOn ? "Quitter la vie privée" : "Vie privée")
    }
}

/// Le bandeau d'état, en haut de l'écran.
private struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
