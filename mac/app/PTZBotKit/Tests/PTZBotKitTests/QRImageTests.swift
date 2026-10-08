import CoreGraphics
import Testing
import Vision
@testable import PTZBotKit

@Suite("Image du QR code", .french)
struct QRImageTests {
    let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.168.0.10,10.0.0.5&p=1985"

    @Test("Carrée, 10 pixels par module avec une marge de 4 modules ; relue par Vision, elle redonne le lien")
    func readable() throws {
        let image = try #require(QRImage.make(text))
        #expect(image.width == image.height)
        #expect(image.width % 10 == 0)
        let modules = image.width / 10
        #expect((modules - 8 - 21) % 4 == 0)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        #expect(request.results?.first?.payloadStringValue == text)
    }
}
