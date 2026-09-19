import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var store: RelayStore
    @ObservedObject private var downloads: DownloadCenter
    @ObservedObject private var unread: UnreadCenter
    init(store: RelayStore) { self.store = store; self.downloads = store.downloads; self.unread = store.unread }
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.openWindow) private var openWindow
    private var theme: ShellTheme { ShellTheme(settings: store.appearance, system: systemScheme) }
    private var selectedAccount: Account? { store.preferences.accounts.first { $0.id == store.preferences.selected } }
    private var session: BrowserSession? {
        guard store.localPage == "service", let id = store.preferences.selected else { return nil }
        return store.session(for: id)
    }
    private var compact: Bool { store.appearance.compact }
    private var railWidth: CGFloat { compact ? 36 : 64 }

    var body: some View {
        VStack(spacing: 0) {
            caption
            Rectangle().fill(theme.line).frame(height: 1)
            if store.appearance.topTabs {
                rail(horizontal: true).frame(height: compact ? 40 : 50)
                Rectangle().fill(theme.line).frame(height: 1)
                workspaceWithDownloads
            } else {
                HStack(spacing: 0) {
                    rail(horizontal: false).frame(width: railWidth)
                    Rectangle().fill(theme.line).frame(width: 1)
                    workspaceWithDownloads
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(theme.ink)
        .background(theme.base)
        .tint(theme.accent)
        .preferredColorScheme(store.appearance.mode == "System" ? nil : theme.dark ? .dark : .light)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 540)
        .background(WindowSetup())
        .onAppear {
            store.runShellCheck()
            store.updates.start()
            store.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .sheet(item: $store.editingAccount) { account in AccountEditor(store: store, account: account, theme: theme) }
        .confirmationDialog("Remove account?", isPresented: Binding(
            get: { store.removingAccount != nil }, set: { if !$0 { store.removingAccount = nil } }), presenting: store.removingAccount) { account in
                Button("Remove \(account.name)", role: .destructive) { store.remove(account) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You can restore this account from Settings.")
            }
        .alert("Relay", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var caption: some View {
        HStack(spacing: 12) {
            // Reserve room for the native macOS traffic lights.
            Color.clear.frame(width: 70, height: 1)
            RelayMark().stroke(theme.accent, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                .frame(width: 15, height: 15).accessibilityLabel("Relay")
            if let account = selectedAccount, let session {
                BrowserCaption(session: session, account: account, theme: theme)
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    browserActions(session).fixedSize()
                    CompactNavigation(session: session, store: store, account: account)
                }
            } else {
                GreetingView(unread: unread, theme: theme)
                Spacer()
            }
            MediaControlsView(store: store, center: store.media, theme: theme)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(CaptionDragArea())
        .background(theme.panel)
    }

    private func browserActions(_ session: BrowserSession) -> some View {
        HStack(spacing: 2) {
            if let account = selectedAccount { AccountZoomControl(store: store, account: account, theme: theme) }
            HistoryButtons(session: session, theme: theme)
            if let account = selectedAccount {
                tool(account.audioMuted == true ? "Unmute media audio" : "Mute media audio",
                     account.audioMuted == true ? "speaker.slash.fill" : "speaker.wave.2") {
                    store.setAudioMuted(account, muted: account.audioMuted != true)
                }
            }
            tool("Reload", "arrow.clockwise") { session.reload() }
            tool("Service home", "house") { session.load(session.service.url) }
            Rectangle().fill(theme.line).frame(width: 1, height: 16).padding(.horizontal, 5)
            tool("Open externally", "arrow.up.right.square") {
                NSWorkspace.shared.open(session.address ?? session.service.url)
            }
        }
    }

    private func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.muted).frame(width: 28, height: 28)
        }.buttonStyle(ShellButtonStyle(theme: theme)).help(name).accessibilityLabel(name)
    }

    private func rail(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
        return layout {
            railButton("Activity", symbol: "bubble.left.and.bubble.right", selected: store.localPage == "activity") {
                store.showLocal("activity")
            }
            Rectangle().fill(theme.line)
                .frame(width: horizontal ? 1 : compact ? 16 : 26, height: horizontal ? 26 : 1)
                .padding(horizontal ? .horizontal : .vertical, 8)
            ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                let serviceLayout = horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
                serviceLayout {
                    ForEach(store.shortcutAccounts) { account in
                        if let service = store.services.first(where: { $0.id == account.serviceID }) {
                            serviceRailButton(service, account: account)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .contextMenu { railAccountMenu }
            railButton(compact ? "Expand rail" : "Compact rail", symbol: compact ? "chevron.right" : "chevron.left") {
                store.appearance.compact.toggle()
            }
            ResourcePulse(monitor: store.resources, theme: theme, compact: compact)
            railButton(store.quiet ? "Unmute notifications" : "Quiet notifications", symbol: store.quiet ? "bell.slash.fill" : "bell", selected: store.quiet) {
                store.quiet.toggle()
            }
            railButton("Downloads", symbol: "arrow.down.to.line", selected: downloads.isOpen) { downloads.isOpen.toggle() }
            railButton("Settings", symbol: "gearshape", selected: store.localPage == "settings") {
                store.showLocal("settings")
            }
        }
        .padding(horizontal ? .horizontal : .vertical, horizontal ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            theme.panel.contentShape(Rectangle()).contextMenu { railAccountMenu }
        }
    }

    @ViewBuilder private var railAccountMenu: some View {
        if !store.hiddenAccounts.isEmpty {
            ForEach(store.hiddenAccounts) { account in
                Button("Open \(account.name)") { store.reveal(account) }
            }
            Divider()
        }
        Menu("Add account") {
            ForEach(store.services) { service in
                Button(service.name) { store.add(service) }
            }
        }
        Button("Settings…") { store.showLocal("settings") }
    }

    private func railButton(_ name: String, symbol: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: compact ? 13 : 16))
                .foregroundStyle(selected ? theme.accent : theme.muted)
                .frame(width: compact ? 30 : 46, height: compact ? 32 : 38)
        }.buttonStyle(ShellButtonStyle(theme: theme, selected: selected)).help(name).accessibilityLabel(name)
    }

    private func serviceRailButton(_ service: Service, account: Account) -> some View {
        let selected = store.preferences.selected == account.id
        let extra = store.preferences.accounts.first(where: { $0.serviceID == account.serviceID })?.id != account.id
        return Button {
            store.select(account)
        } label: {
            ZStack(alignment: .leading) {
                ServiceIcon(id: service.id, size: compact ? 18 : 21)
                    .foregroundStyle(selected ? theme.accent : !store.isLoaded(account) ? theme.muted.opacity(0.7) : theme.ink)
                    .frame(width: compact ? 30 : 46, height: compact ? 34 : 44)
                if selected { RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 3, height: 14) }
                if extra {
                    Text(String(account.name.prefix(1))).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(4)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            UnreadBadge(text: unread.badge(for: account.id), theme: theme, compact: compact)
                .allowsHitTesting(false)
        }
        .buttonStyle(ShellButtonStyle(theme: theme, selected: selected))
        .help(account.name).accessibilityLabel(account.name)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard press.modifiers.contains([.command, .shift]) else { return .ignored }
            store.move(account, by: press.key == .leftArrow || press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .overlay {
            AccountDragSource(payload: store.accountDragScope.payload(for: account.id), serviceID: account.serviceID) {
                store.select(account)
            }.accessibilityHidden(true)
        }
        .accountDropTarget(store: store, account: account, horizontal: store.appearance.topTabs, theme: theme)
        .contextMenu {
            Button("Open") { store.select(account) }
            if store.isLoaded(account) { Button("Unload") { store.unload(account) } }
            Button("Dismiss unread in Relay") { unread.dismiss(account.id) }
                .disabled(unread.badge(for: account.id).isEmpty)
            Menu("Zoom") {
                ForEach([50, 75, 100, 125, 150, 175, 200], id: \.self) { percent in
                    Button("\(percent)%\(Int((account.zoom * 100).rounded()) == percent ? " ✓" : "")") {
                        store.setZoom(account, to: Double(percent) / 100)
                    }
                }
            }
            Toggle("Mute media audio", isOn: Binding(get: { account.audioMuted == true },
                set: { store.setAudioMuted(account, muted: $0) }))
            Toggle("Keep awake in background", isOn: Binding(get: { account.staysAwake },
                set: { store.setKeepLive(account, enabled: $0) }))
            if account.serviceID == "gmail" {
                Picker("Gmail badge", selection: Binding(get: { account.gmailAllUnread == true },
                    set: { store.setGmailAllUnread(account, enabled: $0) })) {
                    Text("New since launch").tag(false)
                    Text("All unread").tag(true)
                }
            }
            Toggle("Notifications", isOn: Binding(get: { account.notifications != false },
                set: { store.setAccountNotifications(account, enabled: $0) }))
            Button("Add another account") { store.add(service) }
            if ChromiumRuntime.isEnabled {
                Menu("Browser engine") {
                    Button("WebKit\(account.usesChromium ? "" : " ✓")") { store.setBrowserEngine(account, chromium: false) }
                    Button("Chromium Experimental\(account.usesChromium ? " ✓" : "")") { store.setBrowserEngine(account, chromium: true) }
                        .disabled(!ChromiumRuntime.isEnabled)
                }
            }
            Button("Rename…") { store.editingAccount = account }
            Button("Hide shortcut") { store.setVisible(account, false) }
            Button("Move earlier") { store.move(account, by: -1) }
            Button("Move later") { store.move(account, by: 1) }
            Divider()
            Button("Remove…", role: .destructive) { store.removingAccount = account }
        }
    }

    private var workspaceWithDownloads: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                if downloads.isOpen && geometry.size.width >= 900 { DownloadsView(center: downloads, theme: theme) }
            }
            .overlay(alignment: .trailing) {
                if downloads.isOpen && geometry.size.width < 900 {
                    DownloadsView(center: downloads, theme: theme).shadow(color: .black.opacity(0.2), radius: 12, x: -4)
                }
            }
        }
    }

    @ViewBuilder private var workspace: some View {
        let current = session
        ZStack {
            BrowserDeck(sessions: store.loadedSessions, selected: current, dark: theme.dark)
            if let current {
                SessionErrorView(session: current, theme: theme)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                localWorkspace
            }
        }
    }

    private var localWorkspace: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.localPage == "settings" ? "Settings" : "Activity").font(.system(size: 16, weight: .semibold))
                if store.localPage != "settings" {
                    Text("The gang's nonsense, centralized").font(.system(size: 11)).foregroundStyle(theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).frame(height: 64)
            Rectangle().fill(theme.line).frame(height: 1)
            ScrollView {
                Group {
                    if store.localPage == "settings" { ShellSettings(store: store, theme: theme) }
                    else { activity }
                }
                .frame(maxWidth: 920).padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 26) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(store.shortcutAccounts) { account in
                    if let service = store.services.first(where: { $0.id == account.serviceID }) {
                        serviceCard(service, account: account) { store.select(account) }
                    }
                }
            }
            if store.shortcutAccounts.isEmpty {
                Button("Manage services") { store.showLocal("settings") }
                    .foregroundStyle(theme.accent).buttonStyle(.plain)
            }
            ActivityFeed(store: store, center: unread, theme: theme)
        }
    }

    private func serviceCard(_ service: Service, account: Account, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ServiceIcon(id: service.id).foregroundStyle(store.isLoaded(account) ? theme.accent : theme.muted).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(store.isLoaded(account) ? "Open" : "Load  +").font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)
                UnreadBadge(text: unread.badge(for: account.id), theme: theme)
            }.padding(.horizontal, 14).frame(height: 74)
        }.buttonStyle(ShellButtonStyle(theme: theme, bordered: true))
    }
}

struct SessionErrorView: View {
    @ObservedObject var session: BrowserSession
    let theme: ShellTheme
    var body: some View {
        if let error = session.error {
            HStack {
                Text(error).font(.system(size: 12)).textSelection(.enabled)
                Spacer()
                Button("Try again") { session.reload() }
            }.padding(16).background(theme.card)
        }
    }
}

extension View {
    func shellCard(_ theme: ShellTheme) -> some View {
        background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line))
    }
}

struct WindowSetup: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.isMovableByWindowBackground = false
        }
    }
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Only the caption starts native window movement. Content drags belong to the
// service rail, Settings, or the embedded page.
private struct CaptionDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct HistoryButtons: View {
    @ObservedObject var session: BrowserSession
    let theme: ShellTheme
    var body: some View {
        HStack(spacing: 2) {
            Button { session.goBack() } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }.disabled(!session.canGoBack).help("Back (⌘[)").accessibilityLabel("Back")
            Button { session.goForward() } label: {
                Image(systemName: "arrow.right").frame(width: 28, height: 28)
            }.disabled(!session.canGoForward).help("Forward (⌘])").accessibilityLabel("Forward")
        }
        .font(.system(size: 12)).foregroundStyle(theme.muted)
        .buttonStyle(ShellButtonStyle(theme: theme))
    }
}
