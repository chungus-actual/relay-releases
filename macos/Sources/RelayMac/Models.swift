import Foundation

struct Service: Decodable, Identifiable {
    static let terminal = Service(id: "terminal", name: "Terminal", url: URL(string: "relay-terminal://local/index.html")!, glyph: ">_", hosts: [])
    var isTerminal: Bool { id == "terminal" }
    let id: String
    let name: String
    let url: URL
    let glyph: String
    let hosts: [String]
    private static let authenticationHosts = ["accounts.google.com", "accounts.youtube.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com"]

    func contains(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func allowsEmbedded(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if BrowserRules.googleSignIn(url) || Self.authenticationHosts.contains(host) { return true }
        if ["gmail", "calendar", "googlemessages", "googlekeep"].contains(id) {
            return ["mail.google.com", "calendar.google.com", "messages.google.com", "keep.google.com"].contains(host)
        }
        if id == "youtube" { return ["www.youtube.com", "youtube.com", "m.youtube.com", "youtu.be", "consent.youtube.com"].contains(host) }
        if id == "youtubemusic" { return host == "music.youtube.com" }
        return contains(url)
    }

    func allowsMediaPermissionRequest(origin: URL, page: URL?) -> Bool {
        guard let page, !BrowserRules.googleSignIn(origin), !BrowserRules.googleSignIn(page),
              !Self.authenticationHosts.contains(origin.host?.lowercased() ?? ""),
              !Self.authenticationHosts.contains(page.host?.lowercased() ?? "") else { return false }
        // Authentication hosts may be embedded but do not inherit call permissions.
        return contains(origin) && allowsEmbedded(origin) && contains(page) && allowsEmbedded(page)
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id: UUID
    var serviceID: String
    var name: String
    var pageZoom: Double?
    var enabled: Bool?
    var keepLive: Bool?
    var notifications: Bool?
    var audioMuted: Bool?
    var gmailAllUnread: Bool?
    var browserEngine: String?
    var identityColor: String?
    var snoozedUntil: Int64?
    var usesChromium: Bool { browserEngine == "chromium" }

    var staysAwake: Bool { keepLive ?? (serviceID != "googlekeep") }
    var zoom: Double { Self.normalizedZoom(pageZoom ?? 1) }
    static func normalizedZoom(_ value: Double) -> Double {
        value.isFinite ? min(2, max(0.5, (value * 100).rounded() / 100)) : 1
    }
}

struct AppearancePreferences: Codable, Equatable {
    var mode = "Dark"
    var surface = "Graphite"
    var accent = "Mint"
    var compact = false
    var topTabs = false
}

struct RemovedAccount: Codable, Equatable, Identifiable {
    var account: Account
    let position: Int
    let wasVisible: Bool
    var deletionPending: Bool?
    var id: UUID { account.id }
}

struct Preferences: Codable, Equatable {
    var accounts: [Account] = []
    var selected: UUID?
    var appearance: AppearancePreferences?
    var catalogInitialized: Bool?
    var catalogServiceIDs: [String]?
    var hiddenAccountIDs: [UUID]?
    var notificationsEnabled: Bool?
    var quiet: Bool?
    var captureLinks: Bool?
    var inlinePredictionsEnabled: Bool?
    var closeToMenuBar: Bool?
    var menuBarEnabled: Bool?
    var removedAccounts: [RemovedAccount]?
    var workspace: WorkspaceLayout?
    var hideLayoutButton: Bool?
    var hidePaletteButton: Bool?
    var titlebarPetEnabled: Bool?
    var titlebarCompanion: String?
    var savedWorkspaces: [SavedWorkspace]?
    var bookmarks: [AccountBookmark]?
    var snoozedUntil: Int64?

    func shouldNotify(_ accountID: UUID, viewing activeAccountID: UUID?, now: Date = Date()) -> Bool {
        notificationsEnabled == true && quiet != true && activeAccountID != accountID &&
            !Productivity.snoozed(snoozedUntil, now: now) &&
            accounts.contains { $0.id == accountID && $0.notifications != false && !Productivity.snoozed($0.snoozedUntil, now: now) }
    }

    mutating func initializeCatalog(_ services: [Service]) {
        // Migrate the pre-YouTube catalog once; thereafter track introduced providers.
        let known = Set(catalogServiceIDs ?? (catalogInitialized == true ? services.filter { $0.id != "youtube" }.map(\.id) : []))
        for service in services where !known.contains(service.id) && !accounts.contains(where: { $0.serviceID == service.id }) &&
            !(removedAccounts ?? []).contains(where: { $0.account.serviceID == service.id }) {
            accounts.append(Account(id: UUID(), serviceID: service.id, name: service.name))
        }
        catalogInitialized = true
        catalogServiceIDs = services.map(\.id)
    }

    mutating func addAccount(service: Service, name: String? = nil) throws -> Account {
        var candidate = name ?? service.name
        if name == nil {
            var suffix = 2
            while accounts.contains(where: { $0.serviceID == service.id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                candidate = "\(service.name) \(suffix)"
                suffix += 1
            }
        }
        let account = Account(id: UUID(), serviceID: service.id,
                              name: try validatedName(candidate, serviceID: service.id))
        accounts.append(account)
        return account
    }

    func validatedName(_ value: String, serviceID: String, excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw AccountError.invalidName }
        guard !accounts.contains(where: { $0.id != id && $0.serviceID == serviceID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AccountError.duplicateName
        }
        return name
    }

    mutating func renameAccount(_ id: UUID, to value: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = try validatedName(value, serviceID: accounts[index].serviceID, excluding: id)
    }

    mutating func removeAccount(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = accounts[index]
        account.enabled = false
        var removed = removedAccounts ?? []
        removed.removeAll { $0.id == id }
        removed.append(RemovedAccount(account: account, position: index,
                                      wasVisible: !(hiddenAccountIDs ?? []).contains(id)))
        removedAccounts = removed
        accounts.removeAll { $0.id == id }
        bookmarks?.removeAll { $0.accountId == id }
        for i in (savedWorkspaces ?? []).indices {
            savedWorkspaces?[i].layout.remove(id)
            let remainingPane = savedWorkspaces?[i].layout.panes.first
            if savedWorkspaces?[i].focused == id { savedWorkspaces?[i].focused = remainingPane }
        }
        savedWorkspaces?.removeAll { $0.layout.panes.isEmpty }
        hiddenAccountIDs?.removeAll { $0 == id }
        workspace?.remove(id)
        if selected == id { selected = workspace?.panes.first }
    }

    mutating func restoreAccount(_ id: UUID) throws {
        guard let entry = removedAccounts?.first(where: { $0.id == id }),
              entry.deletionPending != true,
              !accounts.contains(where: { $0.id == id }) else { return }
        var account = entry.account
        var name = account.name
        var suffixNumber = 1
        while accounts.contains(where: { $0.serviceID == account.serviceID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let suffix = suffixNumber == 1 ? " (restored)" : " (restored \(suffixNumber))"
            name = String(account.name.prefix(max(0, 80 - suffix.count))) + suffix
            suffixNumber += 1
        }
        account.name = try validatedName(name, serviceID: account.serviceID)
        account.enabled = false
        accounts.insert(account, at: min(max(0, entry.position), accounts.count))
        setVisible(id, entry.wasVisible)
        removedAccounts?.removeAll { $0.id == id }
    }

    @discardableResult
    mutating func markProfileDeletion(_ id: UUID, pending: Bool) -> Bool {
        guard !accounts.contains(where: { $0.id == id }),
              let index = removedAccounts?.firstIndex(where: { $0.id == id }) else { return false }
        removedAccounts?[index].deletionPending = pending
        return true
    }

    mutating func finishProfileDeletion(_ id: UUID) {
        guard !accounts.contains(where: { $0.id == id }),
              removedAccounts?.contains(where: { $0.id == id && $0.deletionPending == true }) == true else { return }
        removedAccounts?.removeAll { $0.id == id }
    }

    mutating func setLoaded(_ id: UUID, _ loaded: Bool, select: Bool = false) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].enabled = loaded
        if loaded && select {
            var layout = workspace ?? WorkspaceLayout()
            layout.select(id, active: selected)
            workspace = layout
            selected = id
        }
        if !loaded {
            workspace?.remove(id)
            if selected == id { selected = workspace?.panes.first }
        }
    }

    mutating func setVisible(_ id: UUID, _ visible: Bool) {
        var hidden = Set(hiddenAccountIDs ?? [])
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        hiddenAccountIDs = Array(hidden)
    }

    mutating func moveAccount(_ id: UUID, by offset: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts.indices.contains(index + offset) else { return }
        accounts.swapAt(index, index + offset)
    }

    func adjacentShortcut(to current: UUID?, forward: Bool) -> Account? {
        let visible = accounts.filter { !(hiddenAccountIDs ?? []).contains($0.id) }
        guard !visible.isEmpty else { return nil }
        guard let index = visible.firstIndex(where: { $0.id == current }) else {
            return forward ? visible.first : visible.last
        }
        return visible[(index + (forward ? 1 : visible.count - 1)) % visible.count]
    }

    @discardableResult
    mutating func moveAccount(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let source = accounts.firstIndex(where: { $0.id == id }),
              accounts.contains(where: { $0.id == target }) else { return false }
        var reordered = accounts
        let account = reordered.remove(at: source)
        guard let destination = reordered.firstIndex(where: { $0.id == target }) else { return false }
        reordered.insert(account, at: destination + (after ? 1 : 0))
        guard reordered != accounts else { return false }
        accounts = reordered
        return true
    }
}

// Drag payloads are scoped to this running store. Unrelated text and drags from
// other instances cannot move accounts, even when they contain an account UUID.
struct AccountDragScope {
    private let id = UUID()
    func payload(for account: UUID) -> String { "relay-account:\(id):\(account)" }
    func account(from payloads: [String]) -> UUID? {
        guard payloads.count == 1 else { return nil }
        let prefix = "relay-account:\(id):"
        guard payloads[0].hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payloads[0].dropFirst(prefix.count)))
    }
}

struct RendererRecovery {
    private var failures = 0
    private var lastFailure: Date?
    mutating func nextDelay(at now: Date) -> TimeInterval? {
        if let previous = lastFailure, now.timeIntervalSince(previous) >= 120 { failures = 0 }
        lastFailure = now
        failures += 1
        let delays: [TimeInterval] = [1, 3, 10]
        return failures <= delays.count ? delays[failures - 1] : nil
    }
}

enum AccountError: LocalizedError {
    case invalidName, duplicateName
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter an account name between 1 and 80 characters."
        case .duplicateName: return "That service already has an account with this name."
        }
    }
}

struct PreferencesFile {
    let url: URL

    func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
    }

    func save(_ preferences: Preferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
    }
}

// Normalized top-left coordinates are identical for WebKit, Chromium and WebView2.
struct WorkspaceLayout: Codable, Equatable {
    var panes: [UUID] = []
    var arrangement = "grid"
    var primary = 0.5
    var cuts: [Double] = []
    static let arrangements = ["columns", "rows", "grid", "main-left", "main-top"]
    static let labels = ["Side by side", "Stacked", "Grid", "Main on left", "Main on top"]
    struct Cell: Equatable { let x, y, width, height: Double }
    struct Divider: Equatable { let index: Int; let vertical: Bool; let position, start, length: Double }

    mutating func normalize(available: [UUID]) {
        let known = Set(available)
        var seen = Set<UUID>()
        panes = Array(panes.filter { known.contains($0) && seen.insert($0).inserted }.prefix(4))
        if !Self.arrangements.contains(arrangement) { arrangement = "grid" }
        normalizeSizes()
    }
    mutating func normalizeSizes() {
        primary = primary.isFinite ? min(0.85, max(0.15, primary)) : 0.5
        let segments = ["columns", "rows"].contains(arrangement) ? panes.count : arrangement == "grid" ? (panes.count > 2 ? 2 : 1) : max(1, panes.count - 1)
        let expected = max(0, segments - 1)
        if cuts.count != expected || cuts.enumerated().contains(where: { i, v in !v.isFinite || v + 0.000000001 < (i == 0 ? 0 : cuts[i - 1]) + 0.1 || v > 0.9 }) {
            cuts = (0..<expected).map { Double($0 + 1) / Double(segments) }
        }
    }
    mutating func select(_ id: UUID, active: UUID?) {
        guard !panes.contains(id) else { return }
        if panes.isEmpty { panes.append(id) }
        else { panes[active.flatMap { panes.firstIndex(of: $0) } ?? 0] = id }
        normalizeSizes()
    }
    @discardableResult mutating func add(_ id: UUID) -> Bool {
        guard panes.count < 4, !panes.contains(id) else { return false }
        panes.append(id); normalizeSizes(); return true
    }
    mutating func remove(_ id: UUID) { panes.removeAll { $0 == id }; normalizeSizes() }
    private func edge(_ index: Int) -> Double { index == 0 ? 0 : index > cuts.count ? 1 : cuts[index - 1] }
    func cell(_ index: Int) -> Cell {
        let count = panes.count
        if count <= 1 { return Cell(x: 0, y: 0, width: 1, height: 1) }
        let start = edge(index), length = edge(index + 1) - start
        if arrangement == "columns" { return Cell(x: start, y: 0, width: length, height: 1) }
        if arrangement == "rows" { return Cell(x: 0, y: start, width: 1, height: length) }
        if arrangement == "main-left" { return index == 0 ? Cell(x: 0, y: 0, width: primary, height: 1) : Cell(x: primary, y: edge(index - 1), width: 1 - primary, height: edge(index) - edge(index - 1)) }
        if arrangement == "main-top" { return index == 0 ? Cell(x: 0, y: 0, width: 1, height: primary) : Cell(x: edge(index - 1), y: primary, width: edge(index) - edge(index - 1), height: 1 - primary) }
        let y = index < 2 ? 0 : cuts[0], height = count == 2 ? 1 : index < 2 ? cuts[0] : 1 - cuts[0]
        return count == 3 && index == 2 ? Cell(x: 0, y: y, width: 1, height: height) : Cell(x: index % 2 == 0 ? 0 : primary, y: y, width: index % 2 == 0 ? primary : 1 - primary, height: height)
    }
    func dividers() -> [Divider] {
        guard panes.count > 1 else { return [] }
        if ["columns", "rows"].contains(arrangement) { return cuts.enumerated().map { Divider(index: $0.offset, vertical: arrangement == "columns", position: $0.element, start: 0, length: 1) } }
        let vertical = arrangement != "main-top"
        return [Divider(index: -1, vertical: vertical, position: primary, start: 0, length: arrangement == "grid" && panes.count == 3 ? cuts[0] : 1)] + cuts.enumerated().map { Divider(index: $0.offset, vertical: !vertical, position: $0.element, start: arrangement == "grid" ? 0 : primary, length: arrangement == "grid" ? 1 : 1 - primary) }
    }
    mutating func resize(_ divider: Int, position: Double) {
        normalizeSizes()
        guard position.isFinite else { return }
        if divider == -1 { primary = min(0.85, max(0.15, position)) }
        else if cuts.indices.contains(divider) { cuts[divider] = min(edge(divider + 2) - 0.1, max(edge(divider) + 0.1, position)) }
    }
}
