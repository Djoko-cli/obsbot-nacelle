import Testing
@testable import PTZCore

@Suite("Issue d'une exécution d'obsbot-ai")
struct AIResultTests {
    @Test("Motifs en français pour l'utilisateur : aucune forme brute de l'énumération")
    func userDescriptions() {
        #expect(AIResult.cameraNotFound.userDescription == "caméra introuvable")
        #expect(AIResult.sdkError.userDescription == "erreur du SDK OBSBOT")
        #expect(AIResult.timeout.userDescription == "délai dépassé")
        #expect(AIResult.launchFailed("/x : introuvable").userDescription == "l'utilitaire n'a pas pu être lancé")
        #expect(AIResult.unexpectedExit(7).userDescription == "l'utilitaire s'est arrêté avec le code 7")
    }
}
