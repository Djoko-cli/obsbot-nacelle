import AppKit

/// L'icône de la barre des menus (spec app Mac § 8.2) : silhouette de la Tiny 2 dessinée en formes
/// nettes, en image modèle que macOS teinte selon la barre. Repère de 300 × 300, origine en haut à gauche.
public enum MenuBarIcon {
    /// Hauteur en points dans la barre des menus.
    public static let height: CGFloat = 18
    /// Zone utile du repère (tête, bras et socle), avec le liseré de la tête.
    static let frame = CGRect(x: 40, y: 13, width: 250, height: 261)

    public static func image() -> NSImage {
        let scale = height / frame.height
        let size = NSSize(width: (frame.width * scale).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            draw(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PTZBot"
        return image
    }

    /// Les formes, en noir sur transparent.
    static func draw(in context: CGContext) {
        context.setFillColor(.black)
        // Bras : cylindre derrière la tête, puis tige.
        context.addPath(CGPath(roundedRect: CGRect(x: 150, y: 38, width: 92, height: 76), cornerWidth: 36, cornerHeight: 36, transform: nil))
        context.addRect(CGRect(x: 186, y: 100, width: 36, height: 58))
        context.fillPath()
        // Liseré de 9 autour de la tête : efface le bras derrière elle.
        context.setBlendMode(.clear)
        context.addPath(CGPath(roundedRect: CGRect(x: 61, y: 13, width: 136, height: 130), cornerWidth: 43, cornerHeight: 43, transform: nil))
        context.fillPath()
        context.setBlendMode(.normal)
        // Tête.
        context.addPath(CGPath(roundedRect: CGRect(x: 70, y: 22, width: 118, height: 112), cornerWidth: 34, cornerHeight: 34, transform: nil))
        context.fillPath()
        // Objectif : anneau évidé, centre plein.
        context.setBlendMode(.clear)
        context.addEllipse(in: CGRect(x: 126 - 38, y: 76 - 38, width: 76, height: 76))
        context.fillPath()
        context.setBlendMode(.normal)
        context.addEllipse(in: CGRect(x: 126 - 25, y: 76 - 25, width: 50, height: 50))
        context.fillPath()
        // Socle.
        context.addPath(CGPath(roundedRect: CGRect(x: 52, y: 162, width: 216, height: 112), cornerWidth: 30, cornerHeight: 30, transform: nil))
        context.fillPath()
    }
}
