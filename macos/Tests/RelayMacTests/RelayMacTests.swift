import Foundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Check failed",
                   file: StaticString = #file, line: UInt = #line) rethrows {
    if try !condition() { fatalError(message, file: file, line: line) }
}

@main
struct RelayMacTests {
    @MainActor static func main() throws {
        let tests = RelayMacTests()
        tests.testHostBoundariesAndSchemes()
        try tests.testMediaPermissions()
        tests.testGoogleLinksDoNotCaptureSearch()
        try tests.testGoogleSessionHandoffs()
        try tests.testAccountIdentifiersSurviveRestart()
        try tests.testBrowserEngineMigration()
        try tests.testZoomPersistence()
        try tests.testSharedCatalog()
        try tests.testWorkspaceLayout()
        try tests.testProductivity()
        try tests.testTerminalCatalogAndExports()
        try tests.testYouTube()
        tests.testPetMotion()
        tests.testPetWardrobeAndGrooming()
        try tests.testAppearanceMigration()
        try tests.testAccountManagement()
        try tests.testRemovedAccountRestoration()
        try tests.testDragReordering()
        tests.testAccountCycling()
        tests.testRendererRecovery()
        try tests.testLoadedAccounts()
        try tests.testNotificationPreferences()
        try tests.testInlinePredictionPreferences()
        try tests.testMediaScriptParity()
        try tests.testDownloadDestination()
        tests.testBrowserRules()
        tests.testUnreadState()
        try tests.testGmailUnreadModes()
        try tests.testMessengerScriptParity()
        try tests.testBugReport()
        print("Passed: routing/permissions, account/notification preferences, ordering/zoom, recovery, downloads, Windows unread/media script parity")
    }
    private let service = Service(id: "messenger", name: "Messenger",
        url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M",
        hosts: ["facebook.com", "messenger.com"])

    func testTerminalCatalogAndExports() throws {
        let terminal = Service.terminal
        check(terminal.isTerminal && !terminal.contains(URL(string: "https://relay-terminal.invalid/")!), "Native terminal never grants a web origin shell privileges")
        check(!MediaBridge.supports(terminal.id), "Terminal accounts do not participate in browser media polling")
        var settings = Preferences(); settings.initializeCatalog([service, terminal]); settings.initializeCatalog([service, terminal])
        check(settings.accounts.count == 2, "Terminal catalog initialization is idempotent")
        let web = settings.accounts.first { $0.serviceID == service.id }!, local = settings.accounts.first { $0.serviceID == "terminal" }!
        settings.savedWorkspaces = [SavedWorkspace(name: "Web", layout: WorkspaceLayout(panes: [web.id]), focused: web.id),
                                    SavedWorkspace(name: "Local", layout: WorkspaceLayout(panes: [web.id, local.id]), focused: local.id)]
        let exported = settings.exportSetup()
        check(exported.accounts.count == 1 && exported.workspaces.count == 1 && exported.workspaces[0].name == "Web", "Native terminal accounts and mixed layouts stay out of portable exports on both platforms")
        _ = try PortableSetup.decode(exported.encode(), services: [service])
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(restored.accounts == settings.accounts, "Terminal account identities survive application restart")
    }

    func testProductivity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: root.appendingPathComponent("services.json")))
        let fixture = try Data(contentsOf: root.appendingPathComponent("Assets/Fixtures/relay-setup-v1.json"))
        let setup = try PortableSetup.decode(fixture, services: services)
        check(setup.hidePaletteButton == true, "Shared setup fixture carries palette visibility")
        var p = Preferences(); try p.mergeSetup(setup, services: services)
        let first = p; try p.mergeSetup(setup, services: services)
        check(p == first, "Repeated setup imports preserve account IDs and do not duplicate saved places")
        let work = p.accounts.first { $0.name == "Work" }!
        check(p.bookmarks?.first?.accountId == work.id && p.savedWorkspaces?.first?.focused == work.id && work.enabled != true && work.identityColor == "Sky", "Portable references map to new unloaded local profiles")
        var pruned = p; pruned.removeAccount(work.id)
        check(pruned.bookmarks?.isEmpty == true && pruned.savedWorkspaces?.first?.layout.panes.count == 1 && pruned.savedWorkspaces?.first?.focused == pruned.savedWorkspaces?.first?.layout.panes.first,
              "Removing a saved account clears its bookmarks and moves workspace focus to the remaining pane")
        let decoded = try PortableSetup.decode(p.exportSetup().encode(), services: services)
        check(p.hidePaletteButton == true && decoded.hidePaletteButton == true, "Hidden palette button survives setup import and export")
        var legacy = setup; legacy.hidePaletteButton = nil
        var legacyPreferences = p; try legacyPreferences.mergeSetup(legacy, services: services)
        check(legacyPreferences.hidePaletteButton == true, "Older setup files preserve palette visibility")
        legacy.hidePaletteButton = false; try legacyPreferences.mergeSetup(legacy, services: services)
        check(legacyPreferences.hidePaletteButton == false, "Setup import can restore the palette button")
        check(decoded.accounts.count == 2 && decoded.workspaces.count == 1 && decoded.bookmarks.count == 1, "Cross-platform setup round trips")
        let text = String(decoding: fixture, as: UTF8.self)
        for invalid in ["{}", text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 99"),
            text.replacingOccurrences(of: "https://web.whatsapp.com/", with: "javascript:alert(1)"),
            text.replacingOccurrences(of: "https://web.whatsapp.com/", with: "https://whatsapp.com.evil.test/"),
            text.replacingOccurrences(of: "https://web.whatsapp.com/", with: "https://user:password@web.whatsapp.com/"),
            text.replacingOccurrences(of: "\"accountId\": \"work\"", with: "\"accountId\": \"missing\"")] {
            do { _ = try PortableSetup.decode(Data(invalid.utf8), services: services); check(false, "Invalid setup accepted") } catch {}
        }
        let now = Date(timeIntervalSince1970: 1_000)
        p.notificationsEnabled = true; p.accounts[0].notifications = true
        let id = p.accounts[0].id
        p.snoozedUntil = 1_001
        check(!p.shouldNotify(id, viewing: nil, now: now), "Global snooze suppresses notifications")
        p.snoozedUntil = 1_000
        check(p.shouldNotify(id, viewing: nil, now: now), "Snooze expiry permits the next event")
        p.accounts[0].snoozedUntil = 1_001
        check(!p.shouldNotify(id, viewing: nil, now: now), "Per-account snooze remains effective after global expiry")
        p.accounts[0].snoozedUntil = nil; p.quiet = true
        check(!p.shouldNotify(id, viewing: nil, now: now), "Resuming a snooze does not disable quiet mode")
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        check(restored == p, "Saved places and snoozes survive restart")
        var active = p.savedWorkspaces![0].layout; active.resize(0, position: 0.72)
        check(p.savedWorkspaces![0].layout.cuts == [0.6], "Resizing current workspace leaves saved layout intact")
        p.removeAccount(work.id)
        check(p.bookmarks?.isEmpty == true && p.savedWorkspaces?.first?.layout.panes.count == 1, "Removing an account clears bookmarks and stale workspace panes")
        check(Productivity.matches("work chat", "Work chats", "Bookmark") && !Productivity.matches("work cat", "Work chats"), "Search requires all words")
        check(Productivity.paletteMatches("wapp", "WhatsApp") && !Productivity.paletteMatches("wppa", "WhatsApp"), "Fuzzy palette matching preserves character order")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved.txt"), history = directory.appendingPathComponent("downloads.json")
        try Data("keep".utf8).write(to: file)
        let record = DownloadHistoryRecord(id: UUID(), accountId: id, accountName: "Fixture", provider: "whatsapp", path: file.path, status: "Complete", received: 4, total: 4, started: 1)
        try DownloadHistoryRecord.save([record, record], to: history)
        try check(DownloadHistoryRecord.load(history).count == 1, "Restart history deduplicates transfers")
        try FileManager.default.removeItem(at: file)
        try check(DownloadHistoryRecord.load(history).first?.status == "Complete", "Missing files stay historical records")
        try DownloadHistoryRecord.save([], to: history)
        try check(DownloadHistoryRecord.load(history).isEmpty, "Cleared history stays empty after restart")
    }

    func testPetWardrobeAndGrooming() {
        for kind in PetMotion.kinds {
            var pet = PetMotion(kind: kind, random: { 0.69 })
            for outfit in 0..<4 { pet.setOutfit(outfit); check(pet.toyLabel("dress") == "Outfit", "Clothing category stays Outfit for every selection and companion") }
            pet.setOutfit(2); pet.setNookOpen(true); pet.act("groom"); pet.advance(0.25)
            let remaining = pet.remaining, position = pet.position
            pet.setOutfit(2); pet.setOutfit(-1); pet.setOutfit(4)
            check(pet.outfit == 2 && pet.remaining == remaining && pet.action == "groom", "Duplicate and invalid outfits preserve the reaction")
            var frames = Set<Int>()
            for _ in 0..<10 {
                pet.advance(0.25); frames.insert(pet.groomFrame)
                check(pet.position == position && !pet.walking && pet.velocity == 0 && pet.outfit == 2, "Grooming stays in place and keeps clothing")
            }
            check(frames == [0, 1] && pet.updateInterval() == (kind == "rock" ? 0.5 : 0.125), "Both grooming gestures use the existing gentle timer")
            pet.advance(1)
            check(pet.action == "idle" && pet.groomFrame == 0, "Grooming expires without leaving a stale gesture")
            pet.act("groom"); pet.advance(0.4); pet.act("feed")
            check(pet.action == "feed" && pet.groomFrame == 0, "New actions clear grooming immediately")
            pet.act("groom")
            for _ in 0..<4 { pet.advance(1, reducedMotion: true) }
            check(pet.action == "idle" && pet.position == position && !pet.walking && pet.updateInterval(reducedMotion: true) == 0.5, "Reduced motion keeps grooming still and expires")
            var groomed = false
            for _ in 0..<600 {
                pet.advance(1); groomed = groomed || pet.action == "groom"
                check(pet.outfit == 2, "Autonomous activities never change clothing")
            }
            check(kind == "rock" ? !groomed : groomed, "Only animals groom autonomously")
            for pose in PetArtwork.wardrobe.keys {
                check(PetArtwork.layers[pet.artworkLayer(pet.clothingLayer(pose)!)] != nil, "All resting and active poses have fitted clothing")
            }
        }
        var wardrobe = PetMotion(random: { 0.9 })
        wardrobe.setMusicPlaying(true); wardrobe.setNookOpen(true); wardrobe.setOutfit(2)
        wardrobe.selectKind("roof"); wardrobe.setOutfit(1)
        wardrobe.selectKind("rock"); wardrobe.setOutfit(3)
        wardrobe.selectKind("puke")
        check(wardrobe.outfit == 2 && wardrobe.musicPlaying && wardrobe.nookOpen, "Returning to Puke restores clothing while keeping music and the room")
        wardrobe.selectKind("roof"); check(wardrobe.outfit == 1, "Roof remembers his own outfit")
        wardrobe.selectKind("rock"); check(wardrobe.outfit == 3, "Rock remembers his own outfit")
        wardrobe = PetMotion(); wardrobe.selectKind("puke")
        check(wardrobe.outfit == 0 && wardrobe.groomFrame == 0, "Reset clears the session wardrobe and grooming state")
    }

    @MainActor func testBugReport() throws {
        for index in 0..<240 { ReportEvents.record("fixture", "event-\(index)") }
        let events = ReportEvents.snapshot
        check(events.components(separatedBy: "\n").count == 200 && !events.contains("event-0\n") && events.contains("event-239"), "Diagnostic events expire at the 200-event limit")
        var report = BugReport(description: "Rendering fixture 界", diagnostics: ["engine": "WebKit"], events: "messenger navigation-complete")
        let frozen = try report.encoded()
        report.description = "changed"
        let decoded = try JSONDecoder().decode(BugReport.self, from: frozen)
        check(decoded.description == "Rendering fixture 界" && decoded.screenshot == nil, "Retries freeze the payload; screenshots are opt-in")
        report.screenshot = "fixture-image"
        let attached = try report.encoded()
        report.screenshot = nil
        let cleared = try JSONDecoder().decode(BugReport.self, from: report.encoded())
        let submitted = try JSONDecoder().decode(BugReport.self, from: attached)
        check(cleared.screenshot == nil && submitted.screenshot == "fixture-image", "Removing an image clears future exports and preserves a frozen report")
        for invalid in [" ", String(repeating: "x", count: 8001), String(repeating: "👋", count: 4001)] {
            report.description = invalid
            check((try? report.encoded()) == nil, "Empty and oversized reports cannot be exported for intake")
        }
        check(BugReport.endpoint("https://reports.example.test/reports") != nil)
        for address in ["", "http://reports.example.test/", "https://user:secret@reports.example.test/", "https://reports.example.test/#fragment", "file:///tmp/report"] {
            check(BugReport.endpoint(address) == nil, "Reports require a credential-free HTTPS intake URL")
        }
    }

    func testWorkspaceLayout() throws {
        let ids = (0..<5).map { _ in UUID() }
        var layout = WorkspaceLayout(panes: [UUID(), ids[0], ids[0]] + Array(ids.dropFirst()), arrangement: "unknown", primary: .nan)
        layout.normalize(available: ids)
        check(layout.panes == Array(ids.prefix(4)) && layout.arrangement == "grid")
        check(!layout.add(ids[0]) && !layout.add(ids[4]), "Duplicate/fifth pane must be a no-op")
        layout.select(ids[4], active: ids[1])
        check(layout.panes == [ids[0], ids[4], ids[2], ids[3]])
        layout.select(ids[0], active: ids[4])
        check(layout.panes.count == 4 && layout.panes[1] == ids[4])
        for arrangement in WorkspaceLayout.arrangements {
            for count in 1...4 {
                layout = WorkspaceLayout(panes: Array(ids.prefix(count)), arrangement: arrangement)
                layout.normalizeSizes()
                for divider in layout.dividers() { layout.resize(divider.index, position: 0.72) }
                let cells = (0..<count).map { layout.cell($0) }
                check(abs(cells.reduce(0) { $0 + $1.width * $1.height } - 1) < 0.000001, "Resized panes must tile the workspace")
                for (i, a) in cells.enumerated() {
                    check(a.x >= 0 && a.y >= 0 && a.width > 0 && a.height > 0 && a.x + a.width <= 1.000001 && a.y + a.height <= 1.000001)
                    for b in cells.dropFirst(i + 1) {
                        check(min(a.x + a.width, b.x + b.width) <= max(a.x, b.x) + 0.000001 || min(a.y + a.height, b.y + b.height) <= max(a.y, b.y) + 0.000001, "Panes must not overlap")
                    }
                }
                for divider in layout.dividers() { layout.resize(divider.index, position: -100); layout.resize(divider.index, position: 100); layout.resize(divider.index, position: .nan) }
                check((0..<count).allSatisfy { layout.cell($0).width >= 0.099 && layout.cell($0).height >= 0.099 })
                let restored = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
                check(restored == layout, "Divider proportions and account order must persist")
            }
        }
        let accounts = ids.map { Account(id: $0, serviceID: "fixture", name: "Pane", enabled: true) }
        var settings = Preferences(accounts: accounts)
        settings.setLoaded(ids[0], true, select: true)
        check(settings.workspace?.panes == [ids[0]], "Legacy selection creates a single pane")
        settings.workspace?.add(ids[1]); settings.workspace?.add(ids[2])
        settings.setLoaded(ids[1], true, select: true)
        settings.setLoaded(ids[1], false)
        check(settings.selected == ids[0] && settings.workspace?.panes == [ids[0], ids[2]])
        settings.removeAccount(ids[2]); settings.removeAccount(ids[2])
        check(settings.workspace?.panes == [ids[0]], "Repeated removal must not retain stale pane IDs")
        settings.setLoaded(ids[0], false)
        check(settings.selected == nil && settings.workspace?.panes.isEmpty == true)
    }

    func testYouTube() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: root.appendingPathComponent("services.json")))
        let youtube = services.first { $0.id == "youtube" }!
        check(youtube.url.absoluteString == "https://www.youtube.com/" && MediaBridge.supports(youtube.id))
        for address in ["https://www.youtube.com/watch?v=fixture", "https://youtu.be/fixture", "https://accounts.google.com/signin", "https://consent.youtube.com/"] {
            check(youtube.allowsEmbedded(URL(string: address)!))
        }
        for address in ["https://music.youtube.com/", "https://youtube.com.evil.test/", "http://www.youtube.com/"] { check(!youtube.allowsEmbedded(URL(string: address)!)) }
        check(BrowserRules.googleHome("youtube") == youtube.url)
        check(UnreadRules.titleReading("(3) Video", service: youtube, url: youtube.url).count == nil)
        check(MediaBridge.script(for: "youtube").contains(".ytp-play-button"))
        let windows = try String(contentsOf: root.appendingPathComponent("windows/Sources/Relay/MediaControls.cs"), encoding: .utf8)
        check(windows.contains("is \"youtube\" or \"youtubemusic\""), "Both platforms must register YouTube media")
        var legacy = Preferences(catalogInitialized: true)
        legacy.initializeCatalog(services)
        check(legacy.accounts.filter { $0.serviceID == "youtube" }.count == 1)
        let account = legacy.accounts[0]
        check(account.enabled != true, "New catalog providers start unloaded")
        legacy.removeAccount(account.id); legacy.initializeCatalog(services)
        check(!legacy.accounts.contains { $0.serviceID == "youtube" }, "Catalog migration must not resurrect a removed account")
    }

    func testBrowserEngineMigration() throws {
        let id = UUID()
        let old = Data("{\"id\":\"\(id.uuidString)\",\"serviceID\":\"whatsapp\",\"name\":\"WhatsApp\"}".utf8)
        var account = try JSONDecoder().decode(Account.self, from: old)
        check(!account.usesChromium, "Existing accounts must retain WebKit")
        account.browserEngine = "chromium"
        let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        check(restored.usesChromium && restored.id == id, "Engine choice must retain account identity")
    }

    func testBrowserRules() {
        for host in ["scontent-ord5-2.xx.fbcdn.net", "cdn.fbsbx.com", "fbcdn.net"] {
            let attachment = URL(string: "https://\(host)/attachment")!
            check(BrowserRules.providerAttachment(attachment, service: "messenger"))
            check(!service.contains(attachment), "Attachment hosts must not inherit service permissions")
            check(!BrowserRules.providerAttachment(attachment, service: "gmail"))
        }
        for url in ["http://cdn.fbsbx.com/file", "https://fbcdn.net.evil.test/file", "https://notfbcdn.net/file", "https://example.com/file.pdf"] {
            check(!BrowserRules.providerAttachment(URL(string: url)!, service: "messenger"))
        }
        let wrapped = URL(string: "https://www.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Farticle")!
        check(BrowserRules.webLink(wrapped)?.absoluteString == "https://example.com/article")
        check(BrowserRules.webLink(URL(string: "javascript:alert(1)")!) == nil)
        check(BrowserRules.webLink(URL(string: "https://evil.test/url?q=https%3A%2F%2Fexample.com")!)?.host == "evil.test")
        for service in ["gmail", "calendar", "googlemessages", "googlekeep", "youtubemusic"] {
            let home = BrowserRules.googleHome(service)!
            check(BrowserRules.googleApp(home, service: service))
            check(!BrowserRules.googleApp(URL(string: "https://accounts.google.com/"), service: service))
            check(BrowserRules.googleLanding(URL(string: "https://accounts.google.com/"), service: service))
            check(!BrowserRules.googleLanding(URL(string: "https://accounts.google.com.evil.test/"), service: service))
        }
        check(!BrowserRules.googleApp(URL(string: "https://mail.google.com/mail-malicious/"), service: "gmail"))
        check(BrowserRules.googleApp(URL(string: "https://music.youtube.com/watch?v=fixture"), service: "youtubemusic"))
        check(!BrowserRules.googleApp(URL(string: "https://music.youtube.com.evil.test/"), service: "youtubemusic"))
        check(BrowserRules.googleLanding(URL(string: "https://www.youtube.com/signin"), service: "youtubemusic"))
    }

    func testInlinePredictionPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PreferencesFile(url: directory.appendingPathComponent("settings.json"))
        var settings = try JSONDecoder().decode(Preferences.self, from: Data("{\"accounts\":[],\"captureLinks\":true}".utf8))
        check(settings.inlinePredictionsEnabled != true, "Existing profiles retain WebKit's disabled default")
        let account = Account(id: UUID(), serviceID: "fixture", name: "Saved account", enabled: true)
        settings.accounts = [account]
        settings.selected = account.id
        for enabled in [true, false, true] {
            settings.inlinePredictionsEnabled = enabled
            try file.save(settings)
            let restored = try file.load()
            check(restored.inlinePredictionsEnabled == enabled, "Prediction choice must survive restarting Relay")
            check(restored.accounts == [account] && restored.selected == account.id && restored.captureLinks == true,
                  "Changing predictions must preserve accounts and other settings")
        }
    }

    func testNotificationPreferences() throws {
        let account = Account(id: UUID(), serviceID: "fixture", name: "Fixture")
        var settings = Preferences(accounts: [account])
        check(!settings.shouldNotify(account.id, viewing: nil), "Notifications are opt-in")
        settings.notificationsEnabled = true
        check(settings.shouldNotify(account.id, viewing: nil))
        settings.quiet = true
        check(!settings.shouldNotify(account.id, viewing: nil), "Quiet suppresses desktop notifications")
        settings.quiet = false
        check(settings.shouldNotify(account.id, viewing: nil), "Leaving Quiet restores notification policy")
        check(!settings.shouldNotify(account.id, viewing: account.id), "Visible account stays quiet")
        check(!settings.shouldNotify(UUID(), viewing: nil), "Removed accounts stay quiet")
        settings.accounts[0].notifications = false
        check(!settings.shouldNotify(account.id, viewing: nil))
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(restored.notificationsEnabled == true && restored.accounts[0].notifications == false)
    }

    func testLoadedAccounts() throws {
        let a = Account(id: UUID(), serviceID: "fixture", name: "First")
        let b = Account(id: UUID(), serviceID: "fixture", name: "Second")
        var settings = Preferences(accounts: [a, b])
        check(settings.accounts.allSatisfy { $0.enabled != true }, "New accounts start unloaded")
        settings.accounts[0].keepLive = false
        settings.setLoaded(a.id, true, select: true)
        settings.setLoaded(b.id, true, select: true)
        settings.setVisible(a.id, false)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(restored.accounts.allSatisfy { $0.enabled == true } && restored.selected == b.id)
        check(restored.accounts[0].keepLive == false && restored.accounts[1].keepLive == nil)
        settings.setLoaded(a.id, false)
        check(settings.selected == b.id && settings.accounts[0].enabled == false)
        settings.setLoaded(b.id, false)
        check(settings.selected == nil)
        check(settings.hiddenAccountIDs == [a.id], "Unload must retain shortcut visibility")
    }

    func testMediaScriptParity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("windows/Sources/Relay/MediaControls.cs"), encoding: .utf8)
        let start = source.range(of: "private const string MediaBridgeScript = ")!.upperBound
        let scriptStart = source[start...].firstIndex(of: "\n")!
        let end = source[scriptStart...].range(of: "\n        \"\"\";")!.lowerBound
        let windows = source[source.index(after: scriptStart)..<end].split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.dropFirst(8)) }.joined(separator: "\n")
        check(windows == MediaBridge.template, "Media bridge drifted from Windows")
        check(windows.contains("item.played.length") && windows.contains("item.muted || item.volume === 0"), "Both engines must exclude unplayed media and silent autoplay")
        check(MediaBridge.script(for: "youtube").contains("const provider = \"youtube\""))
        check(MediaBridge.script(for: "whatsapp").contains("const provider = \"whatsapp\""))
        check(MediaBridge.script(for: "spotify").contains("const provider = \"spotify\""))
    }

    func testRendererRecovery() {
        var recovery = RendererRecovery()
        let time = Date(timeIntervalSince1970: 1000)
        check(recovery.nextDelay(at: time) == 1)
        check(recovery.nextDelay(at: time.addingTimeInterval(2)) == 3)
        check(recovery.nextDelay(at: time.addingTimeInterval(7)) == 10)
        check(recovery.nextDelay(at: time.addingTimeInterval(20)) == nil)
        check(recovery.nextDelay(at: time.addingTimeInterval(25)) == nil)
        check(recovery.nextDelay(at: time.addingTimeInterval(150)) == 1, "Stable interval should restore the retry budget")
    }

    func testRemovedAccountRestoration() throws {
        let account = Account(id: UUID(), serviceID: service.id, name: "Personal", pageZoom: 1.25,
                              enabled: true, keepLive: false, notifications: false)
        let other = Account(id: UUID(), serviceID: service.id, name: "Other")
        var settings = Preferences(accounts: [other, account], selected: account.id,
                                   hiddenAccountIDs: [account.id])
        settings.removeAccount(account.id)
        check(settings.accounts == [other] && settings.selected == nil)
        check(settings.removedAccounts?.count == 1 && settings.removedAccounts?[0].account.enabled == false)
        settings.removeAccount(account.id)
        check(settings.removedAccounts?.count == 1, "Repeated removal must not duplicate the archive")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PreferencesFile(url: directory.appendingPathComponent("settings.json"))
        try file.save(settings)
        settings = try file.load()
        try settings.restoreAccount(account.id)
        check(settings.accounts.map(\.id) == [other.id, account.id], "Restore original profile UUID and position")
        let restored = settings.accounts[1]
        check(restored.enabled == false && restored.zoom == 1.25 && restored.keepLive == false && restored.notifications == false)
        check(settings.hiddenAccountIDs == [account.id] && settings.selected == nil)
        check(settings.removedAccounts?.isEmpty == true)
        settings.removeAccount(account.id)
        _ = try settings.addAccount(service: service, name: account.name)
        try settings.restoreAccount(account.id)
        check(settings.accounts.first { $0.id == account.id }?.name == "Personal (restored)")
        check(Set(settings.accounts.map(\.id)).count == settings.accounts.count)
        let count = settings.accounts.count
        try settings.restoreAccount(account.id)
        check(settings.accounts.count == count, "Repeated restore must be harmless")
        check(!settings.markProfileDeletion(account.id, pending: true), "Active profiles cannot be deleted")
        settings.removeAccount(account.id)
        check(settings.markProfileDeletion(account.id, pending: true))
        try file.save(settings)
        settings = try file.load()
        try settings.restoreAccount(account.id)
        check(!settings.accounts.contains { $0.id == account.id }, "Interrupted deletion must block restore")
        settings.finishProfileDeletion(account.id)
        check(settings.removedAccounts?.contains { $0.id == account.id } != true)
        check(settings.accounts.contains { $0.id == other.id }, "Deletion must leave unrelated accounts intact")
        var old = try JSONDecoder().decode(Preferences.self, from: Data("{\"accounts\":[]}".utf8))
        check(old.removedAccounts == nil, "Old preferences must migrate")
        old.accounts = [account]
        old.removeAccount(account.id)
        old.initializeCatalog([service])
        check(old.accounts.isEmpty, "Catalog initialization must respect removed accounts")
    }

    func testAccountCycling() {
        let accounts = (0..<3).map { Account(id: UUID(), serviceID: "fixture", name: "Account \($0)") }
        var settings = Preferences(accounts: accounts, hiddenAccountIDs: [accounts[1].id])
        check(settings.adjacentShortcut(to: accounts[0].id, forward: true)?.id == accounts[2].id)
        check(settings.adjacentShortcut(to: accounts[2].id, forward: true)?.id == accounts[0].id)
        check(settings.adjacentShortcut(to: accounts[0].id, forward: false)?.id == accounts[2].id)
        check(settings.adjacentShortcut(to: nil, forward: true)?.id == accounts[0].id)
        check(settings.adjacentShortcut(to: accounts[1].id, forward: false)?.id == accounts[2].id)
        settings.hiddenAccountIDs = accounts.map(\.id)
        check(settings.adjacentShortcut(to: nil, forward: true) == nil)
        check(Preferences().adjacentShortcut(to: nil, forward: false) == nil)
    }

    func testMediaPermissions() throws {
        let page = URL(string: "https://www.facebook.com/messages/")!
        check(service.allowsMediaPermissionRequest(origin: page, page: page))
        check(service.allowsMediaPermissionRequest(origin: URL(string: "https://www.messenger.com")!, page: page))
        for address in ["http://www.facebook.com", "https://facebook.com.evil.test", "https://accounts.google.com", "about:blank"] {
            let url = URL(string: address)!
            check(!service.allowsMediaPermissionRequest(origin: url, page: page))
            check(!service.allowsMediaPermissionRequest(origin: page, page: url))
        }
        check(!service.allowsMediaPermissionRequest(origin: page, page: nil))
        let gmail = Service(id: "gmail", name: "Gmail", url: URL(string: "https://mail.google.com")!, glyph: "G", hosts: ["google.com"])
        check(!gmail.allowsMediaPermissionRequest(origin: URL(string: "https://accounts.google.com")!, page: gmail.url))
        check(gmail.allowsMediaPermissionRequest(origin: gmail.url, page: gmail.url))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
        check(!(plist["NSCameraUsageDescription"] as? String ?? "").isEmpty)
        check(!(plist["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty)
    }

    func testHostBoundariesAndSchemes() {
        check(service.contains(URL(string: "https://www.facebook.com/messages/")!))
        check(service.contains(URL(string: "https://MESSENGER.COM/")!))
        for address in ["https://evilfacebook.com", "https://facebook.com.evil.test",
                        "http://facebook.com", "file:///facebook.com", "javascript:alert(1)"] {
            check(!service.contains(URL(string: address)!), address)
        }
        check(service.allowsEmbedded(URL(string: "https://accounts.google.com/login")!))
        check(!service.allowsEmbedded(URL(string: "https://accounts.google.com.evil.test")!))
    }

    func testGoogleSessionHandoffs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: root.appendingPathComponent("services.json")))
        for service in services where ["gmail", "calendar", "googlemessages", "googlekeep", "youtubemusic"].contains(service.id) {
            for address in ["https://accounts.google.com/signin", "https://accounts.youtube.com/accounts/SetSID", "https://www.youtube.com/signin?action_handle_signin=true", "https://youtube.com/signin/", "https://www.youtube.com/accounts/SetSID"] {
                let url = URL(string: address)!
                check(BrowserRules.googleSignIn(url))
                check(service.allowsEmbedded(url), "Google session handoff escaped the account profile")
                check(!service.allowsMediaPermissionRequest(origin: url, page: service.url))
                check(!service.allowsMediaPermissionRequest(origin: service.url, page: url))
            }
            for address in ["http://accounts.youtube.com/accounts/SetSID", "https://accounts.youtube.com.evil.test/accounts/SetSID", "https://www.youtube.com/watch?v=fixture", "http://www.youtube.com/signin", "https://www.youtube.com.evil.test/signin", "https://www.youtube.com/signin-evil"] {
                let url = URL(string: address)!
                check(!BrowserRules.googleSignIn(url))
                check(!service.allowsEmbedded(url))
            }
        }
    }

    func testGoogleLinksDoNotCaptureSearch() {
        let gmail = Service(id: "gmail", name: "Gmail", url: URL(string: "https://mail.google.com")!,
                            glyph: "G", hosts: ["google.com"])
        check(gmail.allowsEmbedded(URL(string: "https://mail.google.com/mail/u/0")!))
        check(!gmail.allowsEmbedded(URL(string: "https://www.google.com/search?q=relay")!))
    }

    func testAccountIdentifiersSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PreferencesFile(url: directory.appendingPathComponent("settings.json"))
        try check(file.load().accounts.isEmpty)
        let accounts = (1...2).map { Account(id: UUID(), serviceID: "messenger", name: "Account \($0)") }
        try file.save(Preferences(accounts: accounts, selected: accounts[1].id))
        let restored = try file.load()
        check(restored.accounts == accounts)
        check(restored.selected == accounts[1].id)
        check(restored.accounts[0].id != restored.accounts[1].id)
        try Data("invalid".utf8).write(to: file.url)
        do { _ = try file.load(); fatalError("Invalid settings were accepted") }
        catch is DecodingError { /* Expected: preserve the original file. */ }
        try check(String(contentsOf: file.url, encoding: .utf8) == "invalid")
    }

    func testDragReordering() throws {
        let accounts = (0..<4).map { Account(id: UUID(), serviceID: "messenger", name: "Account \($0)", pageZoom: 1.25) }
        var preferences = Preferences(accounts: accounts, selected: accounts[2].id,
                                      hiddenAccountIDs: [accounts[1].id])
        check(preferences.moveAccount(accounts[0].id, relativeTo: accounts[3].id, after: true))
        check(preferences.accounts.map(\.id) == [accounts[1], accounts[2], accounts[3], accounts[0]].map(\.id))
        check(preferences.moveAccount(accounts[0].id, relativeTo: accounts[2].id, after: false))
        check(preferences.accounts.map(\.id) == [accounts[1], accounts[0], accounts[2], accounts[3]].map(\.id))
        check(!preferences.moveAccount(accounts[0].id, relativeTo: accounts[2].id, after: false), "Adjacent no-op")
        check(!preferences.moveAccount(accounts[0].id, relativeTo: accounts[0].id, after: true), "Self drop")
        check(!preferences.moveAccount(UUID(), relativeTo: accounts[0].id, after: true), "Removed source")
        check(!preferences.moveAccount(accounts[0].id, relativeTo: UUID(), after: true), "Removed target")
        check(preferences.selected == accounts[2].id && preferences.hiddenAccountIDs == [accounts[1].id])
        check(preferences.accounts.allSatisfy { $0.zoom == 1.25 })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PreferencesFile(url: directory.appendingPathComponent("settings.json"))
        try file.save(preferences)
        let restored = try file.load()
        check(restored.accounts == preferences.accounts && restored.selected == preferences.selected)
        check(restored.hiddenAccountIDs == preferences.hiddenAccountIDs)
        let scope = AccountDragScope(), other = AccountDragScope()
        let payload = scope.payload(for: accounts[0].id)
        check(scope.account(from: [payload]) == accounts[0].id)
        check(other.account(from: [payload]) == nil, "Other app instance")
        check(scope.account(from: []) == nil && scope.account(from: [payload, payload]) == nil)
        check(scope.account(from: [accounts[0].id.uuidString]) == nil, "Unrelated text")
        check(scope.account(from: [payload + "extra"]) == nil, "Malformed payload")
    }

    func testZoomPersistence() throws {
        let id = UUID()
        let legacy = "{\"id\":\"\(id)\",\"serviceID\":\"messenger\",\"name\":\"Legacy\"}"
        var account = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        check(account.zoom == 1, "Existing accounts default to actual size")
        account.pageZoom = 1.35
        let other = Account(id: UUID(), serviceID: "messenger", name: "Other")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PreferencesFile(url: directory.appendingPathComponent("settings.json"))
        try file.save(Preferences(accounts: [account, other]))
        var restored = try file.load()
        check(restored.accounts[0].zoom == 1.35 && restored.accounts[1].zoom == 1, "Zoom persists per account")
        try restored.renameAccount(id, to: "Renamed")
        check(restored.accounts[0].zoom == 1.35)
        for (input, expected) in [(0.1, 0.5), (3.0, 2.0), (Double.infinity, 1.0), (Double.nan, 1.0), (1.20000001, 1.2)] {
            check(Account.normalizedZoom(input) == expected)
        }
    }

    func testSharedCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self,
            from: Data(contentsOf: root.appendingPathComponent("services.json")))
        check(!services.isEmpty)
        check(Set(services.map(\.id)).count == services.count)
        for service in services { check(service.contains(service.url), service.id) }
        let icons = try String(contentsOf: root.appendingPathComponent("Assets/ServiceIcons.xaml"), encoding: .utf8)
        for service in services { check(icons.contains("ServiceIcon.\(service.id)\""), "Missing shared icon: \(service.id)") }
        let discord = services.first { $0.id == "discord" }!
        check(discord.url.absoluteString == "https://discord.com/channels/@me")
        for address in [discord.url.absoluteString, "https://discord.com/login", "https://discord.com/channels/123/456"] {
            let url = URL(string: address)!
            check(discord.allowsEmbedded(url))
            check(discord.allowsMediaPermissionRequest(origin: url, page: discord.url))
        }
        for address in ["http://discord.com", "https://discord.com.evil.test", "https://notdiscord.com", "https://cdn.discordapp.com/file"] {
            let url = URL(string: address)!
            check(!discord.contains(url) && !discord.allowsEmbedded(url))
            check(!discord.allowsMediaPermissionRequest(origin: url, page: discord.url))
        }
        var preferences = Preferences()
        preferences.initializeCatalog(services)
        check(preferences.accounts.filter { $0.serviceID == "discord" }.count == 1)
        check(preferences.accounts.allSatisfy { $0.enabled != true })
        let first = preferences.accounts.first { $0.serviceID == "discord" }!
        let second = try preferences.addAccount(service: discord)
        check(first.id != second.id && second.name == "Discord 2")
        preferences.removeAccount(first.id)
        preferences.initializeCatalog(services)
        check(!preferences.accounts.contains { $0.id == first.id }, "Removed Discord account reappeared")
    }

    func testPetMotion() {
        for (hour, phase) in [(0, "night"), (5, "night"), (6, "dawn"), (7, "dawn"), (8, "day"), (17, "day"), (18, "dusk"), (19, "dusk"), (20, "night"), (23, "night")] {
            let light = PetDaylight(hour: hour)
            check(light.phase == phase && PetArtwork.layers[light.windowArtwork] != nil, "Local hours select a complete shared window scene")
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
        var west = utc; west.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        var east = utc; east.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        check(PetDaylight.at(instant, calendar: utc).phase == "day" && PetDaylight.at(instant, calendar: west).phase == "night" && PetDaylight.at(instant, calendar: east).phase == "dusk", "The room follows local time rather than UTC or the appearance setting")
        check(PetDaylight.at(instant.addingTimeInterval(-7*3600), calendar: utc).phase == "night", "Clock changes recompute the phase without advancing animation time")
        let bowlDog = PetMotion(kind: "roof")
        check(bowlDog.toyArtwork("feed") == "toyBowl" && bowlDog.toyArtwork("play") == "toyBone", "Roof eats from a bowl and keeps the bone for play")
        for kind in PetMotion.kinds {
            var actor = PetMotion(kind: kind, random: { 0.9 })
            actor.setNookOpen(true)
            for _ in 0..<29 { actor.advance(1, reducedMotion: true) }
            check(actor.musing != nil && (kind == "puke" ? actor.musingAuthor == "Marcus Aurelius" : actor.musingAuthor == actor.name), "Each companion uses its own sayings or an attributed philosopher")
            let saying = actor.musing, left = actor.musingRemaining
            actor.selectKind(kind.uppercased())
            check(actor.musing == saying && actor.musingRemaining == left, "Duplicate companion selection preserves speech and its expiry")
            actor.act("game"); actor.setMusicPlaying(true); actor.selectKind(kind == "rock" ? "roof" : "rock")
            check(actor.action == "idle" && actor.musing == nil && actor.musicPlaying && actor.nookOpen && actor.outfit == 0, "Switching replaces transient state while keeping playback and the open nook")
        }
        var stone = PetMotion(kind: "rock", random: { 0 })
        stone.setMusicPlaying(true); stone.setHovered(true, toward: 0)
        check(!stone.glancing && !stone.enjoyingMusic && stone.transition.isEmpty, "Rock ignores movement cues")
        for action in ["pet", "feed", "play", "dress", "highfive", "hide", "litter", "game", "groom"] {
            stone.act(action, target: 0.9)
            for _ in 0..<24 { stone.advance(0.25); check(stone.position == 0.5 && !stone.walking && stone.velocity == 0 && stone.updateInterval() == 0.5, "Every Rock activity stays still on the quiet timer") }
            check(stone.action == "idle", "Rock props expire, including the static box")
        }
        stone.setMusicPlaying(false)
        let rockOutfit = stone.outfit
        for _ in 0..<600 { stone.advance(1) }
        check(stone.action == "idle" && stone.outfit == rockOutfit && !stone.sleeping && stone.position == 0.5, "Ten idle minutes cannot make Rock wander or choose autonomous activities")
        var dog = PetMotion(kind: "roof", random: { 0 })
        dog.act("play", target: 0.8); dog.advance(0.5)
        check(dog.walking && dog.position > 0.5 && dog.artworkLayer("head") == "roofHead" && dog.toyArtwork("play") == "toyBone", "Roof fetches using dog artwork")
        dog.act("pet"); for _ in 0..<10 { dog.advance(1) }
        check(!dog.sleeping && dog.sitting && !dog.walking && dog.toyLabel("pet") == "Pet" && dog.toyLabel("litter") == "Walk", "Roof stays awake after an interaction and uses plain action labels")
        dog.selectKind("unknown")
        check(dog.kind == "puke" && dog.action == "idle", "Unknown companion values safely select Puke")
        check(!PetMotion(kind: "roof").toyActions.contains("hide") && PetMotion(kind: "roof").toyActions.contains("dig"), "Roof offers Dig instead of Box")
        var digger = PetMotion(kind: "roof", random: { 0.25 })
        digger.act("play", target: 0.9); digger.advance(0.5); digger.act("dig")
        let digPosition = digger.position
        var strokes = Set<Int>()
        for _ in 0..<32 {
            digger.advance(0.125); strokes.insert(digger.digPawOffset)
            check(digger.digging && !digger.walking && digger.position == digPosition && digger.updateInterval() == 0.125 && digger.boxOpacity == 0, "Digging stays planted and uses small strokes without a box")
        }
        check(strokes == Set([-1, 1]), "Digging alternates its forepaws")
        digger.advance(1)
        check(!digger.digging && digger.digPawOffset == 0 && digger.action == "idle", "Digging expires without leaving dirt or gestures")
        digger.act("hide"); digger.advance(0.5, reducedMotion: true)
        check(digger.digging && digger.position == digPosition && digger.updateInterval(reducedMotion: true) == 0.5, "Old dog box requests become stationary digging, including reduced motion")
        digger.act("feed")
        check(!digger.digging && digger.digPawOffset == 0, "A replacement activity clears digging immediately")
        digger = PetMotion(kind: "roof", random: { 0.25 })
        for _ in 0..<105 { digger.advance(1) }
        check(digger.digging && digger.boxOpacity == 0, "Roof's spontaneous activities choose digging instead of hiding")
        for reduced in [false, true] {
            var roof = PetMotion(kind: "roof", random: { 0.25 }), cat = PetMotion(random: { 0.25 })
            var roofNaps = 0, catNaps = 0
            for _ in 0..<2400 {
                roof.advance(0.25, reducedMotion: reduced); cat.advance(0.25, reducedMotion: reduced)
                if roof.sleeping { roofNaps += 1 }; if cat.sleeping { catNaps += 1 }
                check(roof.action != "hide", "Roof cannot choose a cat box activity")
            }
            check(roofNaps > 360 && roofNaps < 1200 && catNaps > 2040, "Ten minutes leave Roof mostly awake and Puke mostly asleep, with or without reduced motion")
        }
        var shortNap = PetMotion(kind: "roof", random: { 0 })
        for _ in 0..<41 { shortNap.advance(1) }
        check(!shortNap.sleeping && shortNap.transition.isEmpty && shortNap.updateInterval() == 0.5, "Roof watches quietly before getting sleepy")
        shortNap.advance(1)
        check(shortNap.transition == "yawn", "Roof yawns just before its later nap")
        shortNap.advance(1); shortNap.advance(0.5)
        check(shortNap.transition == "settle" && shortNap.settleProgress == 0, "Roof's settling animation uses its own sleep timing")
        shortNap.advance(1); shortNap.advance(0.5)
        check(shortNap.sleeping, "Roof starts a nap after forty-five quiet seconds")
        for _ in 0..<6 { shortNap.advance(1) }; shortNap.setNookOpen(true)
        for _ in 0..<23 { shortNap.advance(1) }
        let napSaying = shortNap.musing
        check(shortNap.sleeping && napSaying != nil, "A quiet nap may still include a musing")
        shortNap.advance(1)
        check(!shortNap.sleeping && shortNap.transition == "stretch" && shortNap.position == 0.5 && shortNap.musing == napSaying, "Roof wakes from a thirty-second nap without moving or clearing speech")
        var musicDog = PetMotion(kind: "roof", random: { 0.3 })
        for _ in 0..<45 { musicDog.advance(1) }; musicDog.setMusicPlaying(true)
        check(musicDog.enjoyingMusic && !musicDog.sleeping, "Roof is more likely than Puke to wake when music starts")
        musicDog.setMusicPlaying(true)
        check(musicDog.wakeRemaining == 1.2, "Duplicate music readings do not restart the dog wake transition")
        var gamer = PetMotion(random: { 0 })
        gamer.act("game")
        let gamePosition = gamer.position
        var taps = Set<Int>()
        for _ in 0..<40 { gamer.advance(0.125); taps.insert(gamer.gamePawOffset); check(gamer.sitting && !gamer.walking && gamer.position == gamePosition, "Gaming stays seated without travel") }
        check(taps == Set([0, 1]) && gamer.updateInterval() == 0.125, "Gaming uses small paw taps at the gentle timer rate")
        gamer.advance(1)
        check(gamer.action == "idle" && gamer.gamePawOffset == 0, "The console activity ends without a stale gesture")
        gamer.act("game"); gamer.advance(1, reducedMotion: true); gamer.act("feed")
        check(gamer.action == "feed" && gamer.position == gamePosition && gamer.gamePawOffset == 0, "Reduced motion and replacement keep gaming stationary and clear the console")
        var box = PetMotion(random: { 0 })
        box.act("litter"); for _ in 0..<16 { box.advance(0.25) }
        box.act("hide")
        for _ in 0..<60 { box.advance(1.0 / 60) }
        check(box.position > 0.32 && box.remaining == 4.8 && box.boxProgress == 0, "Travel does not consume the time in the box or start sinking early")
        for _ in 0..<360 { if box.atBox { break }; box.advance(1.0 / 60) }
        check(box.atBox && box.remaining == 4.8 && !box.walking, "Box entry waits for a complete stop at the destination")
        let boxPosition = box.position
        box.advance(0.3)
        check(box.boxProgress > 0 && box.boxProgress < 1, "Puke lowers into the box gradually")
        box.advance(0.3)
        check(abs(box.boxProgress - 1) < 0.00001, "Puke reaches his tucked box pose")
        for _ in 0..<3 { box.advance(1) }
        check(box.boxProgress == 1 && box.position == boxPosition, "Box time is spent sitting still")
        box.advance(0.6)
        check(box.boxProgress > 0 && box.boxProgress < 1, "Puke rises before the box disappears")
        box.advance(0.4)
        check(box.boxProgress == 0 && box.boxOpacity > 0 && box.boxOpacity < 1, "The empty box clears only after Puke has risen")
        box.advance(0.25)
        check(box.action == "idle" && box.boxProgress == 0 && box.boxOpacity == 0, "Box completion clears all presentation state")
        box.act("hide"); box.advance(0.5); box.act("feed")
        check(box.action == "feed" && box.boxProgress == 0 && box.boxOpacity == 0 && box.position == boxPosition, "A new action clears the box without teleporting or stale entry")
        box.act("litter"); for _ in 0..<16 { box.advance(0.25) }
        let reducedBoxPosition = box.position
        box.act("hide"); for _ in 0..<5 { box.advance(1, reducedMotion: true) }
        check(box.action == "idle" && box.position == reducedBoxPosition && box.boxOpacity == 0, "Reduced motion shows a static local box and still expires")
        var philosopher = PetMotion(random: { 0 })
        for _ in 0..<120 { philosopher.advance(1, reducedMotion: true) }
        check(philosopher.musing == nil, "Closed nooks never announce or queue quotes")
        philosopher.setNookOpen(true)
        for _ in 0..<17 { philosopher.advance(1, reducedMotion: true) }
        check(philosopher.musing == nil, "Opening the nook leaves a quiet interval first")
        philosopher.setNookOpen(false)
        for _ in 0..<120 { philosopher.advance(1, reducedMotion: true) }
        philosopher.setNookOpen(true); philosopher.advance(1, reducedMotion: true)
        check(philosopher.musing != nil && philosopher.musingAuthor == "Puke" && philosopher.sleeping && philosopher.updateInterval(reducedMotion: true) == 0.5, "A musing uses visible nook time without waking Puke or adding faster updates")
        let firstMusing = philosopher.musing, firstDuration = philosopher.musingRemaining
        philosopher.setNookOpen(true)
        check(philosopher.musing == firstMusing && philosopher.musingRemaining == firstDuration, "Duplicate open events do not restart a quote")
        for _ in 0..<10 { philosopher.advance(1, reducedMotion: true) }
        check(philosopher.musing == nil && philosopher.musingAuthor.isEmpty, "Quote and attribution clear after ten seconds")
        for _ in 0..<79 { philosopher.advance(1, reducedMotion: true); check(philosopher.musing == nil, "Quotes have a long quiet gap") }
        philosopher.advance(1, reducedMotion: true)
        check(philosopher.musing != nil && philosopher.musing != firstMusing, "Consecutive sayings never repeat")
        philosopher.act("pet")
        check(philosopher.musing == nil && philosopher.musingAuthor.isEmpty, "Interactions immediately dismiss a musing")
        philosopher.setNookOpen(false); philosopher.setNookOpen(true)
        for _ in 0..<12 { philosopher.advance(1, reducedMotion: true) }
        check(philosopher.musing == nil, "Reopening cannot bypass the quote cooldown")
        philosopher = PetMotion(random: { 0.9 }); philosopher.setNookOpen(true)
        for _ in 0..<30 { philosopher.advance(1, reducedMotion: true) }
        check(philosopher.musing != nil && philosopher.musingAuthor != "Puke", "The collection also selects attributed philosophers")
        philosopher.setNookOpen(false)
        check(philosopher.musing == nil && philosopher.musingAuthor.isEmpty, "Dismissal clears an active quote")
        philosopher = PetMotion()
        check(!philosopher.nookOpen && philosopher.musing == nil, "Disable clears the quote lifecycle")
        // Quiet states retain elapsed time at 2 Hz; gestures and travel opt into faster updates.
        var quiet = PetMotion(random: { 0 })
        check(quiet.updateInterval() == 0.5, "Quiet cat uses two updates per second")
        for _ in 0..<6 { quiet.advance(0.5) }
        check(quiet.time == 3 && quiet.transition == "yawn" && quiet.updateInterval() == 0.125, "Slow idle timer reaches the yawn on time")
        for _ in 0..<3 { quiet.advance(0.5) }
        check(quiet.transition == "settle" && quiet.settleProgress == 0, "Yawn leads into settling")
        quiet.advance(0.5)
        check(quiet.settleProgress > 0 && quiet.settleProgress < 1, "Settling progresses before sleep")
        quiet.advance(1)
        check(quiet.sleeping && quiet.transition.isEmpty && quiet.updateInterval() == 0.5, "Settled nap returns to the slow timer")
        let napTime = quiet.sleepTime, napStyle = quiet.sleepStyle
        quiet.setMusicPlaying(true)
        check(quiet.sleeping && quiet.sleepingThroughMusic && !quiet.enjoyingMusic && quiet.sleepTime == napTime, "A sleepy cat can keep its nap when music starts")
        quiet.setMusicPlaying(true)
        check(quiet.sleepStyle == napStyle && quiet.sleepTime == napTime && quiet.updateInterval() == 0.5, "Duplicate playback preserves the quiet nap")
        var twitchTicks = 0
        for _ in 0..<64 { quiet.advance(0.5); if quiet.earTwitch { twitchTicks += 1 } }
        check(twitchTicks == 4 && quiet.sleepStyle == napStyle && quiet.position == 0.5, "Music nap has one brief ear twitch every sixteen seconds without travel")
        let continuedNap = quiet.sleepTime
        quiet.setMusicPlaying(false)
        check(quiet.sleeping && !quiet.sleepingThroughMusic && quiet.sleepTime == continuedNap, "Stopping music preserves an ongoing nap")
        quiet.setHovered(true, toward: 0)
        check(quiet.glancing && quiet.lookDirection == -1 && quiet.sleeping && quiet.updateInterval() == 0.125, "Hover briefly looks toward the pointer without waking or moving")
        quiet.advance(0.5); let glanceLeft = quiet.glanceRemaining
        quiet.setHovered(true, toward: 1)
        check(quiet.glanceRemaining == glanceLeft && quiet.lookDirection == -1, "Pointer motion does not prolong or reverse the glance")
        quiet.advance(1)
        check(!quiet.glancing && quiet.sleeping && quiet.updateInterval() == 0.5, "Holding the pointer over Puke lets him return to resting")
        quiet.setHovered(false); quiet.setHovered(true)
        check(!quiet.glancing, "Repeated hover entry respects the cooldown")
        for _ in 0..<7 { quiet.advance(1) }
        quiet.setHovered(false); quiet.setHovered(true, toward: 1)
        check(quiet.glancing && quiet.lookDirection == 1, "A later hover can look the other way")
        quiet.setHovered(false)
        check(!quiet.glancing, "Pointer exit clears the reaction immediately")
        quiet.setMusicPlaying(true); quiet.act("pet")
        check(!quiet.sleeping && !quiet.sleepingThroughMusic && quiet.action == "pet" && quiet.wakeRemaining == 0, "A click immediately replaces a music nap")
        quiet.advance(1); quiet.advance(1); quiet.advance(0.5)
        check(quiet.enjoyingMusic && quiet.sitting, "After a click reaction Puke joins the music")
        quiet.act("play")
        check(quiet.updateInterval() == 1.0 / 30 && quiet.updateInterval(reducedMotion: true) == 0.5, "Play stays smooth while reduced motion keeps a slow timer")
        quiet.setHovered(false); quiet.setHovered(true)
        check(!quiet.glancing, "Hover never interrupts play")
        quiet = PetMotion(random: { 0.9 })
        for _ in 0..<12 { quiet.advance(0.5) }
        quiet.setMusicPlaying(true)
        check(!quiet.sleeping && quiet.transition == "stretch" && quiet.updateInterval() == 0.125, "A waking cat stretches before joining music")
        quiet.advance(1); quiet.advance(0.25)
        check(quiet.transition.isEmpty && quiet.sitting, "Stretch ends in a seated music reaction")
        quiet.setMusicPlaying(false); quiet.setMusicPlaying(true); quiet.act("feed")
        check(quiet.transition.isEmpty && quiet.wakeRemaining == 0, "A new click clears a pending stretch")
        quiet = PetMotion()
        check(!quiet.hovered && !quiet.glancing && !quiet.sleepingThroughMusic && quiet.wakeRemaining == 0, "Reset clears hover, nap preference and transitions")
        for style in 0..<4 {
            var pose = PetMotion(random: { Double(style) / 4 + 0.01 })
            for _ in 0..<12 { pose.advance(0.5) }
            check(pose.sleepStyle == style && pose.sleeping, "Every resting pose can be selected")
            for _ in 0..<120 { pose.advance(0.5); check(pose.sleepStyle == style && pose.sleeping, "A resting pose lasts for the whole nap") }
        }
        var resting = PetMotion(random: { 0 })
        for _ in 0..<356 {
            resting.advance(0.25)
            check(resting.position == 0.5 && resting.action == "idle", "No autonomous travel or chores during the first 89 seconds")
        }
        check(resting.sleeping && resting.sleepTime > 80, "A nap lasts through most of the idle interval")
        var sleepTicks = 0
        resting = PetMotion(random: { 0 })
        for _ in 0..<2400 { resting.advance(0.25); if resting.sleeping { sleepTicks += 1 } }
        check(sleepTicks > 2040, "Puke sleeps for over 85 percent of ten idle minutes")
        resting.act("feed")
        check(!resting.sleeping && resting.action == "feed", "Manual actions wake a sleeping cat immediately")
        for _ in 0..<40 { resting.advance(0.25) }
        check(resting.sleeping && resting.action == "idle", "Puke settles back to sleep after an interaction")
        resting.setMusicPlaying(true)
        for _ in 0..<160 { resting.advance(0.25) }
        resting.setMusicPlaying(false)
        for _ in 0..<280 { resting.advance(0.25) }
        check(resting.sleeping && resting.action == "idle", "Stopping music starts a fresh rest interval without overdue activity")
        resting.act("dress")
        check(!resting.sleeping && resting.sleepTime == 0 && resting.outfit == 1, "Style wakes Puke to show the new outfit")
        var settling = PetMotion(random: { 0 })
        settling.act("litter")
        for _ in 0..<4 { settling.advance(0.25) }
        settling.setMusicPlaying(true)
        let movingPosition = settling.position
        check(settling.action == "litter" && settling.position == movingPosition, "Playback cannot teleport or interrupt a manual walk")
        for _ in 0..<24 { settling.advance(0.25) }
        let seatedPosition = settling.position
        for _ in 0..<160 { settling.advance(0.25) }
        check(settling.sitting && abs(settling.position - seatedPosition) < 0.000001, "Music settles after a manual walk and never starts another trip")
        var smooth = PetMotion(random: { 0 }); smooth.act("litter")
        var previousPosition = smooth.position, previousVelocity = smooth.velocity
        for _ in 0..<210 {
            smooth.advance(1.0 / 60)
            check(smooth.target == 0.84 && smooth.position >= previousPosition && smooth.position <= 0.84, "A walk keeps one destination and never rebounds or overshoots")
            check(abs(smooth.velocity) <= 0.30001 && abs(smooth.velocity-previousVelocity) <= 0.025, "Walk acceleration and braking stay bounded")
            previousPosition = smooth.position; previousVelocity = smooth.velocity
        }
        check(!smooth.walking && smooth.velocity == 0 && abs(smooth.position-0.84) < 0.001, "Puke settles at its destination")
        let stoppedDistance = smooth.travelDistance, stoppedFrame = smooth.gaitFrame(runwayPixels: 160)
        smooth.advance(0.2)
        check(smooth.travelDistance == stoppedDistance && smooth.gaitFrame(runwayPixels: 160) == stoppedFrame, "Stationary paws do not keep cycling")
        var fastFrames = PetMotion(random: { 0 }), slowFrames = PetMotion(random: { 0 })
        fastFrames.act("litter"); slowFrames.act("litter")
        for _ in 0..<120 { fastFrames.advance(1.0 / 120) }
        for _ in 0..<30 { slowFrames.advance(1.0 / 30) }
        check(abs(fastFrames.position-slowFrames.position) < 0.0001 && fastFrames.gaitFrame(runwayPixels: 160) == slowFrames.gaitFrame(runwayPixels: 160), "Movement and gait agree at different timer rates")
        let beforeDistance = fastFrames.travelDistance; fastFrames.advance(0.25, reducedMotion: true)
        check(fastFrames.travelDistance == beforeDistance && fastFrames.velocity == 0, "Reduced motion freezes travel and gait")
        smooth.act("hide")
        for _ in 0..<15 { smooth.advance(1.0 / 60) }
        let reversingPosition = smooth.position; smooth.act("litter")
        check(smooth.position == reversingPosition, "Retargeting never teleports Puke")
        for _ in 0..<120 { smooth.advance(1.0 / 60); check(smooth.position >= 0.08 && smooth.position <= 0.92, "Reversals remain bounded") }
        smooth = PetMotion(); check(smooth.velocity == 0 && smooth.travelDistance == 0, "Disable clears velocity and gait history")
        let requiredArt = ["tail", "body", "head", "hind", "front", "eyes", "closed", "sleepEyes", "sleepBody", "sleepTail", "bandana", "hoodie", "shades", "paw", "sitBody", "sitTail", "sitFront", "sitHoodie", "loafBody", "chinPaws", "tuckedTail", "stretchBody", "stretchFront", "stretchHoodie", "yawnMouth", "headTwitch", "toyPet", "toyFeed", "toyPlay", "toyDress", "toyHighfive", "toyHide", "toyLitter", "nookWindow", "nookPlant", "boxBack", "boxFront", "toyGame", "gameConsole", "gamePaws"]
        for layer in requiredArt { check(!(PetArtwork.layers[layer] ?? []).isEmpty, "Missing shared Puke layer " + layer) }
        for pixels in PetArtwork.layers.values {
            check(pixels.allSatisfy { $0.x >= 0 && $0.x+$0.width <= 44 && $0.y >= 0 && $0.y < 32 && PetArtwork.palette.indices.contains($0.color) }, "Puke pixels stay inside their frame and palette")
        }
        var pet = PetMotion()
        for _ in 0..<1000 { pet.advance(0.1); check(pet.position >= 0.08 && pet.position <= 0.92, "Pet stays in its runway") }
        pet.act("feed"); pet.advance(0.25); pet.act("pet")
        check(pet.action == "pet" && pet.remaining == 2.4, "Latest interaction replaces the old reaction")
        for _ in 0..<10 { pet.advance(0.25) }
        check(pet.action == "idle" && pet.remaining == 0, "Reactions expire without restoring older actions")
        pet.act("play", target: 10); check(pet.target == 0.92)
        let position = pet.position
        for _ in 0..<10 { pet.advance(0.25, reducedMotion: true) }
        check(pet.position == position && !pet.walking && pet.action == "idle", "Reduced motion keeps Puke still while reactions expire")
        pet = PetMotion(random: { 0.9 }); check(pet.time == 0 && pet.action == "idle" && pet.position == 0.5)
        for _ in 0..<49 { pet.advance(0.25) }
        check(pet.sleeping && pet.sleepTime > 0 && (0...3).contains(pet.sleepStyle), "Idle Puke chooses a nap animation")
        let sleepStyle = pet.sleepStyle, sleepTime = pet.sleepTime
        pet.setMusicPlaying(false); pet.advance(0.25)
        check(pet.sleepStyle == sleepStyle && pet.sleepTime > sleepTime, "Duplicate stopped playback does not restart the nap")
        pet.setMusicPlaying(true)
        check(pet.enjoyingMusic && !pet.sleeping && pet.sleepTime == 0, "Music wakes Puke and clears the nap")
        pet.advance(0.25); let musicPosition = pet.position, musicTime = pet.musicTime; pet.setMusicPlaying(true)
        check(pet.musicTime == musicTime && pet.position == musicPosition, "Repeated music readings do not restart the dance")
        for _ in 0..<5 { pet.advance(0.25) }
        var moves = Set<Int>(), pawOffsets = Set<Int>(), headOffsets = Set<Int>()
        let dancePosition = pet.position, danceDistance = pet.travelDistance
        for _ in 0..<52 {
            pet.advance(0.25); moves.insert(pet.danceMove)
            pawOffsets.insert(pet.dancePawOffset); headOffsets.insert(pet.danceHeadOffset)
            check(pet.sitting && !pet.walking && pet.position == dancePosition && pet.travelDistance == danceDistance, "Seated dancing never paces or cycles walking feet")
            check(pet.position >= 0.08 && pet.position <= 0.92 && pet.action == "idle", "Music stays bounded and excludes spontaneous chores")
        }
        check(moves == [0, 1] && pawOffsets == [-1, 0, 1] && headOffsets == [0, 1], "Seated dance alternates a small paw wave and head bob")
        pet.act("feed"); pet.setMusicPlaying(true)
        check(!pet.enjoyingMusic && pet.action == "feed", "Music updates do not override an interaction")
        for _ in 0..<13 { pet.advance(0.25) }
        check(pet.enjoyingMusic, "Puke resumes enjoying music after a snack")
        let stillPosition = pet.position, stillMusicTime = pet.musicTime
        pet.advance(0.25, reducedMotion: true)
        check(pet.enjoyingMusic && pet.position == stillPosition && pet.musicTime == stillMusicTime && !pet.walking, "Reduced motion retains static music feedback")
        pet.setMusicPlaying(false); pet.setMusicPlaying(false)
        check(!pet.enjoyingMusic && !pet.sitting && pet.dancePawOffset == 0 && pet.danceHeadOffset == 0, "Paused or cleared playback stops the music reaction")
        pet.setMusicPlaying(true); pet.act("pet"); pet = PetMotion()
        check(!pet.musicPlaying && !pet.enjoyingMusic && pet.sleepTime == 0 && pet.action == "idle", "Reset clears music and nap state as well as interactions")
        for (choice, expected) in [(0.0, "play"), (0.18, "hide"), (0.35, "litter"), (0.52, "highfive"), (0.69, "groom"), (0.86, "game")] {
            var curious = PetMotion(random: { choice })
            for _ in 0..<640 {
                if curious.action != "idle" || curious.outfit != 0 { break }
                curious.advance(0.25)
            }
            check(curious.action == expected && curious.outfit == 0, "Idle Puke spontaneously chooses " + expected + " without changing clothes")
            curious.act("feed"); curious.advance(0.25)
            check(curious.action == "feed", "Manual interaction replaces autonomous behavior")
        }
        var still = PetMotion(random: { 0 })
        for _ in 0..<640 { still.advance(0.25, reducedMotion: true) }
        check(still.action == "idle" && still.position == 0.5 && still.outfit == 0, "Reduced motion suppresses spontaneous actions")
        pet = PetMotion(); pet.act("hide")
        for _ in 0..<8 { pet.advance(0.25) }
        check(pet.action == "hide" && abs(pet.position-0.32) < 0.01, "Puke reaches the cardboard box")
        pet.act("litter")
        for _ in 0..<10 { pet.advance(0.25) }
        check(pet.action == "litter" && abs(pet.position-0.84) < 0.01, "Puke reaches the litter tray")
        pet.act("highfive"); pet.act("dress")
        check(pet.action == "highfive" && pet.outfit == 1, "Dress-up preserves a high-five")
        for _ in 0..<3 { pet.act("dress") }
        check(pet.outfit == 0, "Outfit cycle returns to classic")
        pet.act("play", target: 0.5)
        for _ in 0..<5 { pet.advance(0.25) }
        check(pet.fumbled && pet.target != 0.5, "Yarn escapes after the first pounce")
        let escaped = pet.target; pet.advance(0.25)
        check(pet.target == escaped, "Yarn fumbles only once per interaction")
        pet = PetMotion(); check(pet.outfit == 0 && !pet.fumbled && pet.musicTime == 0, "Reset clears clothes, yarn and dancing")
    }

    func testAppearanceMigration() throws {
        // The first macOS prototype saved settings without appearance preferences.
        let id = UUID()
        let original = "{\"accounts\":[{\"id\":\"\(id)\",\"serviceID\":\"gmail\",\"name\":\"Work\"}],\"selected\":\"\(id)\"}"
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(original.utf8))
        check(settings.appearance == nil)
        check(settings.titlebarPetEnabled != true, "Existing settings keep the pet off")
        check(PetMotion.normalizedKind(settings.titlebarCompanion ?? "puke") == "puke", "Existing settings default to Puke")
        for kind in ["roof", "rock"] {
            settings.titlebarCompanion = kind
            let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
            check(loaded.titlebarCompanion == kind && loaded.selected == id, "Companion selection persists without changing accounts")
        }
        settings.titlebarPetEnabled = true
        let withPet = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(withPet.titlebarPetEnabled == true && withPet.selected == id, "Pet opt-in persists without changing the account")
        settings.titlebarPetEnabled = false
        let withoutPet = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(withoutPet.titlebarPetEnabled == false && withoutPet.titlebarCompanion == "rock", "Disabling preserves the chosen companion")
        check(settings.hideLayoutButton != true, "Legacy settings keep Layout visible")
        check(settings.hidePaletteButton != true, "Legacy settings keep the command palette button visible")
        settings.hidePaletteButton = true
        try check(JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings)).hidePaletteButton == true, "Hidden palette button persists")
        settings.hidePaletteButton = false
        try check(JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings)).hidePaletteButton == false, "Restoring palette button persists")
        settings.hideLayoutButton = true
        let hidden = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(hidden.hideLayoutButton == true && hidden.selected == id, "Hiding Layout persists without changing selection")
        settings.hideLayoutButton = false
        let shown = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(shown.hideLayoutButton == false, "Restoring Layout clears the hidden preference")
        settings.appearance = AppearancePreferences(mode: "Light", surface: "Ocean", accent: "Iris", compact: true, topTabs: true)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(restored.appearance == settings.appearance)
        check(restored.accounts.first?.id == id)
        check(restored.selected == id)
    }

    func testAccountManagement() throws {
        let original = Account(id: UUID(), serviceID: service.id, name: "Personal")
        var settings = Preferences(accounts: [original], selected: original.id)
        settings.initializeCatalog([service])
        check(settings.accounts == [original])
        let other = try settings.addAccount(service: service, name: " Work ")
        check(other.name == "Work")
        try settings.renameAccount(original.id, to: "Home")
        check(settings.accounts[0].id == original.id)
        do { try settings.renameAccount(other.id, to: "home"); fatalError("Duplicate name accepted") }
        catch AccountError.duplicateName {}
        do { _ = try settings.addAccount(service: service, name: "  "); fatalError("Empty name accepted") }
        catch AccountError.invalidName {}
        settings.setVisible(original.id, false)
        settings.moveAccount(other.id, by: -1)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        check(restored.accounts.first?.id == other.id)
        check(restored.hiddenAccountIDs == [original.id])
        settings.removeAccount(original.id)
        check(settings.selected == nil)
        check(settings.hiddenAccountIDs?.isEmpty == true)
        settings.removeAccount(other.id)
        settings.initializeCatalog([service])
        check(settings.accounts.isEmpty, "Removed accounts must not reappear at launch")
        let replacement = try settings.addAccount(service: service)
        check(replacement.id != original.id && replacement.id != other.id)
        let duplicate = try settings.addAccount(service: service)
        check(duplicate.name == service.name + " 2")
    }

    func testDownloadDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: file)
        let cancelled = try DownloadDestination(file: file)
        try Data("partial".utf8).write(to: cancelled.stagingFile)
        cancelled.cleanup()
        try check(String(contentsOf: file, encoding: .utf8) == "original")
        let complete = try DownloadDestination(file: file)
        try Data("complete".utf8).write(to: complete.stagingFile)
        try complete.finish()
        try check(String(contentsOf: file, encoding: .utf8) == "complete")
        check(!FileManager.default.fileExists(atPath: complete.stagingDirectory.path))
        let newFile = directory.appendingPathComponent("new.txt")
        let conflict = try DownloadDestination(file: newFile)
        try Data("downloaded".utf8).write(to: conflict.stagingFile)
        try Data("created while downloading".utf8).write(to: newFile)
        do { try conflict.finish(); fatalError("Unexpected overwrite") } catch is CocoaError {}
        try check(String(contentsOf: newFile, encoding: .utf8) == "created while downloading")
        check(FileManager.default.fileExists(atPath: conflict.stagingFile.path), "Preserve completed bytes after a move failure")
        check(DownloadDestination.suggestedName("../../secret.txt") == "secret.txt")
        check(DownloadDestination.suggestedName("..\\secret.txt") == "secret.txt")
        check(DownloadDestination.suggestedName("..") == "Download")
    }

    func testUnreadState() {
        for (title, count) in [("(12) WhatsApp", 12), ("[4+] Telegram", 4), ("Inbox (3) - Gmail", 3), ("(0) Chat", 0)] {
            check(UnreadRules.countFromTitle(title) == count)
        }
        for title in ["Meeting at 12", "Inbox 2026", "(1000000) Chat", "(4)not an unread title", "(oops) Chat"] {
            check(UnreadRules.countFromTitle(title) == nil)
        }
        var state = UnreadState()
        let four = UnreadReading(count: 4, attention: false, key: "title:4")
        check(state.receive(four))
        check(state.badge == "4")
        check(!state.receive(four), "Repeated polling must not duplicate activity")
        check(!state.receive(.unknown))
        check(!state.receive(four), "Reload must not duplicate the same unread signal")
        check(!state.receive(.unknown))
        state.dismiss()
        check(state.badge.isEmpty)
        check(!state.receive(.unknown))
        check(!state.receive(four))
        check(state.badge.isEmpty, "Dismissed badges must stay dismissed after a transient title")
        check(state.receive(UnreadReading(count: 5, attention: false, key: "title:5")))
        check(state.badge == "5", "A new signal must restore the badge")
        check(!state.receive(four), "Decreasing count is not new activity")
        check(state.badge == "4")
        check(!state.receive(UnreadReading(count: 0, attention: true, key: "zero")))
        check(state.badge.isEmpty)
        check(state.receive(four), "Unread after an explicit zero is new activity")
        check(!state.receive(UnreadReading(count: -1, attention: false, key: "invalid")))
        check(state.badge == "4", "Invalid values must not replace a good reading")
        check(state.receive(UnreadReading(count: 120, attention: false, key: "title:120")))
        check(state.badge == "99+")
        check(UnreadRules.messengerPage(URL(string: "https://www.facebook.com/messages/t/123")!))
        for path in ["/messages/", "/notifications/", "/messages-fake"] {
            check(UnreadRules.titleReading("(28) Messenger", service: service, url: URL(string: "https://www.facebook.com" + path)) == .unknown,
                  "Facebook notification totals must never bypass Messenger extraction")
        }
        for address in ["https://www.facebook.com/", "https://www.facebook.com/messages-fake", "https://messenger.com.evil.test", "http://messenger.com"] {
            check(!UnreadRules.messengerPage(URL(string: address)!))
        }
        check(MessengerUnread.reading(["Count": true, "Unread": false, "Key": "bad"]) == nil)
        check(MessengerUnread.reading(["Count": 1.5, "Unread": false, "Key": "bad"]) == nil)
        check(MessengerUnread.reading(["Count": 1_000_000, "Unread": false, "Key": "bad"]) == nil)
    }

    func testGmailUnreadModes() throws {
        var counter = GmailUnreadCounter()
        func raw(_ count: Int) -> UnreadReading { UnreadReading(count: count, attention: false, key: "gmail:\(count)") }
        check(counter.reading(raw(1234), allUnread: false).count == 0, "Backlog must not count as new")
        check(counter.reading(raw(1236), allUnread: false).count == 2)
        check(counter.reading(.unknown, allUnread: false) == .unknown)
        check(counter.reading(raw(1235), allUnread: false).count == 1)
        check(counter.reading(raw(1200), allUnread: false).count == 0)
        check(counter.reading(raw(1201), allUnread: false).count == 1)
        check(counter.reading(raw(1201), allUnread: true).count == 1201)
        var other = GmailUnreadCounter()
        check(other.reading(raw(500), allUnread: false).count == 0, "Account baselines must be independent")
        var account = Account(id: UUID(), serviceID: "gmail", name: "Gmail")
        check(account.gmailAllUnread != true, "Default Gmail mode excludes backlog")
        account.gmailAllUnread = true
        let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        check(restored.gmailAllUnread == true)
    }

    func testMessengerScriptParity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("windows/Sources/Relay/UnreadDetection.cs"), encoding: .utf8)
        let delimiter = "private const string MessengerUnreadScript = \"\"\""
        let script = source.components(separatedBy: delimiter)[1].components(separatedBy: "\"\"\";")[0]
        func normalized(_ value: String) -> [String] {
            value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        check(normalized(script) == normalized(MessengerUnread.script), "Windows and macOS Messenger extraction have diverged")
        let gmail = source.components(separatedBy: "private const string GmailUnreadScript = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
        check(normalized(gmail) == normalized(GmailUnread.script), "Windows and macOS Gmail extraction have diverged")
        let chromeSource = try String(contentsOf: root.appendingPathComponent("windows/Sources/Relay/MessengerChrome.cs"), encoding: .utf8)
        let chrome = chromeSource.components(separatedBy: "private const string MessengerChromeScript = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
        check(normalized(chrome) == normalized(MessengerChrome.script), "Messenger chrome drifted from Windows")
        let whatsappSource = try String(contentsOf: root.appendingPathComponent("windows/Sources/Relay/WhatsAppChrome.cs"), encoding: .utf8)
        let whatsapp = whatsappSource.components(separatedBy: "private const string WhatsAppChromeScript = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
        check(normalized(whatsapp) == normalized(WhatsAppChrome.script), "WhatsApp chrome drifted from Windows")
        check(MessengerChrome.script.contains("function scrollPanes()") && MessengerChrome.script.contains("document.elementFromPoint(innerWidth * x, innerHeight * y)"), "Visible chat targeting must survive a large chat-list DOM on both engines")
    }
}
