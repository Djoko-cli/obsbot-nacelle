import CoreGraphics
import Foundation
import Testing
import Vision
@testable import PTZServer

@Suite("QR code dans le Terminal")
struct QRCodeTextTests {
    let url = "nacelle://pair?v=1&id=1a2b3c4d&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.0.2.30,192.0.2.31&p=1985"

    /// Motif de repérage de 7 modules dont le coin haut gauche est en (ligne, colonne).
    private func isFinder(_ modules: [[Bool]], _ row: Int, _ column: Int) -> Bool {
        (0..<7).allSatisfy { i in
            (0..<7).allSatisfy { j in
                let dark = i == 0 || i == 6 || j == 0 || j == 6 || ((2...4).contains(i) && (2...4).contains(j))
                return modules[row + i][column + j] == dark
            }
        }
    }

    @Test("Modules : carré, marge blanche de 2, repères en haut à gauche, en haut à droite et en bas à gauche")
    func modules() throws {
        let modules = try #require(QRCodeText.modules(for: url))
        let size = modules.count
        let margin = QRCodeText.margin
        #expect(modules.allSatisfy { $0.count == size })
        #expect((size - 2 * margin - 21) % 4 == 0)
        #expect(modules.prefix(margin).allSatisfy { $0.allSatisfy { !$0 } })
        #expect(modules.suffix(margin).allSatisfy { $0.allSatisfy { !$0 } })
        #expect(modules.allSatisfy { !$0.prefix(margin).contains(true) && !$0.suffix(margin).contains(true) })
        let far = size - margin - 7
        #expect(isFinder(modules, margin, margin))
        #expect(isFinder(modules, margin, far))
        #expect(isFinder(modules, far, margin))
        #expect(!isFinder(modules, far, far))
    }

    @Test("Texte : demi-blocs noir sur blanc, une ligne pour deux rangées ; relu par Vision, il redonne l'URL")
    func readable() throws {
        let modules = try #require(QRCodeText.modules(for: url))
        let lines = QRCodeText.render(modules).components(separatedBy: "\n")
        #expect(lines.count == (modules.count + 1) / 2)
        #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;107m") && $0.hasSuffix("\u{1B}[0m") })
        #expect(try decode(lines) == url)
    }

    /// Redessine le texte en image (10 pixels par module) et la fait lire par Vision.
    private func decode(_ lines: [String]) throws -> String? {
        var rows: [[Bool]] = []
        for line in lines {
            let body = line.dropFirst("\u{1B}[30;107m".count).dropLast("\u{1B}[0m".count)
            rows.append(body.map { $0 == "█" || $0 == "▀" })
            rows.append(body.map { $0 == "█" || $0 == "▄" })
        }
        let scale = 10
        let width = rows[0].count * scale
        let height = rows.count * scale
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        pixels[(y * scale + dy) * width + x * scale + dx] = 0
                    }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first?.payloadStringValue
    }
}
