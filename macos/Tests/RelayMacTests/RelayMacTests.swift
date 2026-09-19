import Foundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Check failed",
                   file: StaticString = #file, line: UInt = #line) rethrows {
    if try !condition() { fatalError(message, file: file, line: line) }
}

@main
struct RelayMacTests {
    static func main() throws {
        let tests = RelayMacTests()
        tests.testHostBoundariesAndSchemes()
        try tests.testMediaPermissions()
        tests.testGoogleLinksDoNotCaptureSearch()
        try tests.testGoogleSessionHandoffs()
        try tests.testAccountIdentifiersSurviveRestart()
        try tests.testBrowserEngineMigration()
        try tests.testZoomPersistence()
        try tests.testSharedCatalog()
        try tests.testAppearanceMigration()
        try tests.testAccountManagement()
        try tests.testRemovedAccountRestoration()
        try tests.testDragReordering()
        tests.testAccountCycling()
        tests.testRendererRecovery()
        try tests.testLoadedAccounts()
        try tests.testNotificationPreferences()
        try tests.testMediaScriptParity()
        try tests.testDownloadDestination()
        tests.testBrowserRules()
        tests.testUnreadState()
        try tests.testGmailUnreadModes()
        try tests.testMessengerScriptParity()
        print("Passed: routing/permissions, account/notification preferences, ordering/zoom, recovery, downloads, Windows unread/media script parity")
    }
    private let service = Service(id: "messenger", name: "Messenger",
        url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M",
        hosts: ["facebook.com", "messenger.com"])

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
        for service in ["gmail", "calendar", "googlemessages", "googlekeep"] {
            let home = BrowserRules.googleHome(service)!
            check(BrowserRules.googleApp(home, service: service))
            check(!BrowserRules.googleApp(URL(string: "https://accounts.google.com/"), service: service))
            check(BrowserRules.googleLanding(URL(string: "https://accounts.google.com/"), service: service))
            check(!BrowserRules.googleLanding(URL(string: "https://accounts.google.com.evil.test/"), service: service))
        }
        check(!BrowserRules.googleApp(URL(string: "https://mail.google.com/mail-malicious/"), service: "gmail"))
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
        let source = try String(contentsOf: root.appendingPathComponent("MediaControls.cs"), encoding: .utf8)
        let start = source.range(of: "private const string MediaBridgeScript = ")!.upperBound
        let scriptStart = source[start...].firstIndex(of: "\n")!
        let end = source[scriptStart...].range(of: "\n        \"\"\";")!.lowerBound
        let windows = source[source.index(after: scriptStart)..<end].split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.dropFirst(8)) }.joined(separator: "\n")
        check(windows == MediaBridge.template, "Media bridge drifted from Windows")
        check(MediaBridge.script(for: "whatsapp").isEmpty)
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
            for address in ["https://accounts.google.com/signin", "https://accounts.youtube.com/accounts/SetSID"] {
                let url = URL(string: address)!
                check(BrowserRules.googleSignIn(url))
                check(service.allowsEmbedded(url), "Google session handoff escaped the account profile")
                check(!service.allowsMediaPermissionRequest(origin: url, page: service.url))
                check(!service.allowsMediaPermissionRequest(origin: service.url, page: url))
            }
            for address in ["http://accounts.youtube.com/accounts/SetSID", "https://accounts.youtube.com.evil.test/accounts/SetSID", "https://www.youtube.com/watch?v=fixture"] {
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

    func testAppearanceMigration() throws {
        // The first macOS prototype saved settings without appearance preferences.
        let id = UUID()
        let original = "{\"accounts\":[{\"id\":\"\(id)\",\"serviceID\":\"gmail\",\"name\":\"Work\"}],\"selected\":\"\(id)\"}"
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(original.utf8))
        check(settings.appearance == nil)
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
        let source = try String(contentsOf: root.appendingPathComponent("UnreadDetection.cs"), encoding: .utf8)
        let delimiter = "private const string MessengerUnreadScript = \"\"\""
        let script = source.components(separatedBy: delimiter)[1].components(separatedBy: "\"\"\";")[0]
        func normalized(_ value: String) -> [String] {
            value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        check(normalized(script) == normalized(MessengerUnread.script), "Windows and macOS Messenger extraction have diverged")
        let gmail = source.components(separatedBy: "private const string GmailUnreadScript = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
        check(normalized(gmail) == normalized(GmailUnread.script), "Windows and macOS Gmail extraction have diverged")
        let chromeSource = try String(contentsOf: root.appendingPathComponent("MessengerChrome.cs"), encoding: .utf8)
        let chrome = chromeSource.components(separatedBy: "private const string MessengerChromeScript = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
        check(normalized(chrome) == normalized(MessengerChrome.script), "Messenger chrome drifted from Windows")
    }
}
