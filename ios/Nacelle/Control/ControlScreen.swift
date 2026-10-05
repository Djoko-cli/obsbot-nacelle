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
                    privacyButton
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
        .sensoryFeedback(.success, trigger: privacyOn)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $model.settings)
        }
        .onAppear {
            if !model.settings.isComplete {
                showSettings = true
            }
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
