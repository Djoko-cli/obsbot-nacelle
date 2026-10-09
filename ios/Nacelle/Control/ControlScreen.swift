import SwiftUI

/// L'écran unique : la vidéo en plein écran, les commandes par-dessus (spec § 7.2 et § 7.3).
struct ControlScreen: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var privacyOn: Bool {
        model.ptz.state?.privacy ?? false
    }

    /// En portrait (hauteur « regular »), la rangée du haut tient tout juste ses cinq boutons : le bandeau et le badge
    /// d'enregistrement passent chacun sur leur ligne en dessous. En paysage, ils restent dans la rangée.
    private var bannerOnOwnRow: Bool {
        verticalSizeClass == .regular
    }

    /// Mode épuré (tap sur la vidéo) : seuls le bouton rec et le badge restent, pendant un enregistrement.
    private var clean: Bool {
        model.cleanFeed
    }

    /// Le bouton rec, en mode épuré : visible seulement pendant un enregistrement ou sa sauvegarde.
    private var recordButtonShown: Bool {
        !clean || model.recording != .idle
    }

    private var banner: BannerView? {
        guard let text = clean ? model.cleanFeedBannerText : model.bannerText else { return nil }
        return BannerView(
            text: text,
            retry: model.showsRetry ? { Task { await model.retrySave() } } : nil,
            dismiss: model.showsRetry ? { model.dismissUnsavedClipBanner() } : nil
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoView(session: model.video)
                .ignoresSafeArea()
            // Un tap sur la vidéo nue masque ou rend l'interface. Sous les commandes : le joystick, le zoom et les
            // boutons gardent leurs propres gestes.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { model.toggleCleanFeed() }
                }
                .accessibilityLabel(clean ? "Afficher les commandes" : "Masquer les commandes")
                .accessibilityAddTraits(.isButton)
            VStack {
                ZStack(alignment: .top) {
                    // Masqués sans quitter la mise en page : le bouton rec garde sa place en mode épuré.
                    HStack(alignment: .top) {
                        settingsButton
                            .hiddenInCleanFeed(clean)
                        Spacer(minLength: 12)
                        HStack(spacing: 10) {
                            soundButton
                                .hiddenInCleanFeed(clean)
                            aiButton
                                .hiddenInCleanFeed(clean)
                            recordButton
                                .hiddenInCleanFeed(!recordButtonShown)
                            privacyButton
                                .hiddenInCleanFeed(clean)
                        }
                    }
                    // Paysage : le badge d'enregistrement et le bandeau, centrés sur toute la largeur de l'écran (et non
                    // entre la roue et les quatre boutons). La marge de chaque côté vaut la largeur du groupe de droite
                    // (4 × 44 + 3 × 10 points) plus un écart : ils ne recouvrent jamais un bouton.
                    if !bannerOnOwnRow {
                        HStack(spacing: 10) {
                            if case let .recording(since) = model.recording {
                                RecordingBadge(since: since)
                            }
                            if let banner {
                                banner
                            }
                        }
                        .padding(.horizontal, 4 * 44 + 3 * 10 + 12)
                    }
                }
                // Portrait : le bandeau, centré sur sa ligne, au-dessus du badge.
                if bannerOnOwnRow, let banner {
                    banner
                }
                // Portrait : le badge, sous la rangée du haut, au centre.
                if bannerOnOwnRow, case let .recording(since) = model.recording {
                    RecordingBadge(since: since)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    JoystickView(
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setJoystick($0) },
                        onRelease: { model.ptz.setJoystick(.zero) }
                    )
                    .hiddenInCleanFeed(clean)
                    Spacer()
                    ZoomSlider(
                        value: model.ptz.state?.zoom,
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setZoom($0) }
                    )
                    .hiddenInCleanFeed(clean)
                }
            }
            .padding(20)
        }
        .statusBarHidden(clean)
        .persistentSystemOverlays(clean ? .hidden : .automatic)
        .sensoryFeedback(.success, trigger: model.ptz.state?.privacy) { old, new in
            // Seulement entre deux états connus : pas à la coupure ni à la reconnexion.
            old != nil && new != nil && old != new
        }
        .sensoryFeedback(.success, trigger: model.savedCount)
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
            Group {
                if model.aiTrackingBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: model.aiTrackingOn ? "person.crop.square.fill" : "person.crop.square")
                        .font(.title3)
                }
            }
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.aiToggleEnabled)
        .opacity(model.aiToggleEnabled || model.aiTrackingBusy ? 1 : 0.4)
        .accessibilityLabel(model.aiTrackingBusy ? "Suivi IA en cours de changement" : model.aiTrackingOn ? "Couper le suivi IA" : "Allumer le suivi IA")
    }

    private var isRecording: Bool {
        if case .recording = model.recording { true } else { false }
    }

    /// Atténué quand il est inactif, ou quand l'accès à Photos est refusé (il reste touchable : il explique).
    private var recordDimmed: Bool {
        switch model.recording {
        case .recording, .saving: false
        case .idle: !model.recordToggleEnabled || model.photoAccessDenied
        }
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            Group {
                if model.recording == .saving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                        .font(.title3)
                }
            }
            .frame(width: 44, height: 44)
            .background(isRecording ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.recordToggleEnabled)
        .opacity(recordDimmed ? 0.4 : 1)
        .accessibilityLabel(isRecording ? "Arrêter l'enregistrement" : model.recording == .saving ? "Enregistrement en cours de sauvegarde" : "Enregistrer")
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

/// Le bandeau d'état, en haut de l'écran. `retry` : « Réessayer », pour une vidéo qui n'est pas dans Photos ;
/// `dismiss` : la croix qui ferme ce bandeau (le fichier reste, effacé au bout de 7 jours).
private struct BannerView: View {
    let text: String
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            if let retry {
                Button("Réessayer", action: retry)
                    .font(.subheadline.weight(.bold))
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Fermer")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// « ● 00:42 » : le point rouge pulse, le chronomètre garde des chiffres de largeur fixe (spec enregistrement § 3).
private struct RecordingBadge: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(dimmed ? 0.25 : 1)
                Text(RecordingFormat.clock(seconds: seconds))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RecordingFormat.spoken(seconds: seconds))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}

private extension View {
    /// Masqué en mode épuré : transparent et sans toucher, mais à sa place (rien ne bouge autour).
    func hiddenInCleanFeed(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}
