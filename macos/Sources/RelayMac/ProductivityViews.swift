import SwiftUI

struct SnoozeMenu: View {
    @ObservedObject var store: RelayStore
    var account: Account? = nil
    private var until: Int64? { account.flatMap { a in store.preferences.accounts.first { $0.id == a.id }?.snoozedUntil } ?? (account == nil ? store.preferences.snoozedUntil : nil) }
    private func snooze(_ minutes: Int) { store.snooze(account, until: Int64(Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970)) }
    var body: some View {
        Menu("Snooze notifications") {
            if let until, Productivity.snoozed(until) { Text("Until \(Date(timeIntervalSince1970: Double(until)).formatted(date: .abbreviated, time: .shortened))") }
            Button("30 minutes") { snooze(30) }; Button("1 hour") { snooze(60) }; Button("8 hours") { snooze(480) }
            Button("Until tomorrow at 9 AM") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                let date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
                store.snooze(account, until: Int64(date.timeIntervalSince1970))
            }
            Button("Resume now") { store.snooze(account, until: nil) }.disabled(!Productivity.snoozed(until))
        }
    }
}

struct CommandPalette: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var query = ""
    @ViewState private var selection: String?
    @FocusState private var searchFocused: Bool
    struct Command: Identifiable { let id: String; let title: String; let detail: String; let run: () -> Void }
    private var commands: [Command] {
        var list: [Command] = []
        for account in store.preferences.accounts {
            let provider = store.services.first { $0.id == account.serviceID }?.name ?? account.serviceID
            let badge = store.unread.badge(for: account.id)
            var detail = "Account · " + provider
            if !badge.isEmpty { detail += " · \(badge) unread" }
            if !store.isVisible(account) { detail += " · Hidden" }
            list.append(Command(id: account.id.uuidString, title: account.name, detail: detail, run: { store.select(account) }))
        }
        list += (store.preferences.savedWorkspaces ?? []).map { w in Command(id: "workspace-" + w.id, title: w.name, detail: "Workspace · \(w.layout.panes.count) panes", run: { store.openWorkspace(w) }) }
        list += (store.preferences.bookmarks ?? []).map { b in Command(id: "bookmark-" + b.id, title: b.name,
            detail: "Bookmark · " + (store.preferences.accounts.first { $0.id == b.accountId }?.name ?? "Account"), run: { store.openBookmark(b) }) }
        func action(_ title: String, _ run: @escaping () -> Void) { list.append(Command(id: title, title: title, detail: "Action", run: run)) }
        action("Settings") { store.showLocal("settings") }; action("Activity") { store.showLocal("activity") }
        action("Workspaces & bookmarks") { store.showLocal("library") }; action("Save current workspace") { store.editWorkspace() }
        if let a = store.zoomAccount, a.serviceID != "terminal" { action("Bookmark current page") { store.editBookmark(a) } }
        action("Downloads") { store.downloads.isOpen = true }
        action("Snooze notifications for 1 hour") { store.snooze(until: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)) }
        action("Resume snoozed notifications") { store.snooze(until: nil) }
        action("Export settings") { store.exportSetup() }; action("Import settings") { store.importSetup() }
        if let active = store.media.active, !store.media.performingAction {
            func playback(_ title: String, _ mediaAction: MediaAction) {
                action(title) { Task { guard store.media.active?.accountID == active.accountID else { return }; await store.media.act(mediaAction) } }
            }
            playback(active.reading.playing ? "Pause playback" : "Play", active.reading.playing ? .pause : .play)
            if active.reading.previous { playback("Previous track", .previous) }
            if active.reading.next { playback("Next track", .next) }
        }
        func rank(_ command: Command) -> Int { command.title.lowercased().hasPrefix(query.lowercased()) ? 0 : command.title.localizedCaseInsensitiveContains(query) ? 1 : 2 }
        return list.enumerated().filter { Productivity.paletteMatches(query, $0.element.title, $0.element.detail) }
            .sorted { rank($0.element) == rank($1.element) ? $0.offset < $1.offset : rank($0.element) < rank($1.element) }.map(\.element)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Find your way").font(.system(size: 19, weight: .semibold)); Text("Accounts, workspaces, bookmarks & actions").font(.system(size: 11)).foregroundStyle(theme.muted) }
                Spacer()
                PetDrawing(motion: PetMotion(kind: store.titlebarCompanion), theme: theme, large: false, reducedMotion: true).frame(width: 65, height: 38).accessibilityHidden(true)
            }
            TextField("Search commands", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { runSelected() }
            if commands.isEmpty { Text("No matches. Try an account name or an action.").foregroundStyle(theme.muted); Spacer() }
            else {
                List(selection: $selection) {
                    ForEach(commands) { command in
                        Button { run(command) } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(command.title).font(.system(size: 13, weight: .semibold)); Text(command.detail).font(.system(size: 10)).foregroundStyle(theme.muted) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).tag(command.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            Text("↑ ↓  choose     Return  open     Esc  back").font(.system(size: 11)).foregroundStyle(theme.muted)
        }.padding(22).frame(width: 540, height: 420).foregroundStyle(theme.ink).background(theme.panel)
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--shell-check"), (colorScheme == .dark) != theme.dark {
                    fputs("FAIL: palette native controls use a different color scheme from Relay\n", stderr)
                    exit(1)
                }
                selection = commands.first?.id; searchFocused = true
            }
            .onChange(of: query) { _, _ in selection = commands.first?.id }
            .onKeyPress(.escape) { store.palettePresented = false; return .handled }
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                let rows = commands; guard !rows.isEmpty else { return .handled }
                let index = rows.firstIndex { $0.id == selection } ?? 0
                selection = rows[min(rows.count - 1, max(0, index + (key.key == .downArrow ? 1 : -1)))].id
                return .handled
            }
    }
    private func runSelected() { if let command = commands.first(where: { $0.id == selection }) { run(command) } }
    private func run(_ command: Command) { store.paletteSelection = command.run; store.palettePresented = false }
}

struct SavedPlacesView: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    @ViewState private var query = ""
    private var workspaces: [SavedWorkspace] {
        (store.preferences.savedWorkspaces ?? []).filter { Productivity.matches(query, $0.name, accountNames($0)) }
    }
    private func accountNames(_ item: SavedWorkspace) -> String {
        item.layout.panes.compactMap { id in store.preferences.accounts.first { $0.id == id }?.name }.joined(separator: " · ")
    }
    private func bookmarks(_ account: Account) -> [AccountBookmark] {
        (store.preferences.bookmarks ?? []).filter { $0.accountId == account.id && Productivity.matches(query, $0.name, $0.url, account.name, account.serviceID) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search workspaces, bookmarks, or accounts", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Text("Workspaces").font(.headline); Spacer()
                action("Save current workspace…") { store.editWorkspace() }.disabled(store.workspace.panes.isEmpty)
            }
            ForEach(workspaces) { item in
                HStack {
                    title(item.name, detail: accountNames(item))
                    Spacer()
                    action("Open") { store.openWorkspace(item) }
                    action("Edit") { store.editWorkspace(item) }
                    action("Delete") { store.deleteWorkspace(item) }
                }.padding(16).shellCard(theme)
            }
            if workspaces.isEmpty { empty((store.preferences.savedWorkspaces ?? []).isEmpty ? "No saved workspaces yet." : "No matching workspaces.") }
            HStack {
                Text("Bookmarks").font(.headline); Spacer()
                action("Add bookmark…") { store.editBookmark() }.disabled(store.preferences.accounts.isEmpty)
            }.padding(.top, 10)
            ForEach(store.preferences.accounts) { account in
                if !bookmarks(account).isEmpty {
                    HStack(spacing: 8) { ServiceIcon(id: account.serviceID, size: 16); Text(account.name).font(.system(size: 12, weight: .semibold)) }
                    ForEach(bookmarks(account)) { item in bookmarkRow(item, account: account) }
                }
            }
            if store.preferences.accounts.allSatisfy({ bookmarks($0).isEmpty }) {
                empty((store.preferences.bookmarks ?? []).isEmpty ? "No bookmarks yet." : "No matching bookmarks.")
            }
        }
    }
    private func bookmarkRow(_ item: AccountBookmark, account: Account) -> some View {
        HStack {
            title(item.name, detail: item.url); Spacer()
            action("Open") { store.openBookmark(item) }
            action("Edit") { store.editBookmark(account, saved: item) }
            action("Delete") { store.deleteBookmark(item) }
        }.padding(16).shellCard(theme)
    }
    private func title(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(name)
            Text(detail).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1).help(detail)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(16).shellCard(theme)
    }
    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7) }
            .buttonStyle(ShellButtonStyle(theme: theme, bordered: true)).fixedSize()
    }
}

struct SavedWorkspaceEditor: View {
    @ObservedObject var store: RelayStore
    @ViewState var draft: SavedWorkspace
    let theme: ShellTheme
    @Environment(\.dismiss) private var dismiss
    @ViewState private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save workspace").font(.headline)
            TextField("Workspace name", text: $draft.name).textFieldStyle(.roundedBorder)
            Text("\(draft.layout.panes.count) panes").foregroundStyle(theme.muted)
            Button("Use current layout") { draft.layout = store.workspace; draft.focused = store.preferences.selected }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if store.saveWorkspace(draft) { dismiss() } else { failure = store.error; store.error = nil } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 400).foregroundStyle(theme.ink).background(theme.base)
    }
}

struct BookmarkEditor: View {
    @ObservedObject var store: RelayStore
    @ViewState var draft: AccountBookmark
    let theme: ShellTheme
    @Environment(\.dismiss) private var dismiss
    @ViewState private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((store.preferences.bookmarks ?? []).contains { $0.id == draft.id } ? "Edit bookmark" : "Add bookmark").font(.headline)
            Picker("Account", selection: $draft.accountId) {
                ForEach(store.preferences.accounts) { account in Text(account.name).tag(account.id) }
            }.pickerStyle(.menu)
                .onChange(of: draft.accountId) { old, next in
                    guard let previous = store.preferences.accounts.first(where: { $0.id == old }),
                          let account = store.preferences.accounts.first(where: { $0.id == next }) else { return }
                    if draft.name == previous.name { draft.name = account.name }
                    if draft.url == store.bookmarkAddress(previous) { draft.url = store.bookmarkAddress(account) }
                }
            TextField("Bookmark name", text: $draft.name).textFieldStyle(.roundedBorder)
            TextField("HTTPS address", text: $draft.url).textFieldStyle(.roundedBorder)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if store.saveBookmark(draft) { dismiss() } else { failure = store.error; store.error = nil } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 460).foregroundStyle(theme.ink).background(theme.base)
    }
}
