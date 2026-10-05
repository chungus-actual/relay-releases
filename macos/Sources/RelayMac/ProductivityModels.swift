import Foundation

struct SavedWorkspace: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var layout: WorkspaceLayout
    var focused: UUID?
}

struct AccountBookmark: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var accountId: UUID
    var name: String
    var url: String
}

enum Productivity {
    static let colors = ["", "Mint", "Sky", "Iris", "Rose", "Amber"]
    static func snoozed(_ until: Int64?, now: Date = Date()) -> Bool { Double(until ?? 0) > now.timeIntervalSince1970 }
    static func matches(_ query: String, _ values: String...) -> Bool {
        query.split(separator: " ").allSatisfy { word in values.contains { $0.localizedCaseInsensitiveContains(String(word)) } }
    }
    static func paletteMatches(_ query: String, _ values: String...) -> Bool {
        query.lowercased().split(separator: " ").allSatisfy { word in values.contains { value in
            let letters = Array(word); var index = 0
            for character in value.lowercased() where index < letters.count { if character == letters[index] { index += 1 } }
            return index == letters.count
        } }
    }
    static func name(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 80, !result.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SetupError.invalid("Use a name between 1 and 80 characters.")
        }
        return result
    }
    static func bookmarkAllowed(_ value: String, service: Service) -> Bool {
        guard value.count <= 4096, let url = URL(string: value), url.user == nil, url.password == nil else { return false }
        return service.contains(url)
    }
}

enum SetupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct PortableAccount: Codable {
    var id: String
    var provider: String
    var name: String
    var color: String
    var visible: Bool
    var keepLive: Bool
    var notifications: Bool
    var audioMuted: Bool
    var gmailAllUnread: Bool
    var zoom: Double
}

struct PortableWorkspace: Codable {
    struct Layout: Codable {
        var panes: [String]
        var arrangement: String
        var primary: Double
        var cuts: [Double]
    }
    var id: String
    var name: String
    var layout: Layout
    var focused: String?
}

struct PortableBookmark: Codable {
    var id: String
    var accountId: String
    var name: String
    var url: String
}

struct PortableSetup: Codable {
    var version = 1
    var mode: String
    var surface: String
    var accent: String
    var compact: Bool
    var topTabs: Bool
    var hidePaletteButton: Bool?
    var companionEnabled: Bool
    var companion: String
    var captureLinks: Bool
    var quiet: Bool
    var accounts: [PortableAccount]
    var workspaces: [PortableWorkspace]
    var bookmarks: [PortableBookmark]

    static func decode(_ data: Data, services: [Service]) throws -> Self {
        guard data.count <= 2_000_000 else { throw SetupError.invalid("This setup file is too large.") }
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.accounts.count <= 128, value.workspaces.count <= 32, value.bookmarks.count <= 200,
              ["System", "Dark", "Light"].contains(value.mode), ["Graphite", "Ocean", "Dune"].contains(value.surface),
              Productivity.colors.dropFirst().contains(value.accent), ["puke", "roof", "rock"].contains(value.companion) else {
            throw SetupError.invalid("Unsupported or invalid Relay setup.")
        }
        var keys = Set<String>(), names = Set<String>()
        for i in value.accounts.indices {
            let a = value.accounts[i]
            guard !a.id.isEmpty, a.id.count <= 80, keys.insert(a.id).inserted, services.contains(where: { $0.id == a.provider && !$0.isTerminal }),
                  Productivity.colors.contains(a.color), a.zoom.isFinite, (0.5...2).contains(a.zoom) else { throw SetupError.invalid("Invalid account in setup.") }
            value.accounts[i].name = try Productivity.name(a.name)
            guard names.insert(a.provider + "\n" + value.accounts[i].name.lowercased()).inserted else { throw SetupError.invalid("Duplicate account names in setup.") }
        }
        let accountKeys = keys
        keys.removeAll()
        for i in value.workspaces.indices {
            let w = value.workspaces[i]
            guard !w.id.isEmpty, keys.insert(w.id).inserted, (1...4).contains(w.layout.panes.count),
                  w.layout.panes.allSatisfy(accountKeys.contains), w.layout.primary.isFinite, w.layout.cuts.allSatisfy(\.isFinite) else {
                throw SetupError.invalid("Invalid workspace in setup.")
            }
            value.workspaces[i].name = try Productivity.name(w.name)
        }
        keys.removeAll()
        for i in value.bookmarks.indices {
            let b = value.bookmarks[i]
            guard !b.id.isEmpty, keys.insert(b.id).inserted, let a = value.accounts.first(where: { $0.id == b.accountId }),
                  let service = services.first(where: { $0.id == a.provider }), Productivity.bookmarkAllowed(b.url, service: service) else {
                throw SetupError.invalid("A bookmark does not belong to its account's service.")
            }
            value.bookmarks[i].name = try Productivity.name(b.name)
        }
        return value
    }

    func encode() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
}

extension Preferences {
    func exportSetup() -> PortableSetup {
        let look = appearance ?? AppearancePreferences()
        let portable = Set(accounts.filter { $0.serviceID != "terminal" }.map(\.id))
        return PortableSetup(mode: look.mode, surface: look.surface, accent: look.accent, compact: look.compact, topTabs: look.topTabs,
            hidePaletteButton: hidePaletteButton == true,
            companionEnabled: titlebarPetEnabled == true, companion: ["puke", "roof", "rock"].contains(titlebarCompanion ?? "") ? titlebarCompanion! : "puke",
            captureLinks: captureLinks == true, quiet: quiet == true,
            accounts: accounts.filter { portable.contains($0.id) }.map { a in PortableAccount(id: a.id.uuidString, provider: a.serviceID, name: a.name,
                color: a.identityColor ?? "", visible: !(hiddenAccountIDs ?? []).contains(a.id), keepLive: a.staysAwake,
                notifications: a.notifications != false, audioMuted: a.audioMuted == true, gmailAllUnread: a.gmailAllUnread == true, zoom: a.zoom) },
            workspaces: (savedWorkspaces ?? []).filter { $0.layout.panes.allSatisfy { portable.contains($0) } }.map { w in PortableWorkspace(id: w.id, name: w.name,
                layout: .init(panes: w.layout.panes.map(\.uuidString), arrangement: w.layout.arrangement, primary: w.layout.primary, cuts: w.layout.cuts), focused: w.focused?.uuidString) },
            bookmarks: (bookmarks ?? []).filter { portable.contains($0.accountId) }.map { PortableBookmark(id: $0.id, accountId: $0.accountId.uuidString, name: $0.name, url: $0.url) })
    }

    mutating func mergeSetup(_ setup: PortableSetup, services: [Service]) throws {
        var mapping: [String: UUID] = [:]
        for a in setup.accounts {
            let service = services.first { $0.id == a.provider }!
            let matching = accounts.first { $0.serviceID == a.provider && $0.name.caseInsensitiveCompare(a.name) == .orderedSame } ??
                accounts.first { $0.serviceID == a.provider && $0.id.uuidString == a.id && !mapping.values.contains($0.id) }
            let id: UUID
            if let matching { id = matching.id } else { id = try addAccount(service: service, name: a.name).id }
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { continue }
            guard !mapping.values.contains(id) else { throw SetupError.invalid("Two imported accounts refer to the same local account.") }
            mapping[a.id] = id
            accounts[i].name = a.name
            accounts[i].identityColor = a.color; accounts[i].keepLive = a.keepLive; accounts[i].notifications = a.notifications
            accounts[i].audioMuted = a.audioMuted; accounts[i].gmailAllUnread = a.gmailAllUnread; accounts[i].pageZoom = a.zoom
            setVisible(id, a.visible)
        }
        let importedOrder = setup.accounts.compactMap { mapping[$0.id] }
        accounts = importedOrder.compactMap { id in accounts.first { $0.id == id } } + accounts.filter { !importedOrder.contains($0.id) }
        for w in setup.workspaces {
            var layout = WorkspaceLayout()
            layout.panes = w.layout.panes.compactMap { mapping[$0] }; layout.arrangement = w.layout.arrangement
            layout.primary = w.layout.primary; layout.cuts = w.layout.cuts; layout.normalize(available: accounts.map(\.id))
            let item = SavedWorkspace(id: w.id, name: w.name, layout: layout, focused: w.focused.flatMap { mapping[$0] })
            var list = savedWorkspaces ?? []; list.removeAll { $0.id == item.id }; list.append(item); savedWorkspaces = list
        }
        for b in setup.bookmarks {
            guard let id = mapping[b.accountId] else { continue }
            let item = AccountBookmark(id: b.id, accountId: id, name: b.name, url: b.url)
            var list = bookmarks ?? []; list.removeAll { $0.id == item.id || ($0.accountId == id && $0.url == b.url) }; list.append(item); bookmarks = list
        }
        guard accounts.count <= 128, (savedWorkspaces ?? []).count <= 32, (bookmarks ?? []).count <= 200 else { throw SetupError.invalid("The merged setup exceeds Relay's saved-item limits.") }
        appearance = AppearancePreferences(mode: setup.mode, surface: setup.surface, accent: setup.accent, compact: setup.compact, topTabs: setup.topTabs)
        if let hidden = setup.hidePaletteButton { hidePaletteButton = hidden }
        titlebarPetEnabled = setup.companionEnabled; titlebarCompanion = setup.companion; captureLinks = setup.captureLinks; quiet = setup.quiet
    }
}

struct DownloadHistoryRecord: Codable {
    var id: UUID
    var accountId: UUID
    var accountName: String
    var provider: String
    var path: String
    var status: String
    var received: Int64
    var total: Int64
    var started: Int64
    static func load(_ url: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw SetupError.invalid("Download history is too large.") }
        let records = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        var seen = Set<UUID>()
        return Array(records.filter { !$0.accountName.isEmpty && $0.path.hasPrefix("/") && seen.insert($0.id).inserted }.sorted { $0.started > $1.started }.prefix(200))
    }
    static func save(_ records: [Self], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(records.prefix(200))).write(to: url, options: .atomic)
    }
}
