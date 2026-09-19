import Foundation

struct Service: Decodable, Identifiable {
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
        if Self.authenticationHosts.contains(host) { return true }
        if ["gmail", "calendar", "googlemessages", "googlekeep"].contains(id) {
            return ["mail.google.com", "calendar.google.com", "messages.google.com", "keep.google.com"].contains(host)
        }
        if id == "youtubemusic" { return host == "music.youtube.com" }
        return contains(url)
    }

    func allowsMediaPermissionRequest(origin: URL, page: URL?) -> Bool {
        guard let page,
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
    var hiddenAccountIDs: [UUID]?
    var notificationsEnabled: Bool?
    var quiet: Bool?
    var captureLinks: Bool?
    var closeToMenuBar: Bool?
    var menuBarEnabled: Bool?
    var removedAccounts: [RemovedAccount]?

    func shouldNotify(_ accountID: UUID, viewing activeAccountID: UUID?) -> Bool {
        notificationsEnabled == true && quiet != true && activeAccountID != accountID &&
            accounts.contains { $0.id == accountID && $0.notifications != false }
    }

    mutating func initializeCatalog(_ services: [Service]) {
        guard catalogInitialized != true else { return }
        for service in services where !accounts.contains(where: { $0.serviceID == service.id }) &&
            !(removedAccounts ?? []).contains(where: { $0.account.serviceID == service.id }) {
            accounts.append(Account(id: UUID(), serviceID: service.id, name: service.name))
        }
        catalogInitialized = true
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
        hiddenAccountIDs?.removeAll { $0 == id }
        if selected == id { selected = nil }
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
        if loaded && select { selected = id }
        if !loaded && selected == id { selected = nil }
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
