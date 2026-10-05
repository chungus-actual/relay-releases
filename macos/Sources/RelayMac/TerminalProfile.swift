import AppKit

/// A snapshot of compatible appearance settings, never commands or environment variables.
struct TerminalProfile: Codable {
    var id: String
    var name: String
    var fontFamily: String?
    var fontSize: Double?
    var lineHeight: Double?
    var cursorStyle: String?
    var cursorBlink: Bool?
    var scrollback: Int?
    var colors: [String: String] = [:]

    var options: [String: Any] {
        var result: [String: Any] = [:]
        if let fontFamily { result["fontFamily"] = fontFamily }
        if let fontSize, fontSize.isFinite { result["fontSize"] = min(72, max(6, fontSize)) }
        if let lineHeight, lineHeight.isFinite { result["lineHeight"] = min(3, max(1, lineHeight)) }
        if let cursorStyle { result["cursorStyle"] = cursorStyle }
        if let cursorBlink { result["cursorBlink"] = cursorBlink }
        if let scrollback { result["scrollback"] = min(100_000, max(0, scrollback)) }
        return result
    }
}

@MainActor
enum TerminalProfiles {
    static let ansi = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                       "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]

    private static func cssFont(_ names: [String]) -> String? {
        let families = names.compactMap { NSFont(name: $0, size: 12)?.familyName }
        guard !families.isEmpty else { return nil }
        // Resolve PostScript names to installed CSS families and quote each name.
        return (families + fallbackFonts()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + ", monospace"
    }
    private static func fallbackFonts() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter {
            $0.localizedCaseInsensitiveContains("Nerd Font") || $0.hasSuffix(" NF") || $0.hasSuffix(" NFM")
        }.sorted() + ["Menlo"]
    }
    static var defaultFont: String { cssFont(["Menlo"]) ?? "Menlo, monospace" }

    private static func hex(_ color: NSColor?) -> String? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    private static func plist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000 else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [TerminalProfile] {
        let preferences = home.appendingPathComponent("Library/Preferences")
        var iterm = plist(preferences.appendingPathComponent("com.googlecode.iterm2.plist"))
        if iterm["LoadPrefsFromCustomFolder"] as? Bool == true, let folder = iterm["PrefsCustomFolder"] as? String, folder.hasPrefix("/") || folder.hasPrefix("~") {
            let custom = plist(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).appendingPathComponent("com.googlecode.iterm2.plist"))
            if !custom.isEmpty { iterm = custom }
        }
        var bookmarks = iterm["New Bookmarks"] as? [[String: Any]] ?? []
        let dynamic = home.appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles")
        for url in (try? FileManager.default.contentsOfDirectory(at: dynamic, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: url), data.count <= 4_000_000,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let profiles = value["Profiles"] as? [[String: Any]] else { continue }
            bookmarks += profiles
        }
        let defaultGUID = iterm["Default Bookmark Guid"] as? String
        var profiles = bookmarks.compactMap { iTerm($0) }.sorted { ($0.id == "iterm:" + (defaultGUID ?? "") ? 0 : 1, $0.name) < ($1.id == "iterm:" + (defaultGUID ?? "") ? 0 : 1, $1.name) }
        let terminal = plist(preferences.appendingPathComponent("com.apple.Terminal.plist"))
        let defaultName = terminal["Default Window Settings"] as? String
        let settings = terminal["Window Settings"] as? [String: [String: Any]] ?? [:]
        profiles += settings.keys.sorted { ($0 == defaultName ? 0 : 1, $0) < ($1 == defaultName ? 0 : 1, $1) }.compactMap { appleTerminal(settings[$0]!, name: $0) }
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        var ghost: [String: String] = [:]
        for folder in [home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty"), xdg.appendingPathComponent("ghostty")] {
            // New versions prefer config.ghostty; older versions use config.
            let modern = folder.appendingPathComponent("config.ghostty")
            let url = FileManager.default.fileExists(atPath: modern.path) ? modern : folder.appendingPathComponent("config")
            ghost.merge(ghosttyValues(url: url)) { _, new in new }
        }
        if let value = ghostty(ghost) { profiles.append(value) }
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    static func iTerm(_ settings: [String: Any]) -> TerminalProfile? {
        guard let name = settings["Name"] as? String, let guid = settings["Guid"] as? String else { return nil }
        var p = TerminalProfile(id: "iterm:" + guid, name: "iTerm2 · " + name)
        if let raw = settings["Normal Font"] as? String, let split = raw.lastIndex(of: " ") {
            var names = [String(raw[..<split])]
            if settings["Use Non-ASCII Font"] as? Bool == true, let other = settings["Non Ascii Font"] as? String, let space = other.lastIndex(of: " ") { names.append(String(other[..<space])) }
            p.fontFamily = cssFont(names); p.fontSize = Double(raw[raw.index(after: split)...])
        }
        p.lineHeight = settings["Vertical Spacing"] as? Double
        p.cursorStyle = [0: "block", 1: "bar", 2: "underline"][settings["Cursor Type"] as? Int ?? 0]
        p.cursorBlink = settings["Blinking Cursor"] as? Bool ?? false
        p.scrollback = settings["Unlimited Scrollback"] as? Bool == true ? 100_000 : settings["Scrollback Lines"] as? Int
        var mappings = ["Background Color": "background", "Foreground Color": "foreground", "Cursor Color": "cursor", "Cursor Text Color": "cursorAccent", "Selection Color": "selectionBackground", "Selected Text Color": "selectionForeground"]
        for (i, name) in ansi.enumerated() { mappings["Ansi \(i) Color"] = name }
        for (key, value) in mappings {
            guard let rgb = settings[key] as? [String: Any], let r = rgb["Red Component"] as? Double, let g = rgb["Green Component"] as? Double, let b = rgb["Blue Component"] as? Double,
                  [r, g, b].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { continue }
            p.colors[value] = hex(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
        }
        return p
    }

    static func appleTerminal(_ settings: [String: Any], name: String) -> TerminalProfile? {
        var p = TerminalProfile(id: "terminal:" + name, name: "Terminal · " + name)
        if let data = settings["Font"] as? Data, let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
            p.fontFamily = cssFont([font.fontName]); p.fontSize = font.pointSize
        }
        p.lineHeight = settings["FontHeightSpacing"] as? Double
        p.cursorStyle = [0: "block", 1: "underline", 2: "bar"][settings["CursorType"] as? Int ?? 0]
        p.cursorBlink = settings["CursorBlink"] as? Bool ?? false
        p.scrollback = settings["ScrollbackLines"] as? Int
        var mappings = ["BackgroundColor": "background", "TextColor": "foreground", "CursorColor": "cursor", "SelectionColor": "selectionBackground"]
        for name in ansi { mappings["ANSI" + name.prefix(1).uppercased() + name.dropFirst() + "Color"] = name }
        for (key, value) in mappings {
            if let data = settings[key] as? Data, let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { p.colors[value] = hex(color) }
        }
        return p
    }

    static func ghosttyValues(url: URL, depth: Int = 0, visited: Set<URL> = [], isTheme: Bool = false) -> [String: String] {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard depth < 8, !visited.contains(canonical), let data = try? Data(contentsOf: url), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:], includes: [URL] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key == "config-file", !isTheme {
                let path = (String(value.drop(while: { $0 == "?" })) as NSString).expandingTildeInPath
                includes.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.deletingLastPathComponent().appendingPathComponent(path))
            } else if key == "palette", let equal = value.firstIndex(of: "=") {
                values["palette." + value[..<equal].trimmingCharacters(in: .whitespaces)] = value[value.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            } else { values[key] = value }
        }
        if !isTheme, let theme = values["theme"], !theme.contains(":"), !theme.contains(",") {
            let path = (theme as NSString).expandingTildeInPath
            let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            let localTheme = xdg.appendingPathComponent("ghostty/themes/" + theme)
            let bundledTheme = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")?.appendingPathComponent("Contents/Resources/ghostty/themes/" + theme)
            let themeURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.fileExists(atPath: localTheme.path) ? localTheme : bundledTheme
            if let themeURL { values = ghosttyValues(url: themeURL, depth: depth + 1, visited: visited.union([canonical]), isTheme: true).merging(values) { _, value in value } }
        }
        for include in includes { values.merge(ghosttyValues(url: include, depth: depth + 1, visited: visited.union([canonical]))) { _, value in value } }
        return values
    }
    static func ghostty(_ settings: [String: String]) -> TerminalProfile? {
        var p = TerminalProfile(id: "ghostty", name: "Ghostty · Configuration")
        if let family = settings["font-family"] { p.fontFamily = cssFont([family]) }
        p.fontSize = settings["font-size"].flatMap(Double.init)
        p.cursorStyle = ["block": "block", "bar": "bar", "underline": "underline", "block_hollow": "block"][settings["cursor-style"] ?? ""]
        p.cursorBlink = settings["cursor-style-blink"].flatMap { ["true": true, "false": false][$0] }
        var mappings = ["background": "background", "foreground": "foreground", "cursor-color": "cursor", "cursor-text": "cursorAccent", "selection-background": "selectionBackground", "selection-foreground": "selectionForeground"]
        for (i, name) in ansi.enumerated() { mappings["palette.\(i)"] = name }
        for (key, value) in mappings {
            if let raw = settings[key] {
                let color = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
                if color.count == 6 && color.allSatisfy(\.isHexDigit) { p.colors[value] = "#" + color }
            }
        }
        return p.options.isEmpty && p.colors.isEmpty ? nil : p
    }
}
