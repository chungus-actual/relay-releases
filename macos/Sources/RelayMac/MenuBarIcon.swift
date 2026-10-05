import AppKit

@MainActor
enum RelayMenuBarIcon {
    // Reuse the shell's Relay mark. A template image lets macOS supply the correct
    // foreground for light/dark menu bars and the selected menu-item background.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(RelayMark().path(in: rect).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Relay"
        return image
    }()
}
