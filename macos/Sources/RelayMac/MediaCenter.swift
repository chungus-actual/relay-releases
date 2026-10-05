import Combine
import Foundation
import AppKit

struct ActiveMedia: Equatable {
    let accountID: UUID
    let reading: MediaReading
}

@MainActor
final class MediaCenter: ObservableObject {
    private struct Entry { weak var session: BrowserSession? }
    @Published private(set) var active: ActiveMedia?
    @Published private(set) var performingAction = false
    @Published private(set) var audioAccounts: Set<UUID> = []
    private(set) var floating: RetainedBrowserPanel?
    private var floatingAccount: UUID?
    private var floatingBusy = false
    private var playerColors: (dark: Bool, background: NSColor, foreground: NSColor, accent: NSColor)?
    @Published var error: String?
    private var entries: [UUID: Entry] = [:]
    private var polling: Task<Void, Never>?
    private var refreshing = false
    private var generation = 0

    init(preview: ActiveMedia? = nil) { self.active = preview }

    func register(_ session: BrowserSession) {
        guard MediaBridge.supports(session.service.id) else { return }
        generation += 1
        entries[session.accountID] = Entry(session: session)
        let id = session.accountID
        session.onMediaInvalidated = { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.audioAccounts.remove(id)
            if self.active?.accountID == id { self.active = nil }
            if self.floatingAccount == id { self.dock() }
        }
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func unregister(_ id: UUID) {
        generation += 1
        if floatingAccount == id { dock() }
        audioAccounts.remove(id)
        entries[id]?.session?.onMediaInvalidated = nil
        entries.removeValue(forKey: id)
        if active?.accountID == id { active = nil }
        if entries.isEmpty { polling?.cancel(); polling = nil }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let version = generation
        let prior = active?.accountID
        var readings: [ActiveMedia] = []
        var audio: Set<UUID> = []
        for (id, entry) in entries.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let session = entry.session else { continue }
            if await session.isPlayingAudio() { audio.insert(id) }
            guard version == generation, !Task.isCancelled else { return }
            guard let reading = await session.readMedia(),
                  reading.available || reading.playing else { continue }
            guard version == generation, !Task.isCancelled else { return }
            readings.append(ActiveMedia(accountID: id, reading: reading))
        }
        guard version == generation, !Task.isCancelled else { return }
        if audioAccounts != audio { audioAccounts = audio }
        let playing = readings.filter { $0.reading.playing }
        let candidates = playing.isEmpty ? readings : playing
        let chosen = candidates.first { $0.accountID == prior } ?? candidates.first
        if active != chosen { active = chosen }
    }
    func act(_ action: MediaAction) async {
        guard !performingAction, let current = active, let session = entries[current.accountID]?.session else { return }
        performingAction = true
        defer { performingAction = false }
        let version = generation
        if !(await session.actOnMedia(action)), version == generation {
            error = "The service could not perform that media action. Open its page to continue playback."
        }
        await refresh()
    }
    func updatePlayerAppearance(dark: Bool, background: NSColor, foreground: NSColor, accent: NSColor) {
        playerColors = (dark, background, foreground, accent)
        floating?.applyAppearance(dark: dark, background: background, foreground: foreground, accent: accent)
    }
    func floatActive() async {
        guard !floatingBusy else { return }
        floatingBusy = true
        defer { floatingBusy = false }
        if let floating { floating.makeKeyAndOrderFront(nil); return }
        guard let active, let session = entries[active.accountID]?.session, session.canFloatMedia else {
            error = "Open the media in the main service page to float it."; return
        }
        session.dockServiceWindow(select: false)
        let version = generation
        guard await session.actOnFloatingMedia(.float), version == generation, session.serviceWindow == nil else { return }
        let panel = RetainedBrowserPanel(title: session.accountName, browser: session.contentView,
            action: { [weak session] in
                guard let session else { return }
                Task { await session.toggleFloatingPlayback() }
            }, dock: { [weak self] in self?.dock() })
        if let c = playerColors { panel.applyAppearance(dark: c.dark, background: c.background, foreground: c.foreground, accent: c.accent) }
        floatingAccount = session.accountID; floating = panel
        panel.makeKeyAndOrderFront(nil)
    }
    func dock(account: UUID) { if floatingAccount == account { dock() } }
    func dock() {
        guard let panel = floating else { return }
        let session = floatingAccount.flatMap { entries[$0]?.session }
        floating = nil; floatingAccount = nil
        panel.restoreBrowser(); panel.close()
        if let session { Task { _ = await session.actOnFloatingMedia(.dock) } }
    }
    deinit { polling?.cancel() }
}

@MainActor
final class RetainedBrowserPanel: NSPanel, NSToolbarDelegate {
    private let browser: NSView
    private weak var originalHost: NSView?
    private let onDock: () -> Void
    private var restoring = false
    private var controls: [NSToolbarItem] = []
    init(title: String, browser: NSView, media: Bool = true, action: (() -> Void)? = nil, dock: @escaping () -> Void) {
        self.browser = browser; originalHost = browser.superview; onDock = dock
        let width: CGFloat = media ? 520 : 1000, height: CGFloat = media ? 340 : 700
        super.init(contentRect: NSRect(x: 180, y: 180, width: width, height: height),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        self.title = title + (media ? " · Floating player" : " · Relay"); level = media ? .floating : .normal; isReleasedWhenClosed = false
        // PiP keeps its accessible/window-menu name without reserving title text
        // space that could push playback controls into toolbar overflow.
        titleVisibility = media ? .hidden : .visible
        appearance = browser.appearance
        hidesOnDeactivate = false; minSize = NSSize(width: 360, height: 200)
        collectionBehavior = [.fullScreenPrimary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        func control(_ id: String, _ label: String, _ symbol: String, _ action: @escaping () -> Void) {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(id))
            item.label = label; item.paletteLabel = label; item.toolTip = label
            item.visibilityPriority = .user
            let button = MediaPanelButton(label, symbol: symbol, action: action)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 24)])
            item.view = button; controls.append(item)
        }
        if let action { control("relay.playback", "Play / pause", "playpause", action) }
        control("relay.fullscreen", "Full screen", "arrow.up.left.and.arrow.down.right", { [weak self] in self?.toggleFullScreen(nil) })
        control("relay.dock", "Dock in Relay", "arrow.down.right.and.arrow.up.left", dock)
        let toolbar = NSToolbar(identifier: "relay.retained-browser")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false; toolbar.autosavesConfiguration = false
        self.toolbar = toolbar; toolbarStyle = .unifiedCompact
        browser.removeFromSuperview(); browser.isHidden = false
        content.addSubview(browser); contentView = content
        browser.frame = content.bounds; browser.autoresizingMask = [.width, .height]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] + controls.map(\.itemIdentifier) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        controls.first { $0.itemIdentifier == identifier }
    }
    func applyAppearance(dark: Bool, background: NSColor, foreground: NSColor, accent: NSColor) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        backgroundColor = background; titlebarAppearsTransparent = true
        contentView?.wantsLayer = true; contentView?.layer?.backgroundColor = background.cgColor
        for button in controls.compactMap({ $0.view as? NSButton }) {
            button.contentTintColor = foreground; button.bezelColor = background
        }
    }
    func restoreBrowser() {
        restoring = true; browser.removeFromSuperview(); browser.autoresizingMask = []
        if let deck = originalHost as? BrowserDeckView { deck.restoreFloatingBrowser(browser) }
        else { originalHost?.addSubview(browser) }
    }
    override func close() { if !restoring { onDock() } else { super.close() } }
}

@MainActor
private final class MediaPanelButton: NSButton {
    private let actionBlock: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        actionBlock = action
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(performAction)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageOnly; toolTip = title }
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func performAction() { actionBlock() }

}
