import NacelleProtocol
import Testing
@testable import Nacelle

@Suite("Bandeau d'état")
struct StatusBannerTests {
    private func state(
        camera: CameraPresence = .connected,
        control: ControlState = .ready,
        privacy: Bool = false
    ) -> StateSnapshot {
        StateSnapshot(camera: camera, control: control, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false)
    }

    private func text(unreachable: Bool = false, connecting: Bool = false, _ state: StateSnapshot? = nil) -> String? {
        StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, connecting: connecting, state: state))
    }

    @Test("Appairage : texte selon le problème, juste après « Mac injoignable »")
    func pairingTexts() {
        func text(_ issue: PTZClient.AuthIssue, unreachable: Bool = false) -> String? {
            StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, authIssue: issue, connecting: true, state: state(camera: .absent)))
        }
        #expect(text(.unpaired) == "iPhone non appairé : lance ptzd pair sur le Mac")
        #expect(text(.badCode) == "Code d'appairage refusé")
        #expect(text(.rejected) == "Accès refusé par le Mac")
        #expect(text(.needsTailscale) == "Appairage : active Tailscale sur l'iPhone")
        #expect(text(.unpaired, unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
    }

    @Test("Chaque condition a son texte")
    func texts() {
        #expect(text(unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(state(camera: .absent)) == "Caméra débranchée")
        #expect(text(state(privacy: true)) == "Vie privée")
        #expect(text(state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        #expect(text(state(control: .taking)) == "Prise en main…")
        #expect(text(connecting: true) == "Connexion…")
        #expect(text(state()) == nil)
    }

    @Test("Priorité : injoignable, débranchée, vie privée, suivi IA, prise en main, connexion")
    func priority() {
        let everything = state(camera: .absent, control: .taking, privacy: true)
        #expect(text(unreachable: true, connecting: true, everything) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(connecting: true, everything) == "Caméra débranchée")
        #expect(text(connecting: true, state(control: .failed, privacy: true)) == "Vie privée")
        #expect(text(connecting: true, state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        #expect(text(connecting: true, state(control: .taking)) == "Prise en main…")
    }
}
