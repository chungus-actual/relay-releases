import SwiftUI

// Select the property wrapper on SDKs that also declare a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct ShellTheme {
    let settings: AppearancePreferences
    let system: ColorScheme
    var dark: Bool { settings.mode == "System" ? system == .dark : settings.mode != "Light" }
    private var colors: [String] {
        switch (settings.surface, dark) {
        case ("Ocean", true): return ["131C28", "0F1722", "1A2635", "26374A", "EEF4FA", "99ABBF", "2B3D50"]
        case ("Ocean", false): return ["F0F5FA", "E7EEF6", "FCFDFF", "DEE8F2", "1B3046", "536B82", "D2DEE9"]
        case ("Dune", true): return ["211E1B", "191715", "2A2622", "3A342E", "F5F0E8", "B2A69A", "413A33"]
        case ("Dune", false): return ["F7F3EC", "EEE8DD", "FFFCF6", "EAE2D6", "352E26", "786B5C", "DED5C8"]
        case (_, false): return ["F5F6F8", "EBEEF1", "FFFFFF", "E5E9ED", "202830", "65717D", "D9DFE5"]
        default: return ["17191D", "121418", "1E2126", "2B3038", "F1F3F5", "9BA4AF", "30363F"]
        }
    }
    var base: Color { Color(hex: colors[0]) }
    var panel: Color { Color(hex: colors[1]) }
    var card: Color { Color(hex: colors[2]) }
    var hover: Color { Color(hex: colors[3]) }
    var ink: Color { Color(hex: colors[4]) }
    var muted: Color { Color(hex: colors[5]) }
    var line: Color { Color(hex: colors[6]) }
    func accent(_ name: String) -> Color {
        let values: [String: [String]] = ["Mint": ["85DFC3", "13795F"], "Sky": ["8ABBFF", "235DB7"],
            "Iris": ["BAA4FF", "7250BA"], "Rose": ["F3A4B9", "B33E68"], "Amber": ["EDC37F", "95601A"]]
        return Color(hex: (values[name] ?? values["Mint"]!)[dark ? 0 : 1])
    }
    var accent: Color { accent(settings.accent) }
    var soft: Color { accent.opacity(dark ? 28.0 / 255 : 22.0 / 255) }
}

struct ShellButtonStyle: ButtonStyle {
    let theme: ShellTheme
    var selected = false
    var bordered = false
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, theme: theme, selected: selected, bordered: bordered, primary: primary)
    }
    private struct Surface: View {
        let configuration: Configuration
        let theme: ShellTheme
        let selected: Bool
        let bordered: Bool
        let primary: Bool
        @ViewState private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(primary ? (theme.dark ? Color(hex: "13251F") : .white) : selected ? theme.accent : theme.ink)
                .background(primary ? theme.accent.opacity(hovered ? 0.85 : 1) : hovered ? theme.hover : selected ? theme.soft : bordered ? theme.card : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected && bordered ? theme.accent : bordered ? theme.line : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
                .onHover { hovered = $0 }
        }
    }
}

struct ServiceIcon: View {
    let id: String
    var size: CGFloat = 21
    private static var images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "svg", subdirectory: "ServiceIcons") ?? [] {
            if let image = NSImage(contentsOf: url) { image.isTemplate = true; result[url.deletingPathExtension().lastPathComponent] = image }
        }
        return result
    }()
    var body: some View {
        if let image = Self.images[id] {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "bubble.left").resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

struct RelayMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7, y: 21)); path.addLine(to: CGPoint(x: 7, y: 12))
        path.addCurve(to: CGPoint(x: 25, y: 12), control1: CGPoint(x: 7, y: 3), control2: CGPoint(x: 25, y: 3))
        path.addCurve(to: CGPoint(x: 14, y: 18), control1: CGPoint(x: 25, y: 18), control2: CGPoint(x: 17, y: 18))
        path.addLine(to: CGPoint(x: 24, y: 27))
        path.move(to: CGPoint(x: 7, y: 28)); path.addLine(to: CGPoint(x: 7, y: 28.5))
        return path.applying(CGAffineTransform(scaleX: rect.width / 32, y: rect.height / 32))
    }
}
