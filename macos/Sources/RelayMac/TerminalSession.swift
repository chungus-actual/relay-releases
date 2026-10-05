import AppKit
import WebKit

@MainActor
final class TerminalSession: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let address = URL(string: "relay-terminal://local/index.html")!
    let workspace = TerminalWorkspace()
    private weak var view: WKWebView?
    private var ready = false, closed = false, initialized = false
    private var attached: Set<String> = []
    private let assets: URL
    private let shell: String?
    private let home: String
    private var theme: [String: Any] = [:]
    private var quitObserver: NSObjectProtocol?
    private let profileKey: String
    private let preferences: UserDefaults
    private(set) var profile: TerminalProfile?
    var detectedProfiles: [TerminalProfile] = []
    var onCloseView: (() -> Void)?
    var onFocus: (() -> Void)?
    var onError: ((String) -> Void)?
    var confirmRestart: () -> Bool = {
        let alert = NSAlert(); alert.messageText = "End this shell and its running commands?"
        alert.addButton(withTitle: "Restart"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    init(assets: URL? = nil, shell: String? = nil, home: String = NSHomeDirectory(), accountID: UUID = UUID(), preferences: UserDefaults = .standard) {
        self.shell = shell; self.home = home
        self.preferences = preferences; profileKey = "terminal.profile." + accountID.uuidString
        if let data = preferences.data(forKey: profileKey) { profile = try? JSONDecoder().decode(TerminalProfile.self, from: data) }
        detectedProfiles = TerminalProfiles.discover()
        self.assets = assets ?? Bundle.main.resourceURL?.appendingPathComponent("Terminal") ?? URL(fileURLWithPath: "/missing-terminal-assets")
        super.init()
    }
    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(self, forURLScheme: "relay-terminal")
        configuration.userContentController.add(self, name: "relayTerminal")
    }
    func attach(_ view: WKWebView) {
        self.view = view; view.navigationDelegate = self; view.uiDelegate = self
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    func load() { guard !closed else { return }; view?.load(URLRequest(url: Self.address)) }
    func close() {
        guard !closed else { return }; closed = true; ready = false
        workspace.close(); attached.removeAll()
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "relayTerminal")
        view?.stopLoading()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }; quitObserver = nil
    }
    func setTheme(dark: Bool, background: NSColor, foreground: NSColor, accent: NSColor) {
        func hex(_ color: NSColor) -> String {
            let rgb = color.usingColorSpace(.sRGB) ?? .black
            return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
        let base = hex(background), ink = hex(foreground)
        theme = ["type": "theme", "dark": dark, "colors": ["background": base, "foreground": ink, "panel": base,
                 "card": base, "hover": dark ? "#34383e" : "#e1e5e9", "muted": dark ? "#adb4bd" : "#53616e",
                 "line": dark ? "#454c55" : "#bac3cd", "accent": hex(accent)]]
        post(theme)
    }
    private func post(_ message: [String: Any]) {
        guard ready, !closed, view?.url == Self.address,
              let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        view?.evaluateJavaScript("window.__relayTerminalReceive(\(json))") { [weak self] _, error in
            if let self, !self.closed, self.ready, let error { self.onError?("Terminal interface: \(error.localizedDescription)") }
        }
    }
    private func publish(focus: Bool = false) { var message = workspace.message; message["focus"] = focus; post(message) }
    private func publishProfile() {
        var choices = detectedProfiles.map { ["id": $0.id, "name": $0.name] }
        if let profile, !choices.contains(where: { $0["id"] == profile.id }) { choices.insert(["id": profile.id, "name": profile.name + " (saved)"], at: 0) }
        var options = ["fontFamily": TerminalProfiles.defaultFont] as [String: Any]
        if profile?.colors.isEmpty == false { options["minimumContrastRatio"] = 1 }
        post(["type": "profile", "selected": profile?.id ?? "", "profiles": choices,
              "options": options.merging(profile?.options ?? [:]) { _, new in new }, "colors": profile?.colors ?? [:]])
    }
    private func importProfile(_ id: String) {
        if id.isEmpty { profile = nil; preferences.removeObject(forKey: profileKey) }
        else {
            guard detectedProfiles.contains(where: { $0.id == id }) else {
                publishProfile(); status("Profile source unavailable · Rescan profiles to find it again"); return
            }
            let selected = TerminalProfiles.discover().first(where: { $0.id == id }) ?? detectedProfiles.first(where: { $0.id == id })!
            guard let data = try? JSONEncoder().encode(selected) else { return }
            profile = selected; preferences.set(data, forKey: profileKey)
        }
        publishProfile()
        status(profile.map { "Imported \($0.name) · Font, colors and compatible display settings" } ?? "Using Relay terminal defaults")
    }
    private func status(_ text: String, pane: String? = nil) { post(["type": "status", "data": text, "pane": pane as Any? ?? NSNull()]) }
    private func output(_ data: Data, pane: TerminalPane, completion: @escaping () -> Void = {}) {
        guard ready, !closed, let view, view.url == Self.address else { completion(); return }
        let message: [String: Any] = ["type": "output", "pane": pane.id, "encoding": "base64", "data": data.base64EncodedString()]
        Task { @MainActor in
            _ = try? await view.callAsyncJavaScript("return await window.__relayTerminalReceive(message)", arguments: ["message": message], in: nil, contentWorld: .page)
            completion()
        }
    }
    private func start(_ pane: TerminalPane) {
        if pane.started { pane.process?.resize(columns: pane.columns, rows: pane.rows); return }
        pane.started = true; pane.generation += 1
        let generation = pane.generation
        do {
            pane.process = try MacPTY(columns: pane.columns, rows: pane.rows, shell: shell, home: home, output: { [weak self, weak pane] data, completion in
                DispatchQueue.main.async {
                    guard let self, let pane, !self.closed, pane.generation == generation else { completion(); return }
                    pane.remember(data)
                    if self.attached.contains(pane.id) { self.output(data, pane: pane, completion: completion) }
                    else { completion() }
                }
            }, exited: { [weak self, weak pane] in
                DispatchQueue.main.async {
                    guard let self, let pane, !self.closed, pane.generation == generation else { return }
                    pane.status = "Shell exited"; self.status("Shell exited · Restart to continue", pane: pane.id); self.publish()
                }
            })
            pane.status = "Running"
        } catch { pane.status = "Start failed"; status(error.localizedDescription, pane: pane.id) }
        publish()
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.webView === view, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == Self.address, view?.url == Self.address,
              let data = message.body as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject: data), encoded.count <= 100_000 else { return }
        receive(data)
    }
    private func receive(_ data: [String: Any]) {
        func text(_ key: String) -> String? { data[key] as? String }
        func dimension(_ key: String, _ fallback: Int) -> Int {
            guard let n = data[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return fallback }
            return Int(min(500, max(2, n.doubleValue)))
        }
        func name() -> String? {
            guard let value = text("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf16.count <= 80,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) else {
                status("Use a name of 1–80 characters on one line."); return nil
            }
            return value
        }
        let type = text("type")
        if type == "ready" {
            guard !ready else { return }; ready = true
            if !initialized { workspace.addTab().addPane(); initialized = true }
            if !theme.isEmpty { post(theme) }; publishProfile(); publish(focus: true); return
        }
        guard ready else { return }
        let tab = workspace.tabs.first { tab in tab.panes.contains { $0.id == text("pane") } }
        let pane = tab?.panes.first { $0.id == text("pane") }
        if type == "pane-ready", let pane {
            pane.columns = dimension("cols", pane.columns); pane.rows = dimension("rows", pane.rows)
            if attached.insert(pane.id).inserted && !pane.history.isEmpty { output(pane.history, pane: pane) }
            start(pane); return
        }
        if type == "resize", let pane {
            pane.columns = dimension("cols", pane.columns); pane.rows = dimension("rows", pane.rows)
            pane.process?.resize(columns: pane.columns, rows: pane.rows); return
        }
        switch type {
        case "refresh-profiles": detectedProfiles = TerminalProfiles.discover(); publishProfile()
        case "import-profile": if let id = text("id") { importProfile(id) }
        case "new":
            guard workspace.tabs.count < 16 else { status("Sixteen tabs open · Close a tab to create another"); return }
            workspace.addTab().addPane(); publish(focus: true)
        case "select-tab":
            if let target = workspace.tabs.first(where: { $0.id == text("tab") }) { workspace.activeTab = target.id; publish(focus: true) }
        case "rename-tab":
            if let tab = workspace.tabs.first(where: { $0.id == text("tab") }), let name = name() { tab.name = name; publish() }
        case "close-tab":
            if let tab = workspace.tabs.first(where: { $0.id == text("tab") }) {
                tab.panes.forEach { attached.remove($0.id) }; workspace.closeTab(tab); publish(focus: true)
            }
        case "next", "previous":
            guard let index = workspace.tabs.firstIndex(where: { $0.id == workspace.activeTab }) else { return }
            workspace.activeTab = workspace.tabs[(index + (type == "next" ? 1 : workspace.tabs.count - 1)) % workspace.tabs.count].id
            publish(focus: true)
        case "close-view": onCloseView?()
        default:
            guard let tab, let pane, tab.id == workspace.activeTab else { return }
            switch type {
            case "focus": onFocus?(); if tab.activePane != pane.id { tab.activePane = pane.id; publish() }
            case "input":
                if tab.activePane == pane.id, let input = text("data"), pane.process?.write(input) != true { status("Input buffer full or shell closed; try again", pane: pane.id) }
            case "split":
                guard tab.panes.count < 4 else { status("Four panes open · Close a pane to split again"); return }
                tab.addPane(beside: pane.id, direction: text("direction") == "rows" ? "rows" : "columns"); publish(focus: true)
            case "rename-pane": if let name = name() { pane.name = name; publish() }
            case "close-pane":
                attached.remove(pane.id); tab.closePane(pane); if tab.panes.isEmpty { workspace.closeTab(tab) }; publish(focus: true)
            case "restart":
                guard confirmRestart(), !closed, workspace.current === tab, tab.panes.contains(where: { $0 === pane }) else { return }
                pane.close(); post(["type": "reset", "pane": pane.id]); start(pane); publish(focus: true)
            case "zoom": tab.activePane = pane.id; tab.zoomed = tab.panes.count > 1 && !tab.zoomed; publish(focus: true)
            case "resize-layout":
                if let node = tab.layout?.find(text("split")), node.pane == nil, let value = data["ratio"] as? Double, value.isFinite {
                    node.ratio = min(0.85, max(0.15, value)); publish()
                }
            default: break
            }
        }
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let types = ["index.html": "text/html", "terminal.js": "text/javascript", "xterm.js": "text/javascript",
                     "addon-fit.js": "text/javascript", "terminal.css": "text/css", "xterm.css": "text/css"]
        guard !closed, let url = task.request.url, url.scheme == "relay-terminal", url.host == "local",
              let mime = types[url.lastPathComponent], url.path == "/" + url.lastPathComponent,
              url.query == nil, let data = try? Data(contentsOf: assets.appendingPathComponent(url.lastPathComponent)) else {
            task.didFailWithError(URLError(.resourceUnavailable)); return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = !closed && action.targetFrame?.isMainFrame == true && action.request.url == Self.address && !action.shouldPerformDownload
        if allowed { ready = false; attached.removeAll() }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(!closed && response.isForMainFrame && response.response.url == Self.address && response.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onError?(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onError?(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; attached.removeAll(); workspace.close(); initialized = false
        onError?("Terminal renderer stopped. Reload to start a new shell.")
    }
}
