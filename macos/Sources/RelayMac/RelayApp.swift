import SwiftUI
import WebKit

@MainActor
final class RelayStore: ObservableObject {
    @Published var preferences = Preferences()
    @Published var error: String?
    @Published var localPage = "activity"
    @Published private(set) var workspaceTransition = 0
    @Published var editingAccount: Account?
    @Published var palettePresented = false
    var paletteSelection: (() -> Void)?
    @Published var workspaceDraft: SavedWorkspace?
    @Published var bookmarkDraft: AccountBookmark?
    var lastFocusedAccount: UUID?
    @Published var bugReport: BugReportDraft?
    func reportProblem(account: Account? = nil) {
        guard bugReport == nil else { return }
        let target = account ?? preferences.accounts.first { $0.id == preferences.selected }
        bugReport = BugReportDraft(store: self, session: target.flatMap { sessions[$0.id] }, account: target)
    }
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
    // WebKit copies this setting when a view is created. Keep every account and
    // popup on the launch value until restart, preserving open documents/drafts.
    private var launchedInlinePredictionsEnabled = false
    let accountDragScope = AccountDragScope()
    var openMainWindow: (() -> Void)?
    private var shellCheckStarted = false
    private var shellCheckTerminalHome: URL?
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
            services.append(.terminal)
            if ProcessInfo.processInfo.arguments.contains("--snapshot-directory") || shellCheck {
                canSave = shellCheck
                preferences.initializeCatalog(services)
                return
            }
            preferences = try file.load()
            downloads.configureHistory(URL.applicationSupportDirectory.appending(path: "Relay/macOS/downloads.json"))
            launchedInlinePredictionsEnabled = preferences.inlinePredictionsEnabled == true
            preferences.initializeCatalog(services)
            var layout = preferences.workspace ?? WorkspaceLayout()
            layout.normalize(available: preferences.accounts.filter { $0.enabled == true }.map(\.id))
            if let id = preferences.selected, preferences.accounts.contains(where: { $0.id == id && $0.enabled == true }) { layout.select(id, active: nil) }
            else { preferences.selected = nil }
            preferences.workspace = layout
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
                let viewing = self.focusedAccountID
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
                let viewing = self.focusedAccountID
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
    func change(_ edit: (inout Preferences) throws -> Void) -> Bool {
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
            inlinePredictionsEnabled = inlinePredictionsEnabled
            appearance = appearance
            observation.cancel()
            guard publications == 0 else { stage("FAIL: unchanged settings republished state"); exit(1) }
            stage("Unchanged settings produced no updates")
            let originalAppearance = appearance
            let originalAppAppearance = NSApp.appearance
            for mode in ["Light", "Dark"] {
                NSApp.appearance = NSAppearance(named: mode == "Light" ? .darkAqua : .aqua)
                appearance = AppearancePreferences(mode: mode)
                palettePresented = true
                try? await Task.sleep(for: .milliseconds(500))
                let expected: NSAppearance.Name = mode == "Light" ? .aqua : .darkAqua
                guard let sheet = NSApp.windows.first(where: { $0.sheetParent != nil && $0.isVisible }),
                      sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected else {
                    stage("FAIL: \(mode) palette sheet did not inherit Relay's appearance"); exit(1)
                }
                palettePresented = false
                try? await Task.sleep(for: .milliseconds(350))
                guard !NSApp.windows.contains(where: { $0.sheetParent != nil && $0.isVisible }) else {
                    stage("FAIL: dismissed palette sheet remained visible"); exit(1)
                }
            }
            appearance = originalAppearance
            NSApp.appearance = originalAppAppearance
            stage("PASS: palette sheets follow Relay's light/dark appearance independently of the system")
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
            guard let retained = sessions[account.id] else { stage("FAIL: prediction fixture missing session"); exit(1) }
            inlinePredictionsEnabled = true
            inlinePredictionsEnabled = true
            guard inlinePredictionsRestartRequired, sessions[account.id] === retained,
                  !retained.webView.configuration.allowsInlinePredictions else {
                stage("FAIL: pending prediction setting replaced or changed a live session"); exit(1)
            }
            guard let unloaded = preferences.accounts.first(where: { sessions[$0.id] == nil }),
                  let opened = session(for: unloaded.id), !opened.webView.configuration.allowsInlinePredictions else {
                stage("FAIL: new service missing or applied prediction setting before restart"); exit(1)
            }
            inlinePredictionsEnabled = false
            guard !inlinePredictionsRestartRequired, sessions[account.id] === retained else {
                stage("FAIL: reverting prediction choice did not clear pending restart"); exit(1)
            }
            stage("PASS: prediction changes wait for restart and preserve live sessions")
            guard let messenger = preferences.accounts.first(where: { $0.serviceID == "messenger" }),
                  let other = preferences.accounts.first(where: { $0.serviceID != "messenger" }) else {
                stage("FAIL: Messenger workspace fixtures missing"); exit(1)
            }
            soloPane(messenger)
            addPane(other)
            _ = session(for: messenger.id)
            guard preferences.selected == other.id, canRefreshMessengerDisplay(messenger),
                  !canRefreshMessengerDisplay(other) else {
                stage("FAIL: visible Messenger pane requires focus for display refresh"); exit(1)
            }
            showLocal("settings")
            guard !canRefreshMessengerDisplay(messenger) else {
                stage("FAIL: hidden Messenger pane allows display refresh"); exit(1)
            }
            select(other)
            closePane(messenger)
            guard !canRefreshMessengerDisplay(messenger) else {
                stage("FAIL: closed Messenger pane allows display refresh"); exit(1)
            }
            stage("PASS: Messenger refresh follows pane visibility, not focus")
            let saved = SavedWorkspace(name: "Shell fixture", layout: workspace, focused: preferences.selected)
            let retainedWorkspaceSessions = loadedSessions
            guard saveWorkspace(saved) else { stage("FAIL: workspace could not be saved"); exit(1) }
            showLocal("settings"); openWorkspace(saved)
            guard localPage == "service", preferences.selected == saved.focused,
                  retainedWorkspaceSessions.allSatisfy({ old in loadedSessions.contains { $0 === old } }) else {
                stage("FAIL: opening saved workspace replaced a retained browser"); exit(1)
            }
            snooze(other, until: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970))
            guard Productivity.snoozed(preferences.accounts.first { $0.id == other.id }?.snoozedUntil) else { stage("FAIL: account snooze did not persist"); exit(1) }
            snooze(other, until: nil); deleteWorkspace(saved)
            stage("PASS: saved workspace lifecycle retains sessions; account snooze clears")
            showLocal("library"); editBookmark()
            guard var bookmark = bookmarkDraft else { stage("FAIL: library cannot start a bookmark without a selected pane"); exit(1) }
            bookmark.accountId = other.id; bookmark.name = "Library fixture"; bookmark.url = bookmarkAddress(other)
            guard saveBookmark(bookmark), preferences.bookmarks?.contains(where: { $0.id == bookmark.id && $0.accountId == other.id }) == true else {
                stage("FAIL: library bookmark lost its selected account"); exit(1)
            }
            bookmark.name = "Renamed library fixture"
            guard saveBookmark(bookmark), preferences.bookmarks?.filter({ $0.id == bookmark.id }).count == 1 else {
                stage("FAIL: editing a bookmark duplicated its identity"); exit(1)
            }
            deleteBookmark(bookmark); deleteBookmark(bookmark); bookmarkDraft = nil
            setPaletteButtonHidden(true); setPaletteButtonHidden(true)
            guard paletteButtonHidden, retainedWorkspaceSessions.allSatisfy({ old in loadedSessions.contains { $0 === old } }) else {
                stage("FAIL: hiding the palette launcher changed retained sessions"); exit(1)
            }
            setPaletteButtonHidden(false)
            guard !paletteButtonHidden, preferences.bookmarks?.contains(where: { $0.id == bookmark.id }) != true else {
                stage("FAIL: palette visibility or bookmark deletion did not clear"); exit(1)
            }
            stage("PASS: library bookmark create/edit/delete and palette visibility preserve account sessions")
            unread.receive(UnreadReading(count: 7, attention: false, key: "setup-fixture"), for: other.id)
            let beforeImportBadge = unread.badge(for: other.id)
            var importedPreferences = preferences
            if let index = importedPreferences.accounts.firstIndex(where: { $0.id == other.id }) { importedPreferences.accounts[index].identityColor = "Rose" }
            guard applyImportedPreferences(importedPreferences), unread.badge(for: other.id) == beforeImportBadge,
                  retainedWorkspaceSessions.allSatisfy({ old in loadedSessions.contains { $0 === old } }) else {
                stage("FAIL: setup import replaced a profile or cleared unrelated unread state"); exit(1)
            }
            stage("PASS: setup import preserves sessions and unrelated unread state")
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
            if let local = preferences.accounts.first(where: { $0.serviceID == "terminal" }) {
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-shell-terminal-" + UUID().uuidString)
                try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                shellCheckTerminalHome = home
                defer { try? FileManager.default.removeItem(at: home); shellCheckTerminalHome = nil }
                select(local)
                guard let native = session(for: local.id), let terminal = native.terminal else {
                    stage("FAIL: Terminal account did not create a native terminal session"); exit(1)
                }
                native.load(Service.terminal.url)
                for _ in 0..<80 {
                    if terminal.workspace.current?.panes.first?.process != nil { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let process = terminal.workspace.current?.panes.first?.process else {
                    stage("FAIL: bundled terminal page did not start its PTY: \(native.error ?? "no readiness")"); exit(1)
                }
                terminal.onCloseView?()
                guard !workspace.panes.contains(local.id), session(for: local.id) === native else {
                    stage("FAIL: Close terminal view did not retain its account session"); exit(1)
                }
                select(local); popOutService(local)
                guard native.serviceWindow != nil, !workspace.panes.contains(local.id) else {
                    stage("FAIL: Terminal pop-out did not release its Relay pane"); exit(1)
                }
                terminal.onCloseView?()
                guard native.serviceWindow == nil, workspace.panes.contains(local.id), terminal.workspace.current?.panes.first?.process === process else {
                    stage("FAIL: Terminal docking did not restore the retained shell"); exit(1)
                }
                unload(local)
                guard terminal.workspace.tabs.isEmpty, !loadedSessions.contains(where: { $0 === native }) else {
                    stage("FAIL: Terminal unload did not dispose its workspace"); exit(1)
                }
                stage("PASS: bundled Terminal selection, close/reopen, pop-out/dock and unload retain or end the correct shells")
            }
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

    var inlinePredictionsEnabled: Bool {
        get { preferences.inlinePredictionsEnabled == true }
        set { if inlinePredictionsEnabled != newValue { _ = change { $0.inlinePredictionsEnabled = newValue } } }
    }
    var inlinePredictionsRestartRequired: Bool {
        inlinePredictionsEnabled != launchedInlinePredictionsEnabled
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
        if wasSelected && preferences.selected == nil { localPage = "activity" }
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
        if let id = preferences.selected { lastFocusedAccount = id }
        if change({ $0.selected = nil }), localPage != page { localPage = page }
    }

    func popOutService(_ account: Account) {
        guard isLoaded(account), let session = sessions[account.id] else { return }
        if session.showServiceWindow() { return }
        media.dock(account: account.id)
        session.popOutService { [weak self] in
            guard let self, let current = self.preferences.accounts.first(where: { $0.id == account.id && $0.enabled == true }) else { return }
            self.openMainWindow?(); self.select(current)
        }
        if session.serviceWindow != nil { closePane(account) }
    }

    func select(_ account: Account) {
        if !workspace.panes.contains(account.id), sessions[account.id]?.showServiceWindow() == true { return }
        for id in workspace.panes { sessions[id]?.dockServiceWindow(select: false) }
        if change({ $0.setLoaded(account.id, true, select: true) }), localPage != "service" { localPage = "service" }
    }

    func focusPane(_ account: Account) {
        guard localPage == "service", preferences.selected != account.id,
              paneAccounts.contains(where: { $0.id == account.id }) else { return }
        _ = change { $0.selected = account.id }
    }

    var titlebarCompanion: String {
        get { PetMotion.normalizedKind(preferences.titlebarCompanion ?? "puke") }
        set { _ = change { $0.titlebarCompanion = PetMotion.normalizedKind(newValue) } }
    }
    var titlebarPetEnabled: Bool {
        get { preferences.titlebarPetEnabled == true }
        set { _ = change { $0.titlebarPetEnabled = newValue } }
    }

    var layoutButtonHidden: Bool { preferences.hideLayoutButton == true }
    var paletteButtonHidden: Bool { preferences.hidePaletteButton == true }
    func setPaletteButtonHidden(_ hidden: Bool) { _ = change { $0.hidePaletteButton = hidden } }
    func setLayoutButtonHidden(_ hidden: Bool) { _ = change { $0.hideLayoutButton = hidden } }

    var workspace: WorkspaceLayout { preferences.workspace ?? WorkspaceLayout() }
    var paneAccounts: [Account] {
        workspace.panes.compactMap { id in preferences.accounts.first { $0.id == id && $0.enabled == true } }
    }
    var visibleSessions: [BrowserSession] {
        guard localPage == "service" else { return [] }
        return paneAccounts.compactMap { session(for: $0.id) }
    }
    func canRefreshMessengerDisplay(_ account: Account) -> Bool {
        localPage == "service" && account.serviceID == "messenger" &&
            paneAccounts.contains(where: { $0.id == account.id }) && sessions[account.id] != nil
    }
    func addPane(_ account: Account) {
        sessions[account.id]?.dockServiceWindow(select: false)
        guard preferences.accounts.contains(where: { $0.id == account.id }) else { return }
        var layout = workspace
        guard layout.add(account.id) else { return }
        if change({ $0.workspace = layout; $0.setLoaded(account.id, true, select: true) }) { localPage = "service" }
    }
    func closePane(_ account: Account) {
        guard change({ settings in
            settings.workspace?.remove(account.id)
            if settings.selected == account.id { settings.selected = settings.workspace?.panes.first }
        }) else { return }
        if preferences.selected == nil { localPage = "activity" }
    }
    func soloPane(_ account: Account) {
        sessions[account.id]?.dockServiceWindow(select: false)
        if change({ settings in
            var layout = settings.workspace ?? WorkspaceLayout()
            layout.panes = [account.id]; layout.normalizeSizes()
            settings.workspace = layout; settings.setLoaded(account.id, true, select: true)
        }) { localPage = "service" }
    }
    func movePane(_ account: Account, by offset: Int) {
        if change({ settings in
            guard var layout = settings.workspace, let index = layout.panes.firstIndex(of: account.id), layout.panes.indices.contains(index + offset) else { return }
            layout.panes.swapAt(index, index + offset); settings.workspace = layout
        }) { workspaceTransition &+= 1 }
    }
    func arrangePanes(_ arrangement: String) {
        guard WorkspaceLayout.arrangements.contains(arrangement) else { return }
        if change({ settings in
            var layout = settings.workspace ?? WorkspaceLayout()
            layout.arrangement = arrangement; layout.primary = arrangement.hasPrefix("main-") ? 0.6 : 0.5; layout.cuts = []; layout.normalizeSizes(); settings.workspace = layout
        }) { workspaceTransition &+= 1 }
    }
    func resetPaneSizes() {
        if change({ settings in
            var layout = settings.workspace ?? WorkspaceLayout()
            layout.primary = layout.arrangement.hasPrefix("main-") ? 0.6 : 0.5; layout.cuts = []; layout.normalizeSizes(); settings.workspace = layout
        }) { workspaceTransition &+= 1 }
    }
    func resizePane(_ divider: Int, position: Double, finished: Bool) {
        var layout = workspace
        layout.resize(divider, position: position)
        // Publish live geometry without writing settings on every mouse movement.
        if layout != workspace { preferences.workspace = layout }
        if finished && canSave && !shellCheck {
            do { try file.save(preferences) } catch { self.error = error.localizedDescription }
        }
    }

    func openActivity(_ activity: UnreadActivity, account: Account) {
        select(account)
        if let token = activity.notificationID { sessions[account.id]?.chromium?.command("notification", ["id": token, "click": true]) }
    }

    private var focusedAccountID: UUID? {
        guard NSApp.isActive else { return nil }
        if let activeSession, activeSession.contentView.window?.isKeyWindow == true,
           !activeSession.contentView.isHiddenOrHasHiddenAncestor { return activeSession.accountID }
        return sessions.values.first { $0.contentView.window is RetainedBrowserPanel && $0.contentView.window?.isKeyWindow == true }?.accountID
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
                                     loadImmediately: !snapshot, chromiumTesting: chromiumCheck,
                                     inlinePredictionsEnabled: launchedInlinePredictionsEnabled,
                                     terminalShell: shellCheck ? "/bin/sh" : nil,
                                     terminalHome: shellCheckTerminalHome?.path ?? NSHomeDirectory())
        session.captureLinks = captureLinks
        session.terminal?.onCloseView = { [weak self, weak session] in
            guard let self, let session else { return }
            if session.serviceWindow != nil { session.dockServiceWindow() }
            else { self.closePane(account) }
        }
        session.terminal?.onFocus = { [weak self] in self?.focusPane(account) }
        if snapshot && !service.isTerminal {
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
                    Button("Find your way…") { store.palettePresented = true }.keyboardShortcut("k", modifiers: .command)
                    Button("Workspaces & bookmarks") { store.showLocal("library") }
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
                CommandGroup(replacing: .help) {
                    Button("Report a problem…") { store.reportProblem() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("Refresh Messenger display") {
                        Task { await store.activeSession?.refreshMessengerDisplay() }
                    }.disabled(store.activeSession?.service.id != "messenger")
                }
            }
        MenuBarExtra(isInserted: $store.menuBarEnabled) {
            RelayMenuBar(store: store)
        } label: {
            Image(nsImage: RelayMenuBarIcon.image).accessibilityLabel("Relay")
        }.menuBarExtraStyle(.menu)
    }
}
