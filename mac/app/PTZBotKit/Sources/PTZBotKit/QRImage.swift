import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// L'image du QR code d'appairage (spec app Mac § 8.3) : modules nets (sans lissage), marge blanche de
/// 4 modules, `scale` pixels par module.
public enum QRImage {
    public static func make(_ text: String, scale: Int = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // CoreImage entoure déjà le code d'un module blanc : 3 de plus font la marge de 4.
        let modules = code.extent.width + 6
        let scaled = code
            .transformed(by: CGAffineTransform(translationX: 3, y: 3))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: modules, height: modules)))
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
