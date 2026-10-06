import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// QR code pour le Terminal (spec découverte et QR § 7.2) : deux rangées de modules par ligne de caractères
/// demi-blocs, noir sur blanc imposé par des codes ANSI quel que soit le thème du Terminal.
public enum QRCodeText {
    /// Marge blanche autour du code, en modules.
    public static let margin = 2

    /// Modules du QR code (true : noir), marge comprise ; nil si le texte ne tient pas dans un QR code.
    public static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        // CoreImage entoure le code d'un module blanc, retiré ici pour poser notre marge.
        let size = Int(image.extent.width)
        var pixels = [UInt8](repeating: 0, count: size * size)
        CIContext().render(image, toBitmap: &pixels, rowBytes: size, bounds: image.extent, format: .L8, colorSpace: nil)
        let inner = (1..<(size - 1)).map { y in (1..<(size - 1)).map { x in pixels[y * size + x] < 128 } }
        let width = inner.count + 2 * margin
        let blank = [[Bool]](repeating: [Bool](repeating: false, count: width), count: margin)
        let padding = [Bool](repeating: false, count: margin)
        return blank + inner.map { padding + $0 + padding } + blank
    }

    /// Le texte à afficher : une ligne pour deux rangées de modules.
    public static func render(_ modules: [[Bool]]) -> String {
        var rows = modules
        if rows.count % 2 == 1, let first = rows.first {
            rows.append([Bool](repeating: false, count: first.count))
        }
        return stride(from: 0, to: rows.count, by: 2).map { y in
            let line = zip(rows[y], rows[y + 1]).map { top, bottom in
                switch (top, bottom) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
            }.joined()
            return "\u{1B}[30;107m" + line + "\u{1B}[0m"
        }.joined(separator: "\n")
    }
}
