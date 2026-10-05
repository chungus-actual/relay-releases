import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension RelayStore {
    func snooze(_ account: Account? = nil, until: Int64?) {
        guard change({ p in
            if let account, let i = p.accounts.firstIndex(where: { $0.id == account.id }) { p.accounts[i].snoozedUntil = until }
            else if account == nil { p.snoozedUntil = until }
        }) else { return }
        if let account { notifications.clear(account.id) } else { notifications.clearAll() }
    }
    func setIdentity(_ account: Account, color: String) {
        guard Productivity.colors.contains(color) else { return }
        _ = change { p in if let i = p.accounts.firstIndex(where: { $0.id == account.id }) { p.accounts[i].identityColor = color } }
    }
    func editWorkspace(_ saved: SavedWorkspace? = nil) {
        workspaceDraft = saved ?? SavedWorkspace(name: "", layout: workspace, focused: preferences.selected ?? lastFocusedAccount)
    }
    func saveWorkspace(_ draft: SavedWorkspace) -> Bool {
        change { p in
            var item = draft; item.name = try Productivity.name(item.name); item.layout.normalize(available: p.accounts.map(\.id))
            guard !item.layout.panes.isEmpty else { throw SetupError.invalid("Open an account before saving a workspace.") }
            var list = p.savedWorkspaces ?? []
            guard !list.contains(where: { $0.id != item.id && $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) else { throw SetupError.invalid("That workspace name is already in use.") }
            list.removeAll { $0.id == item.id }; list.append(item)
            guard list.count <= 32 else { throw SetupError.invalid("You can save up to 32 workspaces.") }
            p.savedWorkspaces = list
        }
    }
    func deleteWorkspace(_ item: SavedWorkspace) { _ = change { $0.savedWorkspaces?.removeAll { $0.id == item.id } } }
    func openWorkspace(_ item: SavedWorkspace) {
        guard preferences.savedWorkspaces?.contains(where: { $0.id == item.id }) == true else { return }
        var layout = item.layout; layout.normalize(available: preferences.accounts.map(\.id))
        guard !layout.panes.isEmpty else { error = "This workspace's accounts are no longer available."; return }
        if change({ p in
            p.workspace = layout
            for i in p.accounts.indices where layout.panes.contains(p.accounts[i].id) { p.accounts[i].enabled = true }
            p.selected = item.focused.flatMap { layout.panes.contains($0) ? $0 : nil } ?? layout.panes.first
        }) {
            for session in loadedSessions where layout.panes.contains(session.accountID) { session.dockServiceWindow(select: false) }
            localPage = "service"
        }
    }
    func bookmarkAddress(_ account: Account) -> String {
        guard let service = services.first(where: { $0.id == account.serviceID }) else { return "" }
        let current = loadedSessions.first { $0.accountID == account.id }?.address?.absoluteString ?? ""
        return Productivity.bookmarkAllowed(current, service: service) ? current : service.url.absoluteString
    }
    func editBookmark(_ initial: Account? = nil, saved: AccountBookmark? = nil) {
        guard let account = initial ?? preferences.accounts.first(where: { $0.id == (preferences.selected ?? lastFocusedAccount) }) ?? preferences.accounts.first else { return }
        guard account.serviceID != "terminal" else { return }
        bookmarkDraft = saved ?? AccountBookmark(accountId: account.id, name: account.name,
            url: bookmarkAddress(account))
    }
    func saveBookmark(_ draft: AccountBookmark) -> Bool {
        change { p in
            var item = draft; item.name = try Productivity.name(item.name); item.url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let account = p.accounts.first(where: { $0.id == item.accountId }), let service = services.first(where: { $0.id == account.serviceID }),
                  Productivity.bookmarkAllowed(item.url, service: service) else { throw SetupError.invalid("Choose an HTTPS page belonging to this account's service.") }
            var list = p.bookmarks ?? []; list.removeAll { $0.id == item.id || ($0.accountId == item.accountId && $0.url == item.url) }; list.append(item)
            guard list.count <= 200 else { throw SetupError.invalid("You can save up to 200 bookmarks.") }
            p.bookmarks = list
        }
    }
    func deleteBookmark(_ item: AccountBookmark) { _ = change { $0.bookmarks?.removeAll { $0.id == item.id } } }
    func openBookmark(_ item: AccountBookmark) {
        guard preferences.bookmarks?.contains(where: { $0.id == item.id }) == true,
              let account = preferences.accounts.first(where: { $0.id == item.accountId }),
              let service = services.first(where: { $0.id == account.serviceID }), Productivity.bookmarkAllowed(item.url, service: service),
              let url = URL(string: item.url) else { return }
        select(account)
        guard preferences.selected == account.id else { return }
        session(for: account.id)?.load(url)
    }
    func exportSetup() {
        let panel = NSSavePanel(); panel.title = "Export Relay settings"; panel.nameFieldStringValue = "Relay-setup.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try preferences.exportSetup().encode().write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func importSetup() {
        let panel = NSOpenPanel(); panel.title = "Import Relay settings"; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw SetupError.invalid("This setup file is too large.") }
            let setup = try PortableSetup.decode(Data(contentsOf: url), services: services)
            var next = preferences; try next.mergeSetup(setup, services: services)
            let alert = NSAlert(); alert.messageText = "Import Relay settings?"
            alert.informativeText = "Merge \(setup.accounts.count) accounts, \(setup.workspaces.count) workspaces and \(setup.bookmarks.count) bookmarks. Appearance and matching account preferences will be updated. Existing accounts and sign-ins stay in place. New accounts start unloaded."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = applyImportedPreferences(next)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func applyImportedPreferences(_ next: Preferences) -> Bool {
        let previous = preferences
        guard change({ $0 = next }) else { return false }
        for session in loadedSessions {
            guard let account = preferences.accounts.first(where: { $0.id == session.accountID }) else { continue }
            session.accountName = account.name
            session.setZoom(account.zoom); session.setKeepLive(account.staysAwake); session.setMuted(account.audioMuted == true)
            session.captureLinks = captureLinks
            if account.serviceID == "gmail", (previous.accounts.first { $0.id == account.id }?.gmailAllUnread == true) != (account.gmailAllUnread == true) {
                unread.setGmailMode(for: account.id, allUnread: account.gmailAllUnread == true)
            }
            session.pageControls.refreshPermission()
        }
        notifications.clearAll(); return true
    }
}
