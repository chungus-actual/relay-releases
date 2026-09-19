import SwiftUI
import WebKit

@MainActor
final class RelayStore: ObservableObject {
    @Published var preferences = Preferences()
    @Published var error: String?
    @Published var localPage = "activity"
    @Published var editingAccount: Account?
    @Published var removingAccount: Account?
    @Published private(set) var erasingProfile: UUID?
    let downloads = DownloadCenter()
    let unread = UnreadCenter()
    let media: MediaCenter
    let notifications = RelayNotifications()
    let resources = ResourceMonitor()
    let updates = RelayUpdates()
    private(set) var services: [Service] = []
    private var sessions: [UUID: BrowserSession] = [:]
    var loadedSessions: [BrowserSession] { Array(sessions.values) }
    private var canSave = false
    let accountDragScope = AccountDragScope()
    var openMainWindow: (() -> Void)?
    private var shellCheckStarted = false
    private let shellCheck = ProcessInfo.processInfo.arguments.contains("--shell-check")
    private let file = PreferencesFile(url: URL.applicationSupportDirectory
        .appending(path: "Relay/macOS/settings.json"))

    init(mediaPreview: ActiveMedia? = nil) {
        media = MediaCenter(preview: mediaPreview)
        do {
            guard let catalog = Bundle.main.url(forResource: "services", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: catalog))
            if ProcessInfo.processInfo.arguments.contains("--snapshot-directory") || shellCheck {
                canSave = shellCheck
                preferences.initializeCatalog(services)
                return
            }
            preferences = try file.load()
            preferences.initializeCatalog(services)
            try file.save(preferences)
            canSave = true
            resources.start()
            resources.rendererNames = { [weak self] in
                var result: [Int32: Set<String>] = [:]
                for session in self?.sessions.values ?? Dictionary<UUID, BrowserSession>().values {
                    for page in session.chromium?.pages.values ?? Dictionary<Int, ChromiumSession.PageState>().values where page.pid > 0 {
                        result[page.pid, default: []].insert(session.accountName)
                    }
                }
                return result
            }
            notifications.configure()
            notifications.shouldPresent = { [weak self] id in
                guard let self else { return false }
                let viewing = NSApp.isActive && self.activeSession?.contentView.window?.isKeyWindow == true ? self.preferences.selected : nil
                return self.preferences.shouldNotify(id, viewing: viewing)
            }
            notifications.openAccount = { [weak self] id in
                guard let self, let account = self.preferences.accounts.first(where: { $0.id == id }) else { return }
                self.select(account)
                self.openMainWindow?()
            }
            notifications.activateNotification = { [weak self] account, id in
                self?.sessions[account]?.chromium?.command("notification", ["id": id, "click": true])
            }
            unread.onActivity = { [weak self] entry in
                guard let self else { return }
                let viewing = NSApp.isActive && self.activeSession?.contentView.window?.isKeyWindow == true ? self.preferences.selected : nil
                guard self.preferences.shouldNotify(entry.accountID, viewing: viewing),
                      let account = self.preferences.accounts.first(where: { $0.id == entry.accountID }) else { return }
                self.notifications.post(entry, account: account)
            }
            unread.onBadgeChanged = { NSApp.dockTile.badgeLabel = $0 }
            if preferences.selected != nil { localPage = "service" }
            for account in preferences.accounts where account.enabled == true { _ = session(for: account.id) }
        } catch {
            self.error = "Could not load Relay: \(error.localizedDescription). Existing settings have been preserved."
        }
    }

    @discardableResult
    private func change(_ edit: (inout Preferences) throws -> Void) -> Bool {
        guard canSave else { return false }
        do {
            var next = preferences
            try edit(&next)
            guard next != preferences else { return true }
            if !shellCheck { try file.save(next) }
            preferences = next
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func runShellCheck() {
        guard shellCheck, !shellCheckStarted else { return }
        shellCheckStarted = true
        resources.start()
        Task { @MainActor in
            func stage(_ text: String) { print(text); fflush(stdout) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            var publications = 0
            let observation = objectWillChange.sink { publications += 1 }
            menuBarEnabled = menuBarEnabled
            appearance = appearance
            observation.cancel()
            guard publications == 0 else { stage("FAIL: unchanged settings republished state"); exit(1) }
            stage("Unchanged settings produced no updates")
            for index in 0..<4 {
                stage("Opening fixture service \(index)")
                select(preferences.accounts[index])
                try? await Task.sleep(nanoseconds: 500_000_000)
                stage("Opening Settings \(index)")
                showLocal("settings")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                stage("Settings responsive \(index)")
                quiet.toggle()
                setAudioMuted(preferences.accounts[index], muted: index % 2 == 0)
                menuBarEnabled.toggle()
                appearance.compact.toggle()
                appearance.topTabs.toggle()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let account = preferences.accounts[0]
            remove(account)
            showLocal("settings")
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let removed = preferences.removedAccounts?.first(where: { $0.id == account.id }) else {
                stage("FAIL: removed account not available for restoration"); exit(1)
            }
            restore(removed)
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard preferences.accounts.contains(where: { $0.id == account.id }), !isLoaded(account) else {
                stage("FAIL: restored account must stay unloaded"); exit(1)
            }
            remove(account)
            if let entry = preferences.removedAccounts?.first(where: { $0.id == account.id }) {
                await eraseProfile(entry)
            }
            guard preferences.removedAccounts?.contains(where: { $0.id == account.id }) != true else {
                stage("FAIL: profile deletion did not clear fixture metadata"); exit(1)
            }
            guard resources.memory != nil, resources.cpu != nil else {
                stage("FAIL: shell resource sampling unavailable"); exit(1)
            }
            stage("PASS: live service/Settings transitions and layout changes, account restoration/deletion metadata")
            NSApp.terminate(nil)
        }
    }

    var menuBarEnabled: Bool {
        get { !ProcessInfo.processInfo.arguments.contains("--snapshot-directory") && preferences.menuBarEnabled != false }
        set { if menuBarEnabled != newValue { _ = change { $0.menuBarEnabled = newValue } } }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled { guard await notifications.requestPermission() else { return } }
        guard change({ $0.notificationsEnabled = enabled }) else { return }
        if !enabled { notifications.clearAll() }
        sessions.values.forEach { $0.pageControls.refreshPermission() }
    }

    var captureLinks: Bool {
        get { preferences.captureLinks == true }
        set {
            guard captureLinks != newValue, change({ $0.captureLinks = newValue }) else { return }
            sessions.values.forEach { $0.captureLinks = newValue }
        }
    }
    var closeToMenuBar: Bool {
        get { preferences.closeToMenuBar != false }
        set { if closeToMenuBar != newValue { _ = change { $0.closeToMenuBar = newValue } } }
    }

    var quiet: Bool {
        get { preferences.quiet == true }
        set {
            guard quiet != newValue, change({ $0.quiet = newValue }) else { return }
            if newValue { notifications.clearAll() }
        }
    }

    func setAudioMuted(_ account: Account, muted: Bool) {
        guard change({ settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            settings.accounts[index].audioMuted = muted
        }) else { return }
        sessions[account.id]?.setMuted(muted)
    }

    func setKeepLive(_ account: Account, enabled: Bool) {
        guard change({ settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            settings.accounts[index].keepLive = enabled
        }) else { return }
        sessions[account.id]?.setKeepLive(enabled)
    }

    func setGmailAllUnread(_ account: Account, enabled: Bool) {
        guard account.serviceID == "gmail", change({ settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            settings.accounts[index].gmailAllUnread = enabled
        }) else { return }
        unread.setGmailMode(for: account.id, allUnread: enabled)
        notifications.clear(account.id)
    }

    func setAccountNotifications(_ account: Account, enabled: Bool) {
        guard change({ settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            settings.accounts[index].notifications = enabled
        }) else { return }
        if !enabled { notifications.clear(account.id) }
        sessions[account.id]?.pageControls.refreshPermission()
    }

    func add(_ service: Service) {
        if change({ settings in
            let account = try settings.addAccount(service: service)
            settings.setLoaded(account.id, true, select: true)
        }) { localPage = "service" }
    }

    var shortcutAccounts: [Account] {
        preferences.accounts.filter { !(preferences.hiddenAccountIDs ?? []).contains($0.id) }
    }

    var hiddenAccounts: [Account] {
        preferences.accounts.filter { (preferences.hiddenAccountIDs ?? []).contains($0.id) }
    }

    func reveal(_ account: Account) {
        guard preferences.accounts.contains(where: { $0.id == account.id }) else { return }
        if change({ settings in
            settings.setVisible(account.id, true)
            settings.setLoaded(account.id, true, select: true)
        }), localPage != "service" { localPage = "service" }
    }

    func isVisible(_ account: Account) -> Bool { !(preferences.hiddenAccountIDs ?? []).contains(account.id) }
    func setVisible(_ account: Account, _ visible: Bool) { _ = change { $0.setVisible(account.id, visible) } }
    func move(_ account: Account, by offset: Int) { _ = change { $0.moveAccount(account.id, by: offset) } }

    func reorder(_ payloads: [String], relativeTo target: Account, after: Bool) -> Bool {
        guard let id = accountDragScope.account(from: payloads) else { return false }
        var candidate = preferences
        guard candidate.moveAccount(id, relativeTo: target.id, after: after) else { return false }
        return change { $0 = candidate }
    }

    func rename(_ account: Account, to name: String) -> Bool {
        guard change({ try $0.renameAccount(account.id, to: name) }) else { return false }
        sessions[account.id]?.accountName = preferences.accounts.first { $0.id == account.id }?.name ?? account.name
        return true
    }

    func remove(_ account: Account) {
        guard !downloads.hasActiveDownloads(account.id) else {
            error = "Finish or cancel this account's downloads before removing it."
            return
        }
        guard change({ $0.removeAccount(account.id) }) else { return }
        notifications.clear(account.id)
        media.unregister(account.id)
        sessions.removeValue(forKey: account.id)?.close()
        unread.forget(account.id, removeActivity: true)
        if preferences.selected == nil && localPage == "service" { localPage = "activity" }
    }

    func restore(_ entry: RemovedAccount) {
        guard erasingProfile != entry.id else { return }
        guard services.contains(where: { $0.id == entry.account.serviceID }) else {
            error = "This account's service is no longer in the catalog."
            return
        }
        _ = change { try $0.restoreAccount(entry.id) }
    }

    func eraseProfile(_ entry: RemovedAccount) async {
        guard erasingProfile == nil, !preferences.accounts.contains(where: { $0.id == entry.id }),
              preferences.removedAccounts?.contains(where: { $0.id == entry.id }) == true else { return }
        // Record intent first: an interrupted deletion must never appear restorable.
        guard change({ _ = $0.markProfileDeletion(entry.id, pending: true) }) else { return }
        erasingProfile = entry.id
        defer { erasingProfile = nil }
        do {
            if !shellCheck {
                try await ProfileStorage.erase(entry.id)
            }
            if !change({ $0.finishProfileDeletion(entry.id) }) {
                error = "The website data was deleted, but settings could not be updated. Retry deletion to clear the remaining entry."
            }
        } catch {
            self.error = "Could not delete the website profile: \(error.localizedDescription)"
        }
    }

    func unload(_ account: Account) {
        guard !downloads.hasActiveDownloads(account.id) else {
            error = "Finish or cancel this account's downloads before unloading it."
            return
        }
        let wasSelected = preferences.selected == account.id
        guard change({ $0.setLoaded(account.id, false) }) else { return }
        if wasSelected { localPage = "activity" }
        objectWillChange.send()
        notifications.clear(account.id)
        media.unregister(account.id)
        sessions.removeValue(forKey: account.id)?.close()
        unread.forget(account.id, removeActivity: false)
    }

    var zoomAccount: Account? {
        guard localPage == "service" else { return nil }
        return preferences.accounts.first { $0.id == preferences.selected }
    }

    func setZoom(_ account: Account, to value: Double) {
        let zoom = Account.normalizedZoom(value)
        guard change({ settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            settings.accounts[index].pageZoom = zoom
        }) else { return }
        sessions[account.id]?.setZoom(zoom)
    }

    func setBrowserEngine(_ account: Account, chromium: Bool) {
        guard account.usesChromium != chromium else { return }
        guard !downloads.hasActiveDownloads(account.id) else { error = "Finish or cancel this account's downloads first."; return }
        guard !chromium || ChromiumRuntime.isEnabled else { error = "Chromium is only available in experimental development builds."; return }
        guard change({ preferences in
            guard let index = preferences.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            preferences.accounts[index].browserEngine = chromium ? "chromium" : nil
        }) else { return }
        notifications.clear(account.id)
        media.unregister(account.id)
        let wasLoaded = sessions[account.id] != nil
        sessions.removeValue(forKey: account.id)?.close()
        unread.forget(account.id, removeActivity: false)
        if wasLoaded { _ = session(for: account.id) }
        objectWillChange.send()
    }

    func changeSelectedZoom(by delta: Double, reset: Bool = false) {
        guard let account = zoomAccount else { return }
        setZoom(account, to: reset ? 1 : account.zoom + delta)
    }

    func isLoaded(_ account: Account) -> Bool { sessions[account.id] != nil }

    var appearance: AppearancePreferences {
        get { preferences.appearance ?? AppearancePreferences() }
        set {
            guard appearance != newValue else { return }
            if ProcessInfo.processInfo.arguments.contains("--snapshot-directory") { preferences.appearance = newValue }
            else { _ = change { $0.appearance = newValue } }
        }
    }

    func showLocal(_ page: String) {
        if change({ $0.selected = nil }), localPage != page { localPage = page }
    }

    func select(_ account: Account) {
        if change({ $0.setLoaded(account.id, true, select: true) }), localPage != "service" { localPage = "service" }
    }

    func openActivity(_ activity: UnreadActivity, account: Account) {
        select(account)
        if let token = activity.notificationID { sessions[account.id]?.chromium?.command("notification", ["id": token, "click": true]) }
    }

    var activeSession: BrowserSession? {
        guard localPage == "service", let id = preferences.selected else { return nil }
        return sessions[id]
    }

    func selectAdjacent(forward: Bool) {
        guard let account = preferences.adjacentShortcut(to: localPage == "service" ? preferences.selected : nil,
                                                        forward: forward) else { return }
        select(account)
    }

    func session(for id: UUID) -> BrowserSession? {
        if let session = sessions[id] { return session }
        guard var account = preferences.accounts.first(where: { $0.id == id }),
              let service = services.first(where: { $0.id == account.serviceID }) else { return nil }
        let snapshot = ProcessInfo.processInfo.arguments.contains("--snapshot-directory") || shellCheck
        let chromiumCheck = shellCheck && ProcessInfo.processInfo.arguments.contains("--chromium")
        if chromiumCheck { account.browserEngine = "chromium" }
        let session = BrowserSession(account: account, service: service, downloads: downloads,
                                     dataStore: snapshot && !chromiumCheck ? .nonPersistent() : nil,
                                     loadImmediately: !snapshot, chromiumTesting: chromiumCheck)
        session.captureLinks = captureLinks
        if snapshot {
            let html = "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"></head><body>Service preview</body></html>"
            if chromiumCheck {
                guard let chromium = session.chromium else { print("FAIL: Chromium fixture could not start: \(session.error ?? "unknown")"); exit(1) }
                chromium.command("html", ["html": html, "url": service.url.absoluteString])
            } else { session.webView.loadHTMLString(html, baseURL: service.url) }
        }
        session.pageControls.notificationsAllowed = { [weak self] in
            guard let self else { return false }
            return self.preferences.notificationsEnabled == true &&
                self.preferences.accounts.contains { $0.id == id && $0.notifications != false }
        }
        session.pageControls.onNotification = { [weak self] title, body in
            guard let self else { return }
            self.unread.recordNotification(for: id, summary: title + (body.isEmpty ? "" : ": " + body))
        }
        session.onNativeNotification = { [weak self] token, title, body in
            self?.unread.recordNotification(for: id, summary: title + (body.isEmpty ? "" : ": " + body), notificationID: token)
        }
        session.onUnread = { [weak self] reading in
            guard let self else { return }
            if account.serviceID == "gmail" {
                let all = self.preferences.accounts.first { $0.id == id }?.gmailAllUnread == true
                self.unread.receiveGmail(reading, for: id, allUnread: all)
            } else { self.unread.receive(reading, for: id) }
        }
        session.onNavigationChanged = { [weak self] in
            guard let self, self.preferences.selected == id else { return }
            self.objectWillChange.send()
        }
        sessions[id] = session
        if !snapshot { media.register(session) }
        return session
    }
}

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(SnapshotDelegate.self) private var delegate
    @StateObject private var store = RelayStore()
    var body: some Scene {
        Window("Relay", id: "main") {
            ContentView(store: store).onAppear { delegate.closeToMenuBar = { [weak store = store] in store?.closeToMenuBar ?? true } }
        }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1180, height: 800)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Relay") { AppIdentity.showAbout() }
                    UpdateMenu(updates: store.updates)
                }
                CommandMenu("Services") {
                    Button("Activity") { store.showLocal("activity") }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Menu("Hidden accounts") {
                        ForEach(store.hiddenAccounts) { account in
                            Button(account.name) { store.reveal(account) }
                        }
                    }.disabled(store.hiddenAccounts.isEmpty)
                    Button("Next Service") { store.selectAdjacent(forward: true) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .disabled(store.shortcutAccounts.isEmpty)
                    Button("Previous Service") { store.selectAdjacent(forward: false) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        .disabled(store.shortcutAccounts.isEmpty)
                    Divider()
                    ForEach(Array(store.shortcutAccounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                        Button(account.name) { store.select(account) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                }
                CommandMenu("Page") {
                    Button("Back") { store.activeSession?.goBack() }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(store.activeSession?.canGoBack != true)
                    Button("Forward") { store.activeSession?.goForward() }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(store.activeSession?.canGoForward != true)
                    Button("Reload") { store.activeSession?.reload() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(store.zoomAccount == nil)
                    Button("Service Home") {
                        if let session = store.activeSession { session.load(session.service.url) }
                    }.disabled(store.zoomAccount == nil)
                    Divider()
                    Button("Zoom In") { store.changeSelectedZoom(by: 0.1) }
                        .keyboardShortcut("=", modifiers: .command)
                        .disabled(store.zoomAccount == nil || (store.zoomAccount?.zoom ?? 1) >= 2)
                    Button("Zoom Out") { store.changeSelectedZoom(by: -0.1) }
                        .keyboardShortcut("-", modifiers: .command)
                        .disabled(store.zoomAccount == nil || (store.zoomAccount?.zoom ?? 1) <= 0.5)
                    Button("Actual Size") { store.changeSelectedZoom(by: 0, reset: true) }
                        .keyboardShortcut("0", modifiers: .command)
                        .disabled(store.zoomAccount == nil)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { store.showLocal("settings") }.keyboardShortcut(",")
                }
            }
        MenuBarExtra(isInserted: $store.menuBarEnabled) {
            RelayMenuBar(store: store)
        } label: {
            Image(nsImage: RelayMenuBarIcon.image).accessibilityLabel("Relay")
        }.menuBarExtraStyle(.menu)
    }
}
