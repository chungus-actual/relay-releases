import AppKit

@MainActor
enum AppIdentity {
    static var icon: NSImage? {
        Bundle.main.url(forResource: "Relay", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    }

    static func showAbout() {
        let credits = NSMutableAttributedString()
        func line(_ text: String, bold: Bool = false) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = 8
            credits.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]))
        }
        line("Thin apps. Thicc brain.", bold: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Relay",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .credits: credits
        ]
        if let icon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
