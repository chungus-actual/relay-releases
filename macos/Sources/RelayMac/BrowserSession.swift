import AppKit
import Combine
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let service: Service
    let webView: WKWebView
    let accountID: UUID
    var captureLinks = false { didSet { chromium?.captureLinks = captureLinks } }
    var openExternalURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var chromium: ChromiumSession?
    private var activeChromiumMediaPage: Int?
    var contentView: NSView { chromium?.view ?? webView }
    func load(_ url: URL) {
        if let chromium { chromium.command("load", ["url": url.absoluteString]) }
        else {
            // Google apps can cache an unsupported-browser shell across user-agent changes.
            // Fetch a fresh document while retaining cookies and website storage.
            webView.load(URLRequest(url: url, cachePolicy: ["gmail", "calendar"].contains(service.id) ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy))
        }
    }
    func reload() {
        if let chromium { chromium.command("reload") }
        else if ["gmail", "calendar"].contains(service.id) { webView.reloadFromOrigin() }
        else { webView.reload() }
    }
    func goBack() { if let chromium { chromium.command("back") } else { webView.goBack() } }
    func goForward() { if let chromium { chromium.command("forward") } else { webView.goForward() } }
    func setZoom(_ zoom: Double) { if let chromium { chromium.command("zoom", ["value": zoom]) } else { webView.pageZoom = zoom } }
    func setMuted(_ muted: Bool) {
        if let chromium { chromium.command("mute", ["value": muted]) }
        else { pageControls.setMuted(muted) }
    }
    @Published private(set) var address: URL?
    private var popupOrigins: [ObjectIdentifier: (URL?, Bool)] = [:]
    var accountName: String
    let downloads: DownloadCenter
    @Published var error: String?
    private(set) var keepLive: Bool
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    var onNavigationChanged: (() -> Void)?
    private var navigationObservations: [NSKeyValueObservation] = []
    private var popups: [NSWindow] = []
    var onUnread: ((UnreadReading) -> Void)?
    var onNativeNotification: ((String, String, String) -> Void)?
    private var unreadObservations: [NSKeyValueObservation] = []
    private var unreadPoll: Task<Void, Never>?
    private var unreadGeneration = 0
    private var unreadReadingInProgress = false
    private var closed = false
    private var mediaGeneration = 0
    private weak var activeMediaView: WKWebView?
    let pageControls = PageControls()
    private var recovery = RendererRecovery()
    private var recoveryTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?

    init(account: Account, service: Service, downloads: DownloadCenter,
         dataStore: WKWebsiteDataStore? = nil, loadImmediately: Bool = true, chromiumTesting: Bool = false) {
        self.service = service
        self.accountID = account.id
        self.accountName = account.name
        self.downloads = downloads
        self.keepLive = account.staysAwake
        // Normal builds resume the account's existing WebKit profile even if a prior
        // experimental build selected Chromium. Neither stored profile is changed.
        let useChromium = account.usesChromium && ChromiumRuntime.isEnabled
        let configuration = WKWebViewConfiguration()
        configuration.preferences.inactiveSchedulingPolicy = keepLive ? .none : .suspend
        configuration.websiteDataStore = dataStore ?? (useChromium ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: account.id))
        // Every WebKit service needs a desktop browser version for provider checks.
        // Preserve WebKit's generated Mac/platform/engine tokens; popups inherit this
        // configuration. Chromium uses its own native engine identification.
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        if service.id == "messenger" {
            configuration.userContentController.addUserScript(WKUserScript(source: MessengerChrome.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if MediaBridge.supports(service.id) {
            configuration.userContentController.addUserScript(WKUserScript(source: MediaBridge.script(for: service.id),
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        pageControls.muted = account.audioMuted == true
        pageControls.install(configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        pageControls.session = self
        if useChromium && dataStore == nil {
            do {
                let engine = try ChromiumSession(account: account, service: service, testing: chromiumTesting)
                chromium = engine
                engine.notificationsAllowed = { [weak self] in self?.pageControls.notificationsAllowed?() == true }
                engine.onNotification = { [weak self] id, title, body in
                    guard let self else { return }
                    if self.pageControls.notificationsAllowed?() == true { self.onNativeNotification?(id, title, body) }
                    else { self.chromium?.command("notification", ["id": id]) }
                }
                engine.onDownload = { [weak self, weak engine] event, data in
                    guard let self, let engine else { return }
                    self.downloads.chromiumEvent(event, data: data, session: engine,
                        account: Account(id: self.accountID, serviceID: self.service.id, name: self.accountName))
                }
                engine.onState = { [weak self] in
                    guard let self, let state = self.chromium?.pages[0], !self.closed else { return }
                    if self.address != state.url { self.address = state.url; self.unreadGeneration += 1 }
                    if self.canGoBack != state.back || self.canGoForward != state.forward {
                        self.canGoBack = state.back; self.canGoForward = state.forward; self.onNavigationChanged?()
                    }
                    Task { @MainActor [weak self] in await self?.refreshUnread() }
                }
                engine.onLoading = { [weak self] page in
                    guard let self else { return }
                    self.mediaGeneration += 1; self.activeChromiumMediaPage = nil
                    if page == 0 { self.error = nil; self.unreadGeneration += 1; self.onUnread?(.unknown); self.recoveryTask?.cancel() }
                }
                engine.onLoaded = { [weak self] page, ok in
                    guard let self, page == 0 else { return }
                    if !ok { self.error = "The page could not load." }
                    Task { @MainActor [weak self] in await self?.refreshUnread() }
                }
                engine.onTerminated = { [weak self] page in
                    guard let self else { return }
                    if page == 0 { self.webViewWebContentProcessDidTerminate(self.webView) }
                    else { self.error = "A service popup stopped. Reopen it from the service page." }
                }
                startUnreadPoll()
                if loadImmediately { load(service.url) }
            } catch { self.error = error.localizedDescription }
            return
        }
        configure(webView)
        let historyChanged: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                let back = self.webView.canGoBack, forward = self.webView.canGoForward
                guard self.canGoBack != back || self.canGoForward != forward else { return }
                self.canGoBack = back
                self.canGoForward = forward
                self.onNavigationChanged?()
            }
        }
        navigationObservations = [
            webView.observe(\.canGoBack, options: [.new]) { _, _ in historyChanged() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in historyChanged() }
        ]
        webView.pageZoom = account.zoom
        observeUnread()
        if loadImmediately { load(service.url) }
        if loadImmediately, service.id == "gmail", ProcessInfo.processInfo.arguments.contains("--gmail-diagnostics") {
            diagnosticsTask = Task { @MainActor [weak self] in
                for stage in ["initial", "revalidated"] {
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                    guard let self, !self.closed else { return }
                    let script = """
                    (() => {
                      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                      let unsupported = false;
                      while (walker.nextNode()) {
                        const value = walker.currentNode.textContent.trim();
                        if (value.startsWith('This browser version is no longer supported')) { unsupported = true; break; }
                      }
                      return {userAgent:navigator.userAgent, origin:location.origin, loading:document.readyState,
                              unsupported, serviceWorker:!!navigator.serviceWorker?.controller};
                    })()
                    """
                    if let value = try? await self.webView.evaluateJavaScript(script) { print("Gmail diagnostic \(stage): \(value)"); fflush(stdout) }
                    if stage == "initial" { self.webView.reloadFromOrigin() }
                }
            }
        }
    }

    func setKeepLive(_ value: Bool) {
        keepLive = value
        if let chromium { chromium.command("awake", ["value": value]); return }
        webView.configuration.preferences.inactiveSchedulingPolicy = value ? .none : .suspend
        for window in popups {
            (window.contentView as? WKWebView)?.configuration.preferences.inactiveSchedulingPolicy = value ? .none : .suspend
        }
    }

    var browserViews: [WKWebView] { [webView] + popups.compactMap { $0.contentView as? WKWebView } }

    private func mayPollPage(_ view: WKWebView) -> Bool {
        keepLive || (view.window != nil && !view.isHiddenOrHasHiddenAncestor) || view.cameraCaptureState != .none || view.microphoneCaptureState != .none
    }

    func readMedia() async -> MediaReading? {
        guard !closed, MediaBridge.supports(service.id) else { return nil }
        if let chromium {
            let generation = mediaGeneration
            var candidate: (Int, MediaReading)?
            for (page, state) in chromium.pages where !state.sleeping && state.url.map(service.contains) == true {
                guard let value = try? await chromium.evaluate("return window.__relayMedia?.read() ?? null;", page: page),
                      generation == mediaGeneration, !closed, chromium.pages[page]?.url == state.url,
                      let reading = MediaReading(value: value), reading.available || reading.playing else { continue }
                if candidate == nil || (reading.playing && candidate?.1.playing != true) ||
                    (reading.playing == candidate?.1.playing && page == activeChromiumMediaPage) { candidate = (page, reading) }
            }
            guard !closed, generation == mediaGeneration else { return nil }
            activeChromiumMediaPage = candidate?.0
            return candidate?.1
        }
        let generation = mediaGeneration
        let prior = activeMediaView
        var candidate: (WKWebView, MediaReading)?
        for view in browserViews {
            guard !view.isLoading, let address = view.url, service.contains(address) else { continue }
            if !mayPollPage(view) {
                let playback = await view.requestMediaPlaybackState()
                guard playback == .playing else { continue }
            }
            guard let value = try? await view.evaluateJavaScript("window.__relayMedia?.read() ?? null"),
                  generation == mediaGeneration, !closed, view.url == address,
                  browserViews.contains(where: { $0 === view }),
                  let reading = MediaReading(value: value), reading.available || reading.playing else { continue }
            if reading.playing {
                if candidate?.1.playing != true || view === prior { candidate = (view, reading) }
            } else if candidate == nil || (candidate?.1.playing != true && view === prior) {
                candidate = (view, reading)
            }
        }
        guard !closed, generation == mediaGeneration else { return nil }
        activeMediaView = candidate?.0
        return candidate?.1
    }

    func actOnMedia(_ action: MediaAction) async -> Bool {
        if let chromium {
            guard !closed, let page = activeChromiumMediaPage, let url = chromium.pages[page]?.url, service.contains(url) else { return false }
            let generation = mediaGeneration
            let result = try? await chromium.evaluate("return window.__relayMedia?.act('\(action.rawValue)') ?? false;", page: page)
            return !closed && generation == mediaGeneration && chromium.pages[page]?.url == url && result as? Bool == true
        }
        guard !closed, MediaBridge.supports(service.id), let view = activeMediaView,
              browserViews.contains(where: { $0 === view }), !view.isLoading,
              let address = view.url, service.contains(address) else { return false }
        let generation = mediaGeneration
        let result = try? await view.callAsyncJavaScript("return await window.__relayMedia?.act(action) ?? false",
            arguments: ["action": action.rawValue], in: nil, contentWorld: .page)
        return !closed && generation == mediaGeneration && view.url == address && result as? Bool == true
    }

    static var safariApplicationName: String {
        let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let installed = safariURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let components = installed?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        let valid = !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        // Safari updates independently on older macOS releases; prefer its installed version.
        // Fall back to the Safari baseline shipped with the supported OS if it cannot be found.
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let baseline = os >= 26 ? os : os >= 15 ? 18 : 17
        let version = valid ? installed! : "\(baseline).0"
        return "Version/\(version) Safari/605.1.15"
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
    }

    private func observeUnread() {
        let changed: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if self.address != self.webView.url { self.address = self.webView.url }
                self.unreadGeneration += 1
                await self.refreshUnread()
            }
        }
        unreadObservations = [
            webView.observe(\.title, options: [.new]) { _, _ in changed() },
            webView.observe(\.url, options: [.new]) { _, _ in changed() }
        ]
        startUnreadPoll()
    }

    private func startUnreadPoll() {
        if ["messenger", "gmail"].contains(service.id) {
            unreadPoll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard let self, !self.closed else { return }
                    await self.refreshUnread()
                }
            }
        }
    }

    func becameVisible() async {
        guard !closed, service.id == "messenger" else { return }
        await Task.yield()
        guard !closed, contentView.window != nil, !contentView.isHiddenOrHasHiddenAncestor else { return }
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        contentView.needsDisplay = true
        let script = "window.__relayMessengerChrome?.activate()"
        if let chromium { _ = try? await chromium.evaluate(script) }
        else { _ = try? await webView.evaluateJavaScript(script) }
    }

    func refreshUnread() async {
        if let chromium {
            guard !closed, let state = chromium.pages[0], !state.sleeping else { return }
            guard ["messenger", "gmail"].contains(service.id) else {
                onUnread?(UnreadRules.titleReading(state.title, service: service, url: state.url)); return
            }
            guard let address = state.url, (service.id == "gmail" ? GmailUnread.page(address) : UnreadRules.messengerPage(address)), !unreadReadingInProgress else { return }
            unreadReadingInProgress = true
            defer { unreadReadingInProgress = false }
            let generation = unreadGeneration
            if let value = try? await chromium.evaluate("return " + (service.id == "gmail" ? GmailUnread.script : MessengerUnread.script)),
               !closed, generation == unreadGeneration, chromium.pages[0]?.url == address,
               let reading = MessengerUnread.reading(value, prefix: service.id + ":") { onUnread?(reading) }
            return
        }
        guard !closed, !webView.isLoading, mayPollPage(webView) else { return }
        guard ["messenger", "gmail"].contains(service.id) else {
            onUnread?(UnreadRules.titleReading(webView.title ?? "", service: service, url: webView.url))
            return
        }
        guard let address = webView.url, (service.id == "gmail" ? GmailUnread.page(address) : UnreadRules.messengerPage(address)) else { onUnread?(.unknown); return }
        guard !unreadReadingInProgress else { return }
        unreadReadingInProgress = true
        let generation = unreadGeneration
        defer { unreadReadingInProgress = false }
        do {
            let value = try await webView.evaluateJavaScript(service.id == "gmail" ? GmailUnread.script : MessengerUnread.script, in: nil, contentWorld: .defaultClient)
            guard !closed, generation == unreadGeneration, webView.url == address,
                  let value, let reading = MessengerUnread.reading(value, prefix: service.id + ":") else { return }
            onUnread?(reading)
        } catch {
            // Navigation, loading, or an unavailable page must not turn into a fabricated count.
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false, var origin = popupOrigins[ObjectIdentifier(webView)], BrowserRules.googleSignIn(url) {
            origin.1 = true
            popupOrigins[ObjectIdentifier(webView)] = origin
        }
        // Blob/data downloads are produced by chat attachments and never opened externally.
        if action.shouldPerformDownload, ["https", "blob", "data"].contains(url.scheme ?? "") {
            decisionHandler(.download)
            return
        }
        if url.scheme == "blob" { decisionHandler(.allow); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if action.targetFrame?.isMainFrame != false,
           action.navigationType == .linkActivated, !captureLinks,
           let target = BrowserRules.webLink(url), !service.allowsEmbedded(target),
           !BrowserRules.providerAttachment(target, service: service.id),
           !BrowserRules.googleLanding(target, service: service.id) {
            openExternalURL(target)
            decisionHandler(.cancel)
            return
        }
        guard url.scheme == "https" || (captureLinks && url.scheme == "http") else {
            if url.scheme == "http", action.navigationType == .linkActivated {
                openExternalURL(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    private func track(_ download: WKDownload) {
        downloads.track(download, account: Account(id: accountID, serviceID: service.id, name: accountName))
    }

    func close() {
        closed = true
        diagnosticsTask?.cancel(); diagnosticsTask = nil
        chromium?.close(); chromium = nil
        pageControls.close()
        recoveryTask?.cancel()
        recoveryTask = nil
        activeMediaView = nil
        mediaGeneration += 1
        unreadGeneration += 1
        unreadPoll?.cancel()
        unreadPoll = nil
        unreadObservations.removeAll()
        onUnread = nil
        navigationObservations.removeAll()
        onNavigationChanged = nil
        let windows = popups
        popups.removeAll()
        popupOrigins.removeAll()
        for window in windows {
            (window.contentView as? WKWebView)?.stopLoading()
            window.close()
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Upload files · \(frame.securityOrigin.host)"
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    private func dialog(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? service.name : frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = webView.window else { completionHandler(); return }
        dialog(message, frame: frame).beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = webView.window else { completionHandler(false); return }
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in completionHandler(result == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let alert = dialog(prompt, frame: frame)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { result in completionHandler(result == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        if let url = action.request.url, url.absoluteString != "about:blank",
           !service.allowsEmbedded(url), !BrowserRules.googleLanding(url, service: service.id),
           !BrowserRules.providerAttachment(url, service: service.id),
           !(captureLinks && ["http", "https"].contains(url.scheme ?? "")) {
            if ["http", "https"].contains(url.scheme ?? "") { openExternalURL(url) }
            return nil
        }
        // Use WebKit's supplied configuration to retain opener semantics and account storage.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        popupOrigins[ObjectIdentifier(popup)] = (webView.url, BrowserRules.googleSignIn(action.request.url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = service.name
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        popups.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        let owned = webView === self.webView || popups.contains { $0.contentView === webView }
        guard !closed, owned, let address = components.url,
              service.allowsMediaPermissionRequest(origin: address, page: webView.url) else {
            decisionHandler(.deny)
            return
        }
        // WebKit presents the requesting site and manages its permission choice;
        // macOS separately controls Relay's access to the physical devices.
        decisionHandler(.prompt)
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if popups.contains(where: { $0 === window }) {
            mediaGeneration += 1
            if window.contentView === activeMediaView { activeMediaView = nil }
        }
        if let view = window.contentView as? WKWebView { popupOrigins.removeValue(forKey: ObjectIdentifier(view)) }
        popups.removeAll { $0 === window }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        if var origin = popupOrigins[ObjectIdentifier(webView)], BrowserRules.googleSignIn(webView.url) {
            origin.1 = true
            popupOrigins[ObjectIdentifier(webView)] = origin
        }
        if webView === self.webView { recoveryTask?.cancel(); recoveryTask = nil }
        mediaGeneration += 1
        if activeMediaView === webView { activeMediaView = nil }
        if webView === self.webView { unreadGeneration += 1; onUnread?(.unknown) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let origin = popupOrigins[ObjectIdentifier(webView)], self.webView.url == origin.0,
           BrowserRules.googleApp(webView.url, service: service.id),
           origin.1 || BrowserRules.googleLanding(origin.0, service: service.id),
           let destination = webView.url {
            self.webView.load(URLRequest(url: destination))
            webViewDidClose(webView)
            return
        }
        guard webView === self.webView else { return }
        Task { @MainActor [weak self] in await self?.refreshUnread() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
        if (failure as NSError).code != NSURLErrorCancelled { error = failure.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) {
        error = failure.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        mediaGeneration += 1
        if activeMediaView === webView { activeMediaView = nil }
        guard webView === self.webView else {
            error = "A service popup stopped. Close and reopen it from the service page."
            return
        }
        unreadGeneration += 1
        onUnread?(.unknown)
        recoveryTask?.cancel()
        guard let delay = recovery.nextDelay(at: Date()) else {
            error = "The page stopped repeatedly. Automatic recovery is paused; reload to try again."
            recoveryTask = nil
            return
        }
        error = "The page stopped. Reconnecting in \(Int(delay)) seconds…"
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !self.closed, !Task.isCancelled else { return }
            self.reload()
        }
    }
}
