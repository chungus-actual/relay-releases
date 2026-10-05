import AppKit
import WebKit
import UniformTypeIdentifiers

@main
struct BrowserChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(ProcessInfo.processInfo.environment["RELAY_CAPTURE_NATIVE_WINDOWS"] == "1" ? .accessory : .prohibited)
        Task { @MainActor in
            do {
                if ProcessInfo.processInfo.arguments.contains("--terminal") {
                    try await terminalChecks()
                    exit(0)
                }
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--download-resume") {
                    try await downloadResumeChecks(URL(string: ProcessInfo.processInfo.arguments[index + 1])!)
                    print("PASS: interrupted download resumes and safely replaces destination")
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--profile-cleanup-check") {
                    try await profileCleanupChecks()
                    print("PASS: created and deleted a disposable persistent WebKit profile")
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--provider-chrome") {
                    try await providerChromeChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--messenger-visibility") {
                    try await messengerVisibilityChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--engine-fallback") {
                    try await engineFallbackChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--switch-performance") {
                    try await switchPerformanceChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--file-drop") {
                    try await nativeFileDropChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--inline-predictions") {
                    try await inlinePredictionChecks()
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--media") {
                    try await mediaChecks()
                    try await mediaPlaybackRegressionChecks()
                    print("PASS: media routing, floating/docking, audio state, and notification replay regressions")
                    exit(0)
                }
                try await inlinePredictionChecks()
                try await googleSessionRoutingChecks()
                try await discordChecks()
                try railPointerChecks()
                try await dragPayloadChecks()
                try await mediaChecks()
                try await mediaPlaybackRegressionChecks()
                try await youtubeChecks()
                try await workspacePaneChecks()
                try await navigationChecks()
                try await messengerAttachmentRoutingChecks()
                try await messengerVisibilityChecks()
                try await providerChromeChecks()
                try await engineFallbackChecks()
                try await retainedBrowserChecks()
                try await nativeFileDropChecks()
                try await run()
                try await pageControlChecks()
                try await zoomChecks()
                try await unreadChecks()
                print("Passed: native rail dragging, WebKit isolation/downloads, zoom/scheduling/history, unread/activity, main/popup media routing, unload cleanup")
                exit(0)
            } catch {
                fputs("Browser checks failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func inlinePredictionChecks() async throws {
        let service = Service(id: "fixture", name: "Typing fixture", url: URL(string: "https://relay.test")!,
                              glyph: "F", hosts: ["relay.test"])
        for enabled in [false, true] {
            let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Typing fixture"),
                service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false,
                inlinePredictionsEnabled: enabled)
            defer { session.close() }
            try require(session.webView.configuration.allowsInlinePredictions == enabled,
                        "Main service did not receive the prediction choice")
            // This fixture opens a popup from JavaScript without a user gesture.
            session.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            session.webView.loadHTMLString("<html><body><textarea id='draft'>Unsent draft</textarea></body></html>", baseURL: service.url)
            try await waitFor("typing fixture") { !session.webView.isLoading && session.webView.url != nil }
            _ = try await session.webView.evaluateJavaScript("window.open('about:blank', '_blank'); void 0")
            try await waitFor("typing popup") { session.browserViews.count == 2 }
            let popup = session.browserViews[1]
            try require(popup.configuration.allowsInlinePredictions == enabled,
                        "Service popup did not inherit the prediction choice")
            try require(popup.configuration.websiteDataStore === session.webView.configuration.websiteDataStore,
                        "Prediction configuration must preserve popup account storage")
            let draft = try await session.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
            try require(draft == "Unsent draft", "Opening the popup replaced the service draft")
            session.webViewDidClose(popup)
            try require(session.browserViews.count == 1, "Typing popup was not cleaned up")
        }
        print("Passed: inline prediction choices reach service pages and popups while retaining drafts and account storage")
    }

    @MainActor static func googleSessionRoutingChecks() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: root.appendingPathComponent("services.json")))
        for service in services where ["gmail", "calendar", "googlemessages", "googlekeep", "youtubemusic"].contains(service.id) {
            for handoff in ["https://accounts.youtube.com/accounts/SetSID", "https://www.youtube.com/signin?action_handle_signin=true"] {
                let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Auth fixture"),
                    service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
                defer { session.close() }
                var external: [URL] = []
                session.openExternalURL = { external.append($0) }
                let probe = AttachmentRoutingProbe(session: session)
                session.webView.navigationDelegate = probe
                session.webView.uiDelegate = probe
                session.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                session.webView.loadHTMLString("<a id='handoff' href='\(handoff)'>Continue</a>", baseURL: service.url)
                try await waitFor("Google handoff fixture") { !session.webView.isLoading && session.webView.url != nil }
                _ = try await session.webView.evaluateJavaScript("document.getElementById('handoff').click()")
                try await waitFor("Google handoff policy") { probe.policy != nil }
                try require(probe.policy == .allow && external.isEmpty, "Google handoff escaped the account")
                session.webView.navigationDelegate = nil
                _ = try await session.webView.evaluateJavaScript("window.open('\(handoff)') === null")
                try await waitFor("Google handoff popup") { probe.popupCaptured || !external.isEmpty }
                try require(probe.popupCaptured && external.isEmpty, "Google handoff popup escaped the account")
                session.webView.navigationDelegate = probe
                for address in ["https://accounts.youtube.com.evil.test/accounts/SetSID", "https://www.youtube.com/watch?v=fixture"] {
                    probe.policy = nil
                    let before = external.count
                    _ = try await session.webView.evaluateJavaScript("(()=>{const a=document.getElementById('handoff');a.href='\(address)';a.click()})()")
                    try await waitFor("External Google lookalike policy") { probe.policy != nil }
                    try require(probe.policy == .cancel && external.count == before + 1, "External links became embedded after Google handoff")
                }
            }
        }
        let music = services.first { $0.id == "youtubemusic" }!
        let recovery = BrowserSession(account: Account(id: UUID(), serviceID: music.id, name: "Reload fixture"),
            service: music, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { recovery.close() }
        let reloadProbe = AttachmentRoutingProbe(session: recovery)
        recovery.webView.navigationDelegate = reloadProbe
        var escaped = false
        recovery.openExternalURL = { _ in escaped = true }
        recovery.webView.loadHTMLString("<p>Pending sign-in</p>", baseURL: URL(string: "https://accounts.google.com/signin")!)
        try await waitFor("YouTube pending sign-in") { !recovery.webView.isLoading && recovery.address?.host == "accounts.google.com" }
        reloadProbe.interceptAll = true
        recovery.reload()
        try await waitFor("YouTube reload recovery") { reloadProbe.destination == music.url }
        try require(reloadProbe.policy == .allow && !escaped, "Reload did not recover YouTube Music inside Relay")
        print("Passed: Google session link/popup routing, YouTube reload recovery, and external host boundaries")
    }

    @MainActor static func discordChecks() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: root.appendingPathComponent("services.json")))
        let service = services.first { $0.id == "discord" }!
        let account = Account(id: UUID(), serviceID: service.id, name: service.name)
        let center = UnreadCenter()
        let session = BrowserSession(account: account, service: service, downloads: DownloadCenter(),
            dataStore: .nonPersistent(), loadImmediately: false)
        session.onUnread = { center.receive($0, for: account.id) }
        defer { session.close() }
        session.webView.loadHTMLString("<html><title>(4) Discord</title><body>Discord fixture</body></html>", baseURL: service.url)
        try await waitFor("Discord title badge") { center.badge(for: account.id) == "4" }
        center.dismiss(account.id)
        await session.refreshUnread()
        try require(center.badge(for: account.id).isEmpty, "Repeated Discord count restored a dismissed badge")
        _ = try await session.webView.evaluateJavaScript("document.title = '(5) Discord'")
        try await waitFor("new Discord count") { center.badge(for: account.id) == "5" }
        let activityCount = center.activity.count
        await session.refreshUnread()
        try require(center.activity.count == activityCount, "Duplicate Discord count added activity")
        _ = try await session.webView.evaluateJavaScript("document.title = 'Discord | Friends'")
        try await waitFor("Discord count cleared") { center.badge(for: account.id).isEmpty }
        session.close()
        await session.refreshUnread()
        try require(center.badge(for: account.id).isEmpty, "Closed Discord session restored stale unread")
        print("Passed: Discord catalog session, title badges, dismissal, duplicates, and clearing")
    }

    @MainActor static func downloadResumeChecks(_ url: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("resume.bin")
        try Data("original".utf8).write(to: file)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let center = DownloadCenter()
        let account = Account(id: UUID(), serviceID: "fixture", name: "Resume fixture")
        center.destinationForTesting = { _ in file }
        let download = await view.startDownload(using: URLRequest(url: url))
        center.track(download, account: account)
        try await waitFor("interrupted transfer") { center.items.first?.isActive == false }
        let item = center.items[0]
        try require(item.canResume, "WebKit did not provide resumable data: \(item.failure ?? "unknown")")
        let original = try Data(contentsOf: file)
        try require(original == Data("original".utf8), "Interrupted transfer replaced destination")
        try require(center.hasActiveDownloads(account.id), "Resumable transfer must retain its account")
        center.resume(item)
        center.resume(item)
        try await waitFor("resumed transfer") { !item.isActive }
        try require(item.status == .complete, "Resume failed: \(item.failure ?? item.status.rawValue)")
        let expected = Data(String(repeating: "relay-resume-fixture\n", count: 262144).utf8)
        let actual = try Data(contentsOf: file)
        try require(actual == expected, "Resumed bytes differ")
        try require(item.download == nil && item.sourceView == nil && item.resumeData == nil && item.observations.isEmpty, "Resume retained handles")
        try require(!center.hasActiveDownloads(account.id), "Completed resume blocked unload")
        center.clearFinished()
        try require(FileManager.default.fileExists(atPath: file.path), "Clearing history deleted completed file")
        for cancelDuringResume in [false, true] {
            let next = await view.startDownload(using: URLRequest(url: url))
            center.track(next, account: account)
            try await waitFor("second interruption") { center.items.first?.isActive == false }
            let interrupted = center.items[0]
            try require(interrupted.canResume, "Second transfer was not resumable")
            center.clearFinished()
            try require(center.items.contains(where: { $0 === interrupted }), "Clear discarded a resumable transfer")
            let staging = interrupted.destination!.stagingDirectory
            if cancelDuringResume { center.resume(interrupted) }
            center.cancel(interrupted)
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(interrupted.status == .cancelled && !interrupted.canResume, "Cancel retained resume state")
            try require(!FileManager.default.fileExists(atPath: staging.path), "Cancel left staging files")
            let preserved = try Data(contentsOf: file)
            try require(preserved == expected, "Cancel during resume overwrote the destination")
            try require(!center.hasActiveDownloads(account.id), "Canceled resume blocked unload")
            center.clearFinished()
        }
    }

    @MainActor static func pageControlChecks() async throws {
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test")!, glyph: "F", hosts: ["relay.test"])
        let first = BrowserSession(account: Account(id: UUID(), serviceID: "fixture", name: "Muted", audioMuted: true), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        let second = BrowserSession(account: Account(id: UUID(), serviceID: "fixture", name: "Other"), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { first.close(); second.close() }
        var received = [String]()
        first.pageControls.notificationsAllowed = { true }
        first.pageControls.onNotification = { title, body in received.append(title + body) }
        for session in [first, second] {
            session.webView.loadHTMLString("<html><body><audio id='audio'></audio></body></html>", baseURL: service.url)
            try await waitFor("page controls fixture") { !session.webView.isLoading && session.webView.url != nil }
        }
        let muted = try await first.webView.evaluateJavaScript("document.getElementById('audio').muted")
        let other = try await second.webView.evaluateJavaScript("document.getElementById('audio').muted")
        try require(muted as? Bool == true && other as? Bool == false, "Saved mute must be isolated")
        _ = try await first.webView.evaluateJavaScript("document.getElementById('audio').muted = false")
        let held = try await first.webView.evaluateJavaScript("document.getElementById('audio').muted")
        try require(held as? Bool == true, "Page must not undo Relay media mute")
        first.pageControls.setMuted(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let unmuted = try await first.webView.evaluateJavaScript("document.getElementById('audio').muted")
        try require(unmuted as? Bool == false, "Unmute must restore page preference")
        _ = try await first.webView.callAsyncJavaScript("await Notification.requestPermission(); new Notification('hello', {body:'world'});", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor("notification bridge") { received == ["helloworld"] }
        let denied = try await second.webView.callAsyncJavaScript("return await Notification.requestPermission()", arguments: [:], in: nil, contentWorld: .page)
        try require(denied as? String == "denied", "Notification permission must not leak between accounts")
        first.pageControls.setMuted(true)
        _ = try await first.webView.evaluateJavaScript("void window.open('about:blank', 'relay-audio-fixture')")
        try await waitFor("audio popup") { first.browserViews.count == 2 }
        let popup = first.browserViews[1]
        popup.loadHTMLString("<html><body><audio id='audio'></audio></body></html>", baseURL: service.url)
        try await waitFor("audio popup loaded") { !popup.isLoading && popup.url?.host == "relay.test" }
        let popupMuted = try await popup.evaluateJavaScript("document.getElementById('audio').muted")
        try require(popupMuted as? Bool == true, "New popups must inherit current mute")
        let gateMuted = try await first.webView.evaluateJavaScript("""
            window.ctx = new AudioContext();
            const createGain = ctx.createGain.bind(ctx);
            ctx.createGain = () => { window.testGate = createGain(); return testGate; };
            window.osc = ctx.createOscillator(); osc.connect(ctx.destination);
            testGate.gain.value
            """)
        try require(gateMuted as? Double == 0, "Web Audio output must be gated while muted")
        first.pageControls.setMuted(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let gateUnmuted = try await first.webView.evaluateJavaScript("testGate.gain.value")
        let popupUnmuted = try await popup.evaluateJavaScript("document.getElementById('audio').muted")
        try require(gateUnmuted as? Double == 1 && popupUnmuted as? Bool == false, "Unmute must reach Web Audio and popups")
        _ = try await first.webView.evaluateJavaScript("osc.disconnect(ctx.destination); void ctx.close()")
        print("Passed: page notification permission/isolation, media/Web Audio mute, popup inheritance")
    }

    @MainActor static func zoomChecks() async throws {
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test")!, glyph: "F", hosts: ["relay.test"])
        let account = Account(id: UUID(), serviceID: service.id, name: "Zoomed", pageZoom: 1.35)
        let center = DownloadCenter()
        let first = BrowserSession(account: account, service: service, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        let second = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Other"), service: service, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { first.close(); second.close() }
        try require(first.webView.pageZoom == 1.35 && second.webView.pageZoom == 1, "Initial zoom must be account-specific")
        first.webView.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"></head><body>Zoom fixture</body></html>", baseURL: service.url)
        try await waitFor("zoom fixture") { !first.webView.isLoading && first.webView.url != nil }
        try require(first.webView.pageZoom == 1.35, "Navigation lost saved zoom")
        try require(first.webView.configuration.preferences.inactiveSchedulingPolicy == .none, "Accounts default to staying awake")
        first.setKeepLive(false)
        try require(first.webView.configuration.preferences.inactiveSchedulingPolicy == .suspend, "Allow sleep must reach WebKit")
        try require(second.webView.configuration.preferences.inactiveSchedulingPolicy == .none, "Sleep policy leaked to another account")
        first.setKeepLive(true)
        first.webView.pageZoom = 2
        try require(second.webView.pageZoom == 1, "Zoom affected another account")
        first.close()
        let reopened = BrowserSession(account: account, service: service, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { reopened.close() }
        try require(reopened.webView.pageZoom == 1.35, "Recreated session lost saved zoom")
    }

    @MainActor static func dragPayloadChecks() async throws {
        let scope = AccountDragScope()
        let account = UUID()
        let provider = NSItemProvider(object: scope.payload(for: account) as NSString)
        try require(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier), "Drop target must recognize the drag type")
        try require(provider.canLoadObject(ofClass: NSString.self), "Drag must load through the drop handler")
        let payload: String? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, error in
                continuation.resume(returning: error == nil ? value as? String : nil)
            }
        }
        try require(payload != nil && scope.account(from: [payload ?? ""]) == account, "Item provider lost the account drag payload")
        try require(AccountDragScope().account(from: [payload ?? ""]) == nil, "Foreign drag scope accepted")
    }

    @MainActor static func railPointerChecks() throws {
        final class RecordingDragView: AccountDragSource.DragView {
            var draggedItem: NSDraggingItem?
            override func beginAccountDrag(_ item: NSDraggingItem, event: NSEvent) { draggedItem = item }
        }
        let view = RecordingDragView(frame: NSRect(x: 0, y: 0, width: 46, height: 44))
        var clicks = 0
        view.activate = { clicks += 1 }
        view.payload = "relay-drag-fixture"
        view.serviceID = "fixture"
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 20))
        view.mouseUp(with: event(.leftMouseUp, 20))
        try require(clicks == 1 && view.draggedItem == nil, "Rail click must activate without dragging")
        view.mouseDown(with: event(.leftMouseDown, 20))
        view.mouseDragged(with: event(.leftMouseDragged, 22))
        try require(view.draggedItem == nil, "Pointer jitter must not begin dragging")
        view.mouseDragged(with: event(.leftMouseDragged, 28))
        try require(view.draggedItem != nil, "Rail mouse drag must start a native dragging session")
        try require(view.draggedItem?.item as? String == view.payload, "Native drag lost its scoped payload")
        try require((view.draggedItem?.draggingFrame.height ?? 0) == 40, "Icon preview keeps a small padded footprint")
        view.mouseUp(with: event(.leftMouseUp, 28))
        try require(clicks == 1, "Finishing drag must not activate the account")
        try require(!view.mouseDownCanMoveWindow, "Rail gestures must not move the window")
    }

    @MainActor final class AttachmentRoutingProbe: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: BrowserSession
        var policy: WKNavigationActionPolicy?
        var popupCaptured = false
        var interceptAll = false
        var destination: URL?
        init(session: BrowserSession) { self.session = session }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard interceptAll || action.navigationType == .linkActivated else { decisionHandler(.allow); return }
            destination = action.request.url
            session.webView(view, decidePolicyFor: action) { self.policy = $0 }
            // Inspect the real navigation event, then stop it before any network request.
            decisionHandler(.cancel)
        }
        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            popupCaptured = session.webView(view, createWebViewWith: configuration, for: action, windowFeatures: windowFeatures) != nil
            return nil
        }
    }

    @MainActor static func engineFallbackChecks() async throws {
        try require(!ChromiumRuntime.isEnabled, "Normal browser checks must not enable experimental Chromium")
        let id = UUID()
        do {
            try await checkExistingWebKitProfile(id)
            // WebKit releases its network-process profile handle asynchronously after
            // the last test view closes. Retry cleanup of this disposable UUID only.
            for attempt in 0..<30 {
                do { try await ProfileStorage.erase(id); break }
                catch {
                    if attempt == 29 { throw error }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            try? await ProfileStorage.erase(id)
            throw error
        }
        print("Passed: saved Chromium selection resumes the existing WebKit profile without changing account preference")
    }

    @MainActor static func checkExistingWebKitProfile(_ id: UUID) async throws {
        let store = WKWebsiteDataStore(forIdentifier: id)
        let cookie = HTTPCookie(properties: [.domain: "relay.test", .path: "/", .name: "engine-fallback", .value: "preserved", .secure: "TRUE"])!
        await store.httpCookieStore.setCookie(cookie)
        let account = Account(id: id, serviceID: "fixture", name: "Engine fallback", browserEngine: "chromium")
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test/")!, glyph: "F", hosts: ["relay.test"])
        for _ in 0..<2 {
            let session = BrowserSession(account: account, service: service, downloads: DownloadCenter(), loadImmediately: false)
            try require(session.chromium == nil && session.error == nil, "Normal builds must fall back to WebKit without an engine error")
            try require(session.webView.configuration.websiteDataStore.identifier == id,
                        "Fallback must retain the original persistent WebKit profile UUID")
            let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            try require(cookies.contains { $0.name == "engine-fallback" && $0.value == "preserved" },
                        "Fallback must preserve existing WebKit sign-in storage")
            session.close()
        }
        try require(account.usesChromium, "Runtime fallback must not erase the saved experimental preference")
    }

    @MainActor static func switchPerformanceChecks() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = BrowserDeckView(frame: window.contentView!.bounds)
        window.contentView = host
        window.orderFrontRegardless()
        let views = (0..<4).map { _ in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            return WKWebView(frame: host.bounds, configuration: config)
        }
        defer { views.forEach { $0.stopLoading() }; window.close() }
        host.update(views: views, selected: views[0])
        for (index, view) in views.enumerated() {
            view.loadHTMLString("""
                <style>body{margin:0;background:#32485c;color:white}header{height:70px;background:#448866}main{height:600px;overflow:auto}.row{height:36px;border-bottom:1px solid #789;transform:translateZ(0)}</style>
                <header>Service \(index)</header><main id="chat"></main>
                <script>document.getElementById('chat').innerHTML=Array.from({length:1000},(_,i)=>'<div class="row">Message '+i+'</div>').join('');window.token=Math.random();window.initial=window.token;</script>
                """, baseURL: URL(string: "https://relay.test/"))
            try await waitFor("performance fixture") { !view.isLoading && view.url != nil }
        }
        func summary(_ samples: [Double]) -> String {
            let sorted = samples.sorted()
            return String(format: "median %.2f ms, p95 %.2f ms, max %.2f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!)
        }
        // Alternate order to reduce warmup/order bias. This isolates native hosting;
        // requestAnimationFrame completion is not a physical screen-presentation timestamp.
        for retained in [false, true, true, false] {
            var hostTimes: [Double] = [], frameTimes: [Double] = []
            for iteration in 0..<44 {
                let view = views[iteration % views.count]
                let start = ProcessInfo.processInfo.systemUptime
                if retained { host.update(views: views, selected: view) }
                else {
                    for child in host.subviews { child.removeFromSuperview() }
                    view.isHidden = false
                    view.frame = host.bounds
                    host.addSubview(view)
                }
                let switched = ProcessInfo.processInfo.systemUptime
                let intact = try await view.callAsyncJavaScript("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))); return window.token===window.initial;", arguments: [:], in: nil, contentWorld: .page) as? Bool
                try require(intact == true, "Performance switching must not reload documents")
                if iteration >= 4 {
                    hostTimes.append((switched - start) * 1000)
                    frameTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
            }
            print("PERF \(retained ? "retained" : "detach/attach") (40 switches): host \(summary(hostTimes)); two animation frames \(summary(frameTimes))")
            fflush(stdout)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("relay-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = PreferencesFile(url: temporary.appendingPathComponent("settings.json"))
        var settings = Preferences(accounts: (0..<12).map { Account(id: UUID(), serviceID: "fixture", name: "Account \($0)") })
        var saves: [Double] = []
        for index in 0..<40 {
            settings.selected = settings.accounts[index % settings.accounts.count].id
            let start = ProcessInfo.processInfo.systemUptime
            try file.save(settings)
            saves.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        print("PERF atomic settings save (12 accounts, 40 saves): \(summary(saves))")
    }

    @MainActor static func retainedBrowserChecks() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = BrowserDeckView(frame: window.contentView!.bounds)
        window.contentView = host
        window.orderFrontRegardless()
        let views = (0..<2).map { _ in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return WKWebView(frame: host.bounds, configuration: configuration)
        }
        defer { views.forEach { $0.stopLoading() }; window.close() }
        var activations = 0
        host.onActivation = { activations += 1 }
        host.update(views: views, selected: views[0])
        for view in views {
            view.loadHTMLString("<input id='draft' value='Unsent'><div id='pane' style='height:100px;overflow:auto'><div style='height:2000px'>Messages</div></div><script>window.token=Math.random();window.originalToken=window.token;document.getElementById('pane').scrollTop=420;</script>", baseURL: URL(string: "https://relay.test/"))
            try await waitFor("retained browser fixture") { !view.isLoading && view.url != nil }
        }
        for selection in [1, 0, 1, 0] {
            host.update(views: views, selected: views[selection])
            let count = activations
            host.update(views: views, selected: views[selection])
            try require(activations == count, "Duplicate updates must not reactivate a browser")
            try await Task.sleep(for: .milliseconds(100))
            for (index, view) in views.enumerated() {
                try require(view.window === window && view.superview === host && view.frame == host.bounds,
                            "Switching must preserve browser window and viewport")
                try require(view.isHidden == (index != selection), "Only the selected browser should be visible")
                let preserved = try await view.evaluateJavaScript("window.token===window.originalToken && document.getElementById('draft').value==='Unsent' && document.getElementById('pane').scrollTop===420") as? Bool
                try require(preserved == true, "Switching must preserve document, draft, and scroll position")
            }
        }
        host.update(views: views, selected: nil)
        try require(views.allSatisfy { $0.isHidden && $0.window === window }, "Local pages must hide and retain loaded browsers")
        host.setFrameSize(NSSize(width: 640, height: 480))
        host.layoutSubtreeIfNeeded()
        host.update(views: views, selected: views[0])
        try require(views.allSatisfy { $0.frame == host.bounds }, "Hidden browsers must track viewport resizing")
        host.update(views: [views[1]], selected: views[1])
        try require(views[0].superview == nil && views[1].window === window, "Unloading must detach only the removed browser")
        let replacement = BrowserDeckView(frame: host.bounds)
        replacement.update(views: views, selected: views[0])
        try require(views[1].superview === host, "An incoming detached host must wait for its window")
        window.contentView = replacement
        host.update(views: views, selected: views[1])
        try require(views.allSatisfy { $0.window === window && $0.superview === replacement },
                    "An outgoing detached host must not reclaim browsers during a layout change")
        try require(replacement.subviews.last === views[0] && !views[0].isHidden && views[1].isHidden,
                    "The selected browser must remain above retained native drag destinations")
        print("Passed: retained browser host switching, duplicate activation, local pages, resize, unload, and document state")
    }

    @MainActor static func messengerVisibilityChecks() async throws {
        let service = Service(id: "messenger", name: "Messenger", url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M", hosts: ["facebook.com"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Visibility fixture"), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.contentView
        window.orderFrontRegardless()
        defer { session.close(); window.close() }
        session.webView.loadHTMLString("""
            <div role="main"><div id="pane" style="height:200px;overflow:auto"><div style="height:2000px">Chat</div></div><input id="draft" value="Unsent message"></div>
            <script>window.refreshes=0;window.token=Math.random();const pane=document.getElementById('pane');pane.addEventListener('scroll',e=>{if(e.isTrusted && pane.scrollTop!==window.expectedTop) window.refreshes++;});</script>
            """, baseURL: service.url)
        try await waitFor("Messenger visibility fixture") { !session.webView.isLoading && session.webView.url != nil }
        _ = try await session.webView.evaluateJavaScript("pane.scrollTop=420;window.originalToken=window.token")
        try await Task.sleep(for: .milliseconds(300))
        for offset in [420, 0, 1800] {
            _ = try await session.webView.evaluateJavaScript("pane.scrollTop=\(offset)")
            try await Task.sleep(for: .milliseconds(100))
            session.contentView.removeFromSuperview()
            _ = try await session.webView.evaluateJavaScript("window.refreshes=0;window.expectedTop=pane.scrollTop")
            window.contentView = session.contentView
            await session.becameVisible()
            _ = try await session.webView.evaluateJavaScript("window.__relayMessengerChrome.activate();window.__relayMessengerChrome.activate()")
            try await Task.sleep(for: .milliseconds(300))
            let refreshed = try await session.webView.evaluateJavaScript("window.refreshes>0 && pane.scrollTop===window.expectedTop && document.getElementById('draft').value==='Unsent message' && window.token===window.originalToken") as? Bool
            try require(refreshed == true, "Messenger activation failed to move native scroll or changed scroll/draft/document")
        }
        _ = try await session.webView.evaluateJavaScript("""
            pane.scrollTop=420;
            pane.addEventListener('scroll', function userScroll(e) {
              if (e.isTrusted && pane.scrollTop===421) { pane.scrollTop=700; pane.removeEventListener('scroll', userScroll); }
            });
            window.__relayMessengerChrome.activate();
            """)
        try await Task.sleep(for: .milliseconds(300))
        let keptNewScroll = try await session.webView.evaluateJavaScript("pane.scrollTop===700") as? Bool
        try require(keptNewScroll == true,
                    "Activation must not restore over a newer scroll")
        _ = try await session.webView.evaluateJavaScript("""
            const filler=document.createElement('div');filler.style.display='none';filler.innerHTML='<span></span>'.repeat(1500);
            document.querySelector('[role=main]').prepend(filler);
            pane.style.cssText='position:fixed;left:20%;top:20%;width:60%;height:60%;overflow:auto';
            window.expectedTop=pane.scrollTop;window.refreshes=0;
            """)
        await session.refreshMessengerDisplay()
        try await Task.sleep(for: .milliseconds(300))
        let deepPane = try await session.webView.evaluateJavaScript("window.refreshes>0 && pane.scrollTop===window.expectedTop && document.getElementById('draft').value==='Unsent message'") as? Bool
        try require(deepPane == true, "Manual display refresh must reach a visible conversation beyond the bounded DOM scan")
        session.contentView.isHidden = true
        let hiddenEvents = ReportEvents.snapshot
        await session.refreshMessengerDisplay()
        try require(ReportEvents.snapshot == hiddenEvents, "Stale refresh commands must ignore hidden Messenger panes")
        session.contentView.isHidden = false
        _ = try await session.webView.evaluateJavaScript("history.pushState({},'', '/settings/');window.refreshes=0;window.__relayMessengerChrome.activate()")
        try await Task.sleep(for: .milliseconds(300))
        let stale = try await session.webView.evaluateJavaScript("window.refreshes===0 && pane.scrollTop===window.expectedTop") as? Bool
        try require(stale == true, "Stale activation after leaving Messenger must not move the page")
        print("Passed: Messenger reattachment refreshes chat without scrolling, losing drafts, or reloading")
    }

    @MainActor static func messengerAttachmentRoutingChecks() async throws {
        let service = Service(id: "messenger", name: "Messenger", url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M", hosts: ["facebook.com", "messenger.com"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Fixture"), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { session.close() }
        var external: [URL] = []
        session.openExternalURL = { external.append($0) }
        let probe = AttachmentRoutingProbe(session: session)
        session.webView.navigationDelegate = probe
        session.webView.uiDelegate = probe
        session.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        session.webView.loadHTMLString("<a id='attachment' href='https://scontent-ord5-2.xx.fbcdn.net/fixture'>Download</a>", baseURL: service.url)
        try await waitFor("attachment link fixture") { !session.webView.isLoading && session.webView.url != nil }
        _ = try await session.webView.evaluateJavaScript("document.getElementById('attachment').click()")
        try await waitFor("attachment policy") { probe.policy != nil }
        try require(probe.policy == .allow && external.isEmpty, "Messenger CDN navigation escaped Relay")
        // Test the actual new-window action separately from navigation policy.
        session.webView.navigationDelegate = nil
        _ = try await session.webView.evaluateJavaScript("window.open('https://scontent-ord5-2.xx.fbcdn.net/fixture', '_blank') === null")
        try await waitFor("attachment popup") { probe.popupCaptured || !external.isEmpty }
        try require(probe.popupCaptured && external.isEmpty, "Messenger CDN popup escaped Relay")
        session.webView.navigationDelegate = probe
        probe.policy = nil
        _ = try await session.webView.evaluateJavaScript("const a=document.getElementById('attachment');a.href='https://fbcdn.net.evil.test/fixture';a.click()")
        try await waitFor("external link policy") { probe.policy != nil }
        try require(probe.policy == .cancel && external.count == 1, "Ordinary external links must retain external routing")
        print("Passed: Messenger CDN click and popup routing stays in Relay")
    }

    @MainActor static func navigationChecks() async throws {
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test")!, glyph: "F", hosts: ["relay.test"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Fixture"),
                                     service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { session.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html")
        try "<html><body>First local history fixture</body></html>".write(to: first, atomically: true, encoding: .utf8)
        try "<html><body>Second local history fixture</body></html>".write(to: second, atomically: true, encoding: .utf8)
        // Routing is tested separately; allow these local files only in this fixture.
        session.webView.navigationDelegate = nil
        session.webView.loadFileURL(first, allowingReadAccessTo: folder)
        try await waitFor("first history fixture") { !session.webView.isLoading && session.webView.url == first }
        session.webView.loadFileURL(second, allowingReadAccessTo: folder)
        try await waitFor("back enabled") { session.canGoBack && !session.webView.isLoading }
        session.webView.goBack()
        try await waitFor("forward enabled") { session.canGoForward && session.webView.url == first }
        session.webView.goForward()
        try await waitFor("forward cleared") { !session.canGoForward && session.webView.url == second }
    }

    @MainActor static func youtubeChecks() async throws {
        let service = Service(id: "youtube", name: "YouTube", url: URL(string: "https://www.youtube.com/")!, glyph: "YT", hosts: ["youtube.com", "youtu.be"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: service.name), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { session.close() }
        session.webView.loadHTMLString("""
            <h1 class="ytd-watch-metadata">Fixture video</h1><button class="ytp-play-button" aria-label="Pause"></button>
            <button class="ytp-prev-button" disabled></button><button class="ytp-next-button"></button>
            """, baseURL: service.url)
        try await waitFor("YouTube fixture") { !session.webView.isLoading && session.webView.url != nil }
        _ = try await session.webView.evaluateJavaScript("""
            window.videoNext = 0;
            document.querySelector('.ytp-next-button').onclick = () => window.videoNext++;
            document.querySelector('.ytp-play-button').onclick = function() { this.setAttribute('aria-label', this.getAttribute('aria-label') === 'Pause' ? 'Play' : 'Pause'); };
            void 0;
            """)
        guard let reading = await session.readMedia() else { throw Failure(message: "YouTube media bridge not installed") }
        try require(reading.available && reading.playing && reading.next && !reading.previous && reading.title == "Fixture video", "YouTube player state and available actions")
        _ = try await session.webView.evaluateJavaScript("window.__relayMedia.act('nexttrack'); window.__relayMedia.act('pause'); void 0")
        let clicks = try await session.webView.evaluateJavaScript("window.videoNext") as? Int
        let paused = await session.readMedia()
        try require(clicks == 1 && paused?.playing == false, "YouTube actions target the video once")
        _ = try await session.webView.evaluateJavaScript("document.body.replaceChildren(); void 0")
        guard let clearedBridge = try await session.webView.evaluateJavaScript("window.__relayMedia.read()"),
              let clearedReading = MediaReading(value: clearedBridge) else { throw Failure(message: "Missing cleared YouTube bridge reading") }
        try require(!clearedReading.available && !clearedReading.playing, "Removed YouTube player clears bridge playback state")
        let cleared = await session.readMedia()
        try require(cleared == nil, "Removed YouTube player must clear stale controls")
        let actedAfterClear = await session.actOnMedia(.next)
        try require(!actedAfterClear, "Removed YouTube player must clear the active media target")
        print("Passed: YouTube player state, pause/next, and cleared media")
    }

    @MainActor static func workspacePaneChecks() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = BrowserDeckView(frame: window.contentView!.bounds)
        window.contentView = host; window.orderFrontRegardless()
        let views = (0..<4).map { _ in
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            return WKWebView(frame: host.bounds, configuration: configuration)
        }
        defer { views.forEach { $0.stopLoading() }; window.close() }
        var layout = WorkspaceLayout(panes: (0..<4).map { _ in UUID() })
        layout.normalizeSizes()
        host.update(views: views, selected: views[0], visible: views, layout: layout)
        for view in views {
            view.loadHTMLString("<input id='draft' value='Unsent'><script>window.token=Math.random();window.originalToken=window.token</script>", baseURL: URL(string: "https://relay.test/")!)
            try await waitFor("workspace fixture") { !view.isLoading && view.url != nil }
        }
        var focusEvents = 0
        host.onFocus = { target in
            focusEvents += 1
            host.update(views: views, selected: target, visible: views, layout: layout)
        }
        func clickPane(_ index: Int) {
            let frame = views[index].frame
            let location = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.sendEvent(event)
            }
        }
        for index in [1, 2, 0, 3] {
            clickPane(index)
            try await waitFor("native pane focus") { host.selectedView === views[index] }
        }
        let beforeDuplicate = focusEvents
        clickPane(3); clickPane(3)
        try await Task.sleep(for: .milliseconds(50))
        try require(focusEvents == beforeDuplicate, "Duplicate native focus must not reselect or reactivate panes")
        clickPane(1); clickPane(2); clickPane(3)
        try await Task.sleep(for: .milliseconds(50))
        try require(host.selectedView === views[3] && focusEvents == beforeDuplicate, "Newest pointer focus cancels queued older selections")
        clickPane(1)
        host.update(views: views, selected: nil, visible: [], layout: layout)
        try await Task.sleep(for: .milliseconds(50))
        try require(host.selectedView == nil && focusEvents == beforeDuplicate, "Local pages cancel pending pane focus")
        host.update(views: views, selected: views[0], visible: views, layout: layout)
        host.onFocus = nil
        for arrangement in WorkspaceLayout.arrangements {
            layout.arrangement = arrangement; layout.cuts = []; layout.normalizeSizes()
            host.update(views: views, selected: views[0], visible: views, layout: layout)
            host.onResize = { index, position, _ in
                layout.resize(index, position: position)
                host.update(views: views, selected: views[0], visible: views, layout: layout)
            }
            guard let split = layout.dividers().first else { throw Failure(message: "Missing divider") }
            // Avoid the crossing of the grid's horizontal and vertical dividers.
            let alongDivider = split.start + split.length * 0.37
            let point = NSPoint(x: (split.vertical ? split.position : alongDivider) * host.bounds.width,
                                y: (split.vertical ? alongDivider : split.position) * host.bounds.height)
            guard let divider = host.hitTest(host.convert(point, to: host.superview)), !views.contains(where: { divider === $0 || divider.isDescendant(of: $0) }) else { throw Failure(message: "Browser covered resize handle") }
            let target = NSPoint(x: point.x + (split.vertical ? 40 : 0), y: point.y + (split.vertical ? 0 : 40))
            let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: host.convert(target, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            divider.mouseDragged(with: event)
            try await waitFor("coalesced \(arrangement) pane drag") { (split.index < 0 ? layout.primary : layout.cuts[split.index]) > split.position }
            let actual = split.index < 0 ? layout.primary : layout.cuts[split.index]
            try require(actual > split.position, "Dragging must resize the native panes")
            let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(target, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            divider.mouseDown(with: doubleClick); divider.mouseUp(with: doubleClick)
            let reset = split.index < 0 ? layout.primary : layout.cuts[split.index]
            let expected = split.index < 0 ? 0.5 : Double(split.index + 1) / Double(layout.cuts.count + 1)
            try require(abs(reset - expected) < 0.000001, "Mouse-up must not undo double-click divider reset")
            for (i, view) in views.enumerated() {
                try require(!view.isHidden && view.superview === host && view.window === window, "Arrangement changes retain all four native browsers")
                let cell = layout.cell(i)
                try require(abs(view.frame.height - (cell.height * host.bounds.height - 6)) < 1 && abs(view.frame.minY - (cell.y * host.bounds.height + 3)) < 1,
                            "Pane content must reclaim the header space, leaving only the resize gutter")
                for other in views.dropFirst(i + 1) { try require(!view.frame.intersects(other.frame), "Browser panes must not overlap") }
                let preserved = try await view.evaluateJavaScript("window.token===window.originalToken && document.getElementById('draft').value==='Unsent'") as? Bool
                try require(preserved == true, "Resize must preserve document and draft")
            }
        }
        for (index, arrangement) in ["columns", "rows", "main-left"].enumerated() {
            layout.arrangement = arrangement; layout.primary = 0.6; layout.cuts = []; layout.normalizeSizes()
            host.update(views: views, selected: views[0], visible: views, layout: layout, transition: index + 1)
        }
        try await Task.sleep(for: .milliseconds(300))
        for (index, view) in views.enumerated() {
            let cell = layout.cell(index)
            try require(abs(view.frame.width - (cell.width * host.bounds.width - 6)) < 1 && abs(view.frame.minX - (cell.x * host.bounds.width + 3)) < 1,
                        "Interrupted native animations must land on the latest pane geometry")
        }
        let split = layout.dividers()[0]
        let point = NSPoint(x: split.position * host.bounds.width, y: host.bounds.height / 2)
        guard let divider = host.hitTest(host.convert(point, to: host.superview)) else { throw Failure(message: "Missing animated divider") }
        var delivered = 0, completed = false
        host.onResize = { _, _, finished in delivered += 1; completed = finished }
        let dragged = NSEvent.mouseEvent(with: .leftMouseDragged, location: host.convert(NSPoint(x: point.x + 12, y: point.y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        divider.mouseDragged(with: dragged)
        let released = NSEvent.mouseEvent(with: .leftMouseUp, location: host.convert(NSPoint(x: point.x + 24, y: point.y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        divider.mouseUp(with: released)
        try await Task.sleep(for: .milliseconds(50))
        try require(delivered == 1 && completed, "Mouse-up flushes once and cancels queued stale drag updates")
        divider.mouseDragged(with: dragged)
        host.update(views: views, selected: nil, visible: [], layout: layout)
        try await Task.sleep(for: .milliseconds(50))
        try require(delivered == 1, "Leaving the workspace cancels queued resize events")
        host.onResize = nil
        host.update(views: views, selected: nil, visible: [], layout: layout)
        try require(views.allSatisfy { $0.isHidden } && host.subviews.count == views.count, "Local pages hide all panes and remove divider controls")
        layout.remove(layout.panes[1])
        host.update(views: views, selected: views[0], visible: [views[0], views[2], views[3]], layout: layout)
        try require(views[1].isHidden && views[1].window === window, "Closing a pane retains the account session")
        print("Passed: four native panes, divider drag, document retention, local pages, and closing")
    }

    @MainActor static func mediaChecks() async throws {
        func stage(_ text: String) { print("Media: \(text)"); fflush(stdout) }
        stage("loading provider fixtures")
        let service = Service(id: "spotify", name: "Spotify", url: URL(string: "https://open.spotify.com")!, glyph: "S", hosts: ["spotify.com"])
        let first = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "First"), service: service,
                                   downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        let second = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Second"), service: service,
                                    downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        let center = MediaCenter()
        defer { center.unregister(first.accountID); center.unregister(second.accountID); first.close(); second.close() }
        for (index, session) in [first, second].enumerated() {
            session.webView.loadHTMLString("""
                <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head><body>
                <button data-testid="control-button-playpause" aria-label="\(index == 0 ? "Play" : "Pause")"></button>
                <button data-testid="control-button-skip-back" disabled></button>
                <button data-testid="control-button-skip-forward"></button>
                <span data-testid="context-item-info-title">Fixture track \(index)</span>
                </body></html>
                """, baseURL: service.url)
            try await waitFor("media fixture") { !session.webView.isLoading && session.webView.url != nil }
            _ = try await session.webView.evaluateJavaScript("""
                window.nextClicks = 0;
                document.querySelector('[data-testid="control-button-skip-forward"]').onclick = () => { window.nextClicks++; };
                void 0;
                """)
        }
        stage("reading provider controls")
        guard let reading = await second.readMedia() else { throw Failure(message: "Media bridge did not load at document start") }
        try require(reading.available && reading.playing && reading.next && !reading.previous, "Incorrect provider control reading")
        center.register(first); center.register(second)
        try await waitFor("playing media chosen") { center.active?.accountID == second.accountID }
        stage("retained service windows")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let deck = BrowserDeckView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)); window.contentView = deck
        defer { center.dock(); window.close() }
        deck.update(views: [first.contentView, second.contentView], selected: second.contentView)
        var firstDocked = 0, secondDocked = 0
        first.popOutService { firstDocked += 1 }
        let firstChild = first.serviceWindow
        first.popOutService { firstDocked += 100 }
        second.popOutService { secondDocked += 1 }
        let secondChild = second.serviceWindow
        try require(firstChild != nil && first.serviceWindow === firstChild && secondChild != nil && firstChild !== secondChild,
                    "Each account owns one reusable service child")
        try require(firstChild?.level == .normal && second.contentView.window === secondChild, "Service pop-out retains the browser in a normal-level window")
        deck.update(views: [first.contentView, second.contentView], selected: nil, visible: [])
        try require(first.contentView.window === firstChild && second.contentView.window === secondChild && !second.contentView.isHidden,
                    "Local pages cannot reclaim or hide service children")
        second.setNativeAppearance(dark: true, background: .black, foreground: .white)
        try require(secondChild?.appearance?.name == .darkAqua && secondChild?.backgroundColor == .black, "Pop-out chrome follows Relay colors")
        firstChild?.close(); firstChild?.close()
        try require(first.serviceWindow == nil && firstDocked == 1 && first.contentView.superview === deck && first.contentView.isHidden,
                    "Closing and repeated closing dock the original service once")
        _ = try await second.webView.evaluateJavaScript("window.popoutToken='retained'")
        deck.update(views: [first.contentView, second.contentView], selected: second.contentView)
        center.updatePlayerAppearance(dark: false, background: .white, foreground: .black, accent: .systemBlue)
        await center.floatActive()
        stage("floating ownership")
        let panel = center.floating
        try require(panel != nil && second.contentView.window === panel && second.serviceWindow == nil && secondDocked == 0,
                    "PiP transfers the original browser from its service child without docking selection")
        let popoutToken = try await second.webView.evaluateJavaScript("window.popoutToken") as? String
        try require(popoutToken == "retained", "Pop-out/PiP transfers retain document state")
        try require(panel?.appearance?.name == .aqua && panel?.backgroundColor == .white, "Floating titlebar must follow Relay light colors")
        center.updatePlayerAppearance(dark: true, background: .black, foreground: .white, accent: .systemGreen)
        try require(panel?.appearance?.name == .darkAqua && panel?.backgroundColor == .black, "Open floating titlebar must update to Relay dark colors")
        if let panel {
            let original = panel.frame
            for size in [NSSize(width: 360, height: 200), NSSize(width: 1000, height: 210), NSSize(width: 360, height: 750), original.size] {
                panel.setFrame(NSRect(origin: original.origin, size: size), display: true)
                panel.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let visible = panel.toolbar?.visibleItems?.filter { $0.itemIdentifier.rawValue.hasPrefix("relay.") } ?? []
                try require(visible.count == 3, "All floating controls stay visible at \(size), without toolbar overflow: \(visible.map(\.itemIdentifier))")
                let browserRect = second.contentView.convert(second.contentView.bounds, to: nil)
                let windowRect = NSRect(origin: .zero, size: panel.frame.size)
                for item in visible {
                    guard let button = item.view as? NSButton else { throw Failure(message: "Floating control has no button") }
                    let rect = button.convert(button.bounds, to: nil)
                    try require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor && rect.width >= 20 && rect.height >= 20 && windowRect.contains(rect), "Floating control \(item.label) stays enabled and inside the window")
                    try require(!rect.intersects(browserRect), "Floating controls never cover the browser")
                    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        if let traffic = panel.standardWindowButton(type) {
                            try require(!rect.intersects(traffic.convert(traffic.bounds, to: nil)), "Floating controls clear native window buttons")
                        }
                    }
                }
                try require(second.contentView.frame == panel.contentView?.bounds, "Browser fills available content after every resize")
                let chrome = panel.frame.height - panel.contentLayoutRect.height
                try require(chrome <= 52, "Floating player uses one compact titlebar, got \(chrome) points")
                if size.width == 360, size.height == 200, let frame = panel.contentView?.superview,
                   let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("macos/.build/checks/floating-player-minimum.png"))
                    if ProcessInfo.processInfo.environment["RELAY_CAPTURE_NATIVE_WINDOWS"] == "1" {
                        // Toolbar materials are composited by WindowServer; opt in
                        // locally when screen capture permission is available.
                        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
                        try await Task.sleep(for: .milliseconds(200))
                        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l\(panel.windowNumber)", root.appendingPathComponent("macos/.build/checks/floating-player-native.png").path]
                        try capture.run(); capture.waitUntilExit()
                    }
                }
            }
        }
        stage("compact floating controls survive minimum, wide and tall resizes")
        await center.floatActive()
        try require(center.floating === panel, "Repeated float must reuse the native window")
        deck.update(views: [first.contentView, second.contentView], selected: first.contentView)
        try require(second.contentView.window === panel && !second.contentView.isHidden, "Switching services must not reclaim floating media")
        let dockButton = panel?.toolbar?.items.first { $0.itemIdentifier.rawValue == "relay.dock" }?.view as? NSButton
        try require(dockButton != nil, "Floating player has a native dock control")
        dockButton?.performClick(nil); center.dock()
        try require(second.contentView.superview === deck && second.contentView.isHidden, "Repeated dock must respect the currently selected service")
        await center.act(.next)
        stage("transport routing")
        let firstClicks = try await first.webView.evaluateJavaScript("window.nextClicks") as? Int
        let secondClicks = try await second.webView.evaluateJavaScript("window.nextClicks") as? Int
        try require(firstClicks == 0 && secondClicks == 1, "Media action affected the wrong account")
        _ = try await second.webView.evaluateJavaScript("navigator.mediaSession.setActionHandler('previoustrack', () => { window.previousHandled = true; })")
        let handled = await second.actOnMedia(.previous)
        let previousHandled = try await second.webView.evaluateJavaScript("window.previousHandled") as? Bool
        try require(handled && previousHandled == true, "MediaSession action handler was not captured")
        _ = try await second.webView.evaluateJavaScript("void window.open('about:blank', 'relay-media-fixture')")
        try await waitFor("owned media popup") { second.browserViews.count == 2 }
        stage("popup routing")
        let popup = second.browserViews[1]
        second.setNativeAppearance(dark: false, background: .white)
        try require(popup.window?.appearance?.name == .aqua && popup.window?.backgroundColor == .white, "Service popup titlebar follows Relay appearance")
        popup.loadHTMLString("""
            <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head><body>
            <button data-testid="control-button-playpause" aria-label="Pause"></button>
            <button data-testid="control-button-skip-forward"></button>
            <span data-testid="context-item-info-title">Popup track</span></body></html>
            """, baseURL: service.url)
        try await waitFor("popup media page") { !popup.isLoading && popup.url?.host == service.url.host }
        _ = try await second.webView.evaluateJavaScript("document.querySelector('[data-testid=control-button-playpause]').setAttribute('aria-label', 'Play')")
        _ = try await popup.evaluateJavaScript("window.popupClicks = 0; document.querySelector('[data-testid=control-button-skip-forward]').onclick = () => { window.popupClicks++; }; void 0")
        let popupReading = await second.readMedia()
        try require(popupReading?.title == "Popup track", "Playing popup must outrank paused main page")
        let popupActed = await second.actOnMedia(.next)
        let popupClicks = try await popup.evaluateJavaScript("window.popupClicks") as? Int
        let mainClicks = try await second.webView.evaluateJavaScript("window.nextClicks") as? Int
        try require(popupActed && popupClicks == 1 && mainClicks == 1, "Media action missed its owning popup")
        second.webViewDidClose(popup)
        try require(second.browserViews.count == 1, "Closed popup retained by media routing")
        center.unregister(second.accountID); second.close()
        try await waitFor("remaining media chosen") { center.active?.accountID == first.accountID }
        let afterClose = await second.readMedia()
        try require(afterClose == nil, "Closed media session remained readable")
        center.unregister(first.accountID)
        first.popOutService { firstDocked += 1 }
        first.close(); first.close()
        try require(first.serviceWindow == nil && firstDocked == 1, "Unload closes service children without selecting a disposed session")
        try require(center.active == nil, "Unload left stale media controls")
        stage("provider checks passed")
    }

    @MainActor static func mediaPlaybackRegressionChecks() async throws {
        print("Media: shared playback regressions"); fflush(stdout)
        let service = Service(id: "messenger", name: "Messenger", url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M", hosts: ["facebook.com"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Media regression"),
            service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        let center = MediaCenter()
        // WebKit defers video playback in detached views. Exercise this fixture
        // in a real viewport, as for a selected Relay service.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.orderFrontRegardless()
        defer { center.unregister(session.accountID); session.close(); window.close() }
        session.webView.loadHTMLString("<html><body></body></html>", baseURL: service.url)
        try await waitFor("generic media fixture") { !session.webView.isLoading && session.webView.url != nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Assets/Fixtures/media-playback-checks.js"), encoding: .utf8)
        let result = try await session.webView.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        try require((result?["failures"] as? [String]) == [], "Shared media regressions: \(String(describing: result))")
        print("Media: shared playback assertions passed; checking live stream"); fflush(stdout)
        center.register(session)
        _ = try await session.webView.callAsyncJavaScript("""
            const canvas = document.createElement('canvas'); canvas.width=100;canvas.height=100;
            const context=canvas.getContext('2d');context.fillRect(0,0,100,100);
            window.fixtureVideo=document.createElement('video');fixtureVideo.muted=true;
            fixtureVideo.srcObject=canvas.captureStream(10);window.fixtureDraw=setInterval(()=>context.fillRect(0,0,100,100),40);document.body.append(fixtureVideo);await fixtureVideo.play();
            """, arguments: [:], in: nil, contentWorld: .page)
        await center.refresh()
        try require(!center.audioAccounts.contains(session.accountID), "Silent canvas video must not show an audio badge")
        _ = try await session.webView.callAsyncJavaScript("""
            window.fixtureAudio = new AudioContext();
            await fixtureAudio.resume();
            window.fixtureGain = fixtureAudio.createGain(); fixtureGain.connect(fixtureAudio.destination);
            """, arguments: [:], in: nil, contentWorld: .page)
        let idle = await session.isPlayingAudio()
        try require(!idle, "An idle running AudioContext must not show an audio badge")
        _ = try await session.webView.evaluateJavaScript("window.fixtureTone=fixtureAudio.createOscillator();fixtureTone.connect(fixtureGain);fixtureGain.gain.value=0.01;fixtureTone.start();void 0")
        try await waitFor("audible Web Audio indicator") { center.audioAccounts.contains(session.accountID) }
        session.setMuted(true)
        let mutedAudio = await session.isPlayingAudio()
        try require(!mutedAudio, "Muted accounts hide active audio badges")
        session.setMuted(false)
        _ = try await session.webView.evaluateJavaScript("fixtureGain.gain.value=0;void 0")
        try await Task.sleep(for: .milliseconds(100))
        let silentAudio = await session.isPlayingAudio()
        try require(!silentAudio, "A silent connected Web Audio graph must not show a badge")
        _ = try await session.webView.evaluateJavaScript("fixtureGain.gain.value=0.01;void 0")
        try await waitFor("resumed Web Audio indicator") { center.audioAccounts.contains(session.accountID) }
        _ = try await session.webView.evaluateJavaScript("fixtureTone.stop();void 0")
        try await waitFor("ended Web Audio indicator cleared") { !center.audioAccounts.contains(session.accountID) }
        print("Media: detached notification audio"); fflush(stdout)
        _ = try await session.webView.callAsyncJavaScript("""
            const bytes=new ArrayBuffer(44+16000), d=new DataView(bytes);
            const text=(at,s)=>[...s].forEach((c,i)=>d.setUint8(at+i,c.charCodeAt(0)));
            text(0,'RIFF');d.setUint32(4,16036,true);text(8,'WAVE');text(12,'fmt ');d.setUint32(16,16,true);
            d.setUint16(20,1,true);d.setUint16(22,1,true);d.setUint32(24,8000,true);d.setUint32(28,16000,true);
            d.setUint16(32,2,true);d.setUint16(34,16,true);text(36,'data');d.setUint32(40,16000,true);
            for(let i=0;i<8000;i++)d.setInt16(44+i*2,Math.sin(i*0.35)*300,true);
            window.fixtureSoundURL=URL.createObjectURL(new Blob([bytes],{type:'audio/wav'}));
            window.fixtureSound=new Audio(fixtureSoundURL);fixtureSound.loop=true;
            await Promise.race([fixtureSound.play(),new Promise((_,reject)=>setTimeout(()=>reject(new Error('Detached sound start timed out')),4000))]);
            """, arguments: [:], in: nil, contentWorld: .page)
        let detachedAudio = await session.isPlayingAudio()
        try require(detachedAudio, "Detached notification Audio objects report active audio")
        _ = try await session.webView.evaluateJavaScript("fixtureSound.pause();void 0")
        let pausedAudio = await session.isPlayingAudio()
        try require(!pausedAudio, "Paused detached notifications clear audio state")
        _ = try await session.webView.evaluateJavaScript("fixtureSound.removeAttribute('src');fixtureSound.load();URL.revokeObjectURL(fixtureSoundURL);void 0")
        print("Media: cross-origin audio aggregation"); fflush(stdout)
        _ = try await session.webView.callAsyncJavaScript("""
            window.fixtureFrame=document.createElement('iframe');fixtureFrame.sandbox='allow-scripts';fixtureFrame.allow='autoplay';
            // Signal fixture isolates cross-origin aggregation from the acoustic
            // measurements tested above. The production bridge is injected in it.
            window.fixtureFrameURL=URL.createObjectURL(new Blob(['<html><body><script>window.__relayIsPlayingAudio=async()=>true;</script></body></html>'],{type:'text/html'}));
            fixtureFrame.src=fixtureFrameURL;
            const loaded=new Promise(r=>fixtureFrame.onload=r);document.body.append(fixtureFrame);
            await Promise.race([loaded,new Promise((_,reject)=>setTimeout(()=>reject(new Error('Audio frame load timed out')),4000))]);
            """, arguments: [:], in: nil, contentWorld: .page)
        let embeddedAudio = await session.isPlayingAudio()
        try require(embeddedAudio, "Audio activity in an opaque-origin frame reaches its owning account")
        _ = try await session.webView.evaluateJavaScript("fixtureFrame.remove();URL.revokeObjectURL(fixtureFrameURL);void 0")
        let removedAudio = await session.isPlayingAudio()
        try require(!removedAudio, "Removing an audio frame cannot leave stale activity")
        print("Media: audible, idle, silent, muted and stopped audio checks passed"); fflush(stdout)
        await center.floatActive()
        try require(center.floating != nil, "Generic video must float")
        center.unregister(session.accountID); center.unregister(session.accountID)
        try require(center.floating == nil && center.active == nil && !center.audioAccounts.contains(session.accountID), "Unload must clear floating controls and audio indicators exactly once")
        session.close()
        await center.refresh()
        try require(center.active == nil && center.audioAccounts.isEmpty, "Stale polling must not restore a closed source")
    }

    @MainActor static func profileCleanupChecks() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bootstrap = WKWebView(frame: .zero, configuration: configuration)
        defer { bootstrap.stopLoading() }
        let id = UUID()
        let existing = await WKWebsiteDataStore.allDataStoreIdentifiers
        try require(!existing.contains(id), "Disposable profile must not already exist")
        do {
            try await populateDisposableProfile(id)
            let created = await WKWebsiteDataStore.allDataStoreIdentifiers
            try require(created.contains(id), "Disposable profile was not created")
            try await ProfileStorage.erase(id)
            let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
            try require(!remaining.contains(id), "Deleted profile still exists")
        } catch {
            // Only the fresh UUID owned by this check is eligible for cleanup.
            try? await ProfileStorage.erase(id)
            throw error
        }
    }
    @MainActor static func populateDisposableProfile(_ id: UUID) async throws {
        let store = WKWebsiteDataStore(forIdentifier: id)
        let cookie = HTTPCookie(properties: [.domain: "relay.test", .path: "/", .name: "cleanup-fixture", .value: "synthetic", .secure: "TRUE"])!
        await store.httpCookieStore.setCookie(cookie)
        let cookies = await store.httpCookieStore.allCookies()
        try require(cookies.contains { $0.name == "cleanup-fixture" }, "Fixture cookie missing")
    }

    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !condition() {
            if Date() >= limit { throw Failure(message: "Timed out: " + message) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = DownloadCenter()
        let historyURL = directory.appendingPathComponent("downloads.json")
        center.configureHistory(historyURL)
        center.destinationForTesting = { directory.appendingPathComponent($0) }
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test")!, glyph: "F", hosts: ["relay.test"])
        let accounts = [Account(id: UUID(), serviceID: service.id, name: "First"), Account(id: UUID(), serviceID: service.id, name: "Second")]
        let stores = [WKWebsiteDataStore.nonPersistent(), WKWebsiteDataStore.nonPersistent()]
        let first = BrowserSession(account: accounts[0], service: service, downloads: center, dataStore: stores[0], loadImmediately: false)
        let second = BrowserSession(account: accounts[1], service: service, downloads: center, dataStore: stores[1], loadImmediately: false)
        defer { first.close(); second.close() }
        let whatsappService = Service(id: "whatsapp", name: "WhatsApp", url: URL(string: "https://web.whatsapp.com")!, glyph: "W", hosts: ["whatsapp.com"])
        let whatsapp = BrowserSession(account: Account(id: UUID(), serviceID: "whatsapp", name: "WhatsApp"),
            service: whatsappService, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { whatsapp.close() }
        whatsapp.webView.loadHTMLString("<html><body>Browser identification fixture</body></html>", baseURL: service.url)
        try await waitFor("WhatsApp identification fixture") { !whatsapp.webView.isLoading && whatsapp.webView.url != nil }
        let userAgent = try await whatsapp.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try require(userAgent.contains("AppleWebKit/") && userAgent.hasSuffix(BrowserSession.safariApplicationName), "WhatsApp is missing the Safari compatibility identifier")
        try require(first.webView.configuration.applicationNameForUserAgent == BrowserSession.safariApplicationName,
                    "Unlisted services must inherit the installed desktop Safari version")
        let spotifyService = Service(id: "spotify", name: "Spotify", url: URL(string: "https://open.spotify.com")!, glyph: "S", hosts: ["spotify.com"])
        let spotify = BrowserSession(account: Account(id: UUID(), serviceID: "spotify", name: "Spotify"),
            service: spotifyService, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { spotify.close() }
        spotify.webView.loadHTMLString("<html><body>Spotify identification fixture</body></html>", baseURL: service.url)
        try await waitFor("Spotify identification fixture") { !spotify.webView.isLoading && spotify.webView.url != nil }
        let spotifyAgent = try await spotify.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try require(spotifyAgent.contains("Macintosh") && !spotifyAgent.contains("Mobile") && spotifyAgent.hasSuffix(BrowserSession.safariApplicationName),
                    "Spotify must receive a desktop Safari identifier")
        let gmailService = Service(id: "gmail", name: "Gmail", url: URL(string: "https://mail.google.com/mail/")!, glyph: "G", hosts: ["google.com"])
        let gmail = BrowserSession(account: Account(id: UUID(), serviceID: "gmail", name: "Gmail"),
            service: gmailService, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { gmail.close() }
        gmail.webView.loadHTMLString("<html><body>Gmail identification fixture</body></html>", baseURL: service.url)
        try await waitFor("Gmail identification fixture") { !gmail.webView.isLoading && gmail.webView.url != nil }
        let gmailAgent = try await gmail.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        print("Gmail user agent: \(gmailAgent)")
        try require(gmailAgent.contains("Macintosh") && gmailAgent.contains("AppleWebKit/") && !gmailAgent.contains("Mobile") && gmailAgent.hasSuffix(BrowserSession.safariApplicationName),
                    "Gmail must receive the installed desktop Safari version")
        let calendarService = Service(id: "calendar", name: "Calendar", url: URL(string: "https://calendar.google.com/calendar/")!, glyph: "C", hosts: ["google.com"])
        let calendar = BrowserSession(account: Account(id: UUID(), serviceID: "calendar", name: "Calendar"),
            service: calendarService, downloads: center, dataStore: .nonPersistent(), loadImmediately: false)
        defer { calendar.close() }
        calendar.webView.loadHTMLString("<html><body>Calendar identification fixture</body></html>", baseURL: service.url)
        try await waitFor("Calendar identification fixture") { !calendar.webView.isLoading && calendar.webView.url != nil }
        let calendarAgent = try await calendar.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try require(calendarAgent.contains("Macintosh") && calendarAgent.contains("AppleWebKit/") && !calendarAgent.contains("Mobile") && calendarAgent.hasSuffix(BrowserSession.safariApplicationName),
                    "Calendar must receive the installed desktop Safari version")
        calendar.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await calendar.webView.evaluateJavaScript("void window.open('about:blank', 'calendar-signin-fixture')")
        try await waitFor("Calendar popup") { calendar.browserViews.count == 2 }
        let calendarPopup = calendar.browserViews[1]
        let popupAgent = try await calendarPopup.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try require(popupAgent == calendarAgent, "Calendar popup must preserve the main page's browser identification")
        try require(calendarPopup.configuration.websiteDataStore === calendar.webView.configuration.websiteDataStore,
                    "Calendar popup must preserve the account's website data store")
        print("Passed: Calendar main page and popup use the installed Safari identifier and retain account storage")
        let cookie = HTTPCookie(properties: [.domain: "relay.test", .path: "/", .name: "relay-fixture", .value: "first-only", .secure: "TRUE"])!
        await stores[0].httpCookieStore.setCookie(cookie)
        let firstCookies = await stores[0].httpCookieStore.allCookies()
        let secondCookies = await stores[1].httpCookieStore.allCookies()
        try require(firstCookies.contains { $0.name == "relay-fixture" }, "Cookie must reach its own profile")
        try require(!secondCookies.contains { $0.name == "relay-fixture" }, "Cookie leaked into another account")
        for (index, session) in [first, second].enumerated() {
            session.webView.loadHTMLString("<html><body>Relay download fixture</body></html>", baseURL: service.url)
            try await waitFor("fixture page loaded") { !session.webView.isLoading && session.webView.url != nil }
            let fixtureAgent = try await session.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            try require(fixtureAgent.contains("Macintosh") && fixtureAgent.contains("AppleWebKit/") && fixtureAgent.hasSuffix(BrowserSession.safariApplicationName),
                        "An unlisted service must receive desktop Safari version identification")
            _ = try await session.webView.evaluateJavaScript("""
                (() => {
                    const a = document.createElement('a');
                    a.href = URL.createObjectURL(new Blob(['account-\(index)'], {type:'application/octet-stream'}));
                    a.download = 'account-\(index).txt'; document.body.appendChild(a); a.click();
                })();
                """)
            try await waitFor("blob download") { center.items.count == index + 1 && !center.items[0].isActive }
            let item = center.items[0]
            try require(item.status == .complete, "Blob download failed: \(item.failure ?? item.status.rawValue)")
            try require(item.account.id == accounts[index].id, "Wrong account on download")
            let bytes = try String(contentsOf: directory.appendingPathComponent("account-\(index).txt"), encoding: .utf8)
            try require(bytes == "account-\(index)", "Downloaded bytes differ")
            try require(item.download == nil && item.observations.isEmpty, "Completed download retained browser handles")
            try require(!center.hasActiveDownloads(accounts[index].id), "Completed account still marked busy")
        }
        let restoredHistory = DownloadCenter(); restoredHistory.configureHistory(historyURL)
        try require(Set(restoredHistory.items.map(\.id)) == Set(center.items.map(\.id)), "Restored downloads must preserve their stable identities")
        try require(restoredHistory.items.count == 2 && restoredHistory.items.allSatisfy { $0.status == .complete && !$0.canResume && !$0.isActive && $0.destination == nil && $0.revealURL != nil }, "Restart history must restore records without browser handles or staging folders")
        center.destinationForTesting = { _ in nil }
        _ = try await first.webView.evaluateJavaScript("""
            (() => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['cancel']));
            a.download = 'cancelled.txt'; document.body.appendChild(a); a.click(); })();
            """)
        try await waitFor("save cancellation") { center.items.count == 3 && !center.items[0].isActive }
        try require(center.items[0].status == .cancelled, "Save cancellation was not recorded")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.txt").path), "Canceled save wrote a file")
        let existing = directory.appendingPathComponent("keep.txt")
        try Data("keep the original".utf8).write(to: existing)
        center.destinationForTesting = { _ in
            Task { @MainActor in if let item = center.items.first { center.cancel(item) } }
            return existing
        }
        _ = try await first.webView.evaluateJavaScript("""
            (() => { const a = document.createElement('a');
            a.href = URL.createObjectURL(new Blob([new Uint8Array(32 * 1024 * 1024)]));
            a.download = 'keep.txt'; document.body.appendChild(a); a.click(); })();
            """)
        try await waitFor("active cancellation") {
            center.items.count == 4 && !center.items[0].isActive && !center.hasActiveDownloads(accounts[0].id)
        }
        try require(center.items[0].status == .cancelled, "Active transfer was not canceled: \(center.items[0].status.rawValue), \(center.items[0].failure ?? "no error")")
        try require(try String(contentsOf: existing, encoding: .utf8) == "keep the original", "Cancellation replaced the existing file")
        if let staging = center.items[0].destination?.stagingDirectory {
            try require(!FileManager.default.fileExists(atPath: staging.path), "Canceled transfer left staging files")
        }
        center.clearFinished()
        try require(center.items.isEmpty, "Finished history was not cleared")
        let clearedHistory = DownloadCenter(); clearedHistory.configureHistory(historyURL)
        try require(clearedHistory.items.isEmpty, "Cleared download history returned after restart")
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("account-0.txt").path), "Clearing history deleted a download")
        try require(first.error == nil && second.error == nil, "Downloading displayed a page error: \(first.error ?? second.error ?? "")")
    }

    @MainActor static func unreadChecks() async throws {
        let center = UnreadCenter()
        let downloads = DownloadCenter()
        let service = Service(id: "whatsapp", name: "Fixture", url: URL(string: "https://relay.test/")!, glyph: "F", hosts: ["relay.test"])
        let firstID = UUID(), secondID = UUID()
        let first = BrowserSession(account: Account(id: firstID, serviceID: service.id, name: "First"), service: service,
            downloads: downloads, dataStore: .nonPersistent(), loadImmediately: false)
        let second = BrowserSession(account: Account(id: secondID, serviceID: service.id, name: "Second"), service: service,
            downloads: downloads, dataStore: .nonPersistent(), loadImmediately: false)
        first.onUnread = { center.receive($0, for: firstID) }
        second.onUnread = { center.receive($0, for: secondID) }
        defer { first.close(); second.close() }
        let html = "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>(4) WhatsApp</title></head><body>Fixture</body></html>"
        first.webView.loadHTMLString(html, baseURL: service.url)
        second.webView.loadHTMLString(html.replacingOccurrences(of: "(4)", with: "(2)"), baseURL: service.url)
        try await waitFor("separate title badges") { center.badge(for: firstID) == "4" && center.badge(for: secondID) == "2" }
        try require(center.dockBadge == "6", "Dock total should combine accounts")
        center.dismiss(firstID)
        try require(center.badge(for: firstID).isEmpty && center.badge(for: secondID) == "2", "Dismissal crossed account boundaries")
        _ = try await first.webView.evaluateJavaScript("document.title = 'WhatsApp';")
        _ = try await first.webView.evaluateJavaScript("document.title = '(4) WhatsApp';")
        await first.refreshUnread()
        try require(center.badge(for: firstID).isEmpty, "Repeated title restored dismissed count")
        _ = try await first.webView.evaluateJavaScript("document.title = '(5) WhatsApp';")
        try await waitFor("live title change") { center.badge(for: firstID) == "5" }
        let historyCount = center.activity.count
        await first.refreshUnread()
        try require(center.activity.count == historyCount, "Duplicate reading added activity")
        center.clearActivity()
        try require(center.activity.isEmpty && center.badge(for: firstID) == "5", "Clear changed unread badges")

        let gmailID = UUID()
        let gmailService = Service(id: "gmail", name: "Gmail", url: URL(string: "https://mail.google.com/mail/u/0/")!, glyph: "G", hosts: ["google.com"])
        let gmail = BrowserSession(account: Account(id: gmailID, serviceID: "gmail", name: "Gmail fixture"),
            service: gmailService, downloads: downloads, dataStore: .nonPersistent(), loadImmediately: false)
        var gmailAllUnread = true
        gmail.onUnread = { center.receiveGmail($0, for: gmailID, allUnread: gmailAllUnread) }
        defer { gmail.close() }
        gmail.webView.loadHTMLString("""
            <html><head><title>Sent Mail - Gmail</title></head><body>
            <nav><div class="aim"><a href="#inbox">Inbox</a><span class="bsU">1,234</span></div></nav>
            </body></html>
            """, baseURL: gmailService.url)
        try await waitFor("Gmail inbox count outside inbox") { center.states[gmailID]?.current.count == 1234 }
        let gmailActivity = center.activity.count
        await gmail.refreshUnread()
        try require(center.activity.count == gmailActivity, "Repeated Gmail poll created duplicate activity")
        _ = try await gmail.webView.evaluateJavaScript("document.querySelector('.bsU').textContent = '1,235'")
        try await waitFor("Gmail new mail without title change") { center.states[gmailID]?.current.count == 1235 }
        try require(center.activity.count == gmailActivity + 1, "New Gmail unread count did not create pending activity")
        gmailAllUnread = false
        center.setGmailMode(for: gmailID, allUnread: false)
        try require(center.badge(for: gmailID).isEmpty && !center.activity.contains { $0.accountID == gmailID }, "Switching Gmail mode must clear backlog activity")
        _ = try await gmail.webView.evaluateJavaScript("document.querySelector('.bsU').textContent = '1,236'")
        try await waitFor("Gmail net new count") { center.states[gmailID]?.current.count == 1 }
        try require(center.activity.filter { $0.accountID == gmailID }.count == 1, "Net new Gmail should create exactly one activity entry")
        _ = try await gmail.webView.evaluateJavaScript("document.querySelector('.bsU').remove()")
        try await waitFor("Gmail inbox read clears badge") { center.states[gmailID]?.current.count == 0 && center.badge(for: gmailID).isEmpty }

        let messengerID = UUID()
        let messengerService = Service(id: "messenger", name: "Messenger", url: URL(string: "https://www.facebook.com/messages/")!, glyph: "M", hosts: ["facebook.com"])
        let messenger = BrowserSession(account: Account(id: messengerID, serviceID: "messenger", name: "Messenger fixture"),
            service: messengerService, downloads: downloads, dataStore: .nonPersistent(), loadImmediately: false)
        messenger.onUnread = { center.receive($0, for: messengerID) }
        defer { messenger.close() }
        messenger.webView.loadHTMLString("""
            <html><head><meta http-equiv='Content-Security-Policy' content="default-src 'none'"><title>(28) Facebook</title></head>
            <body><nav><button aria-label="Messenger, 3 unread messages"></button></nav></body></html>
            """, baseURL: messengerService.url)
        try await waitFor("Messenger-specific total") { center.badge(for: messengerID) == "3" }
        _ = try await messenger.webView.evaluateJavaScript("document.querySelector('nav').remove();")
        try await waitFor("ignore Facebook notification count") { center.badge(for: messengerID).isEmpty }
        _ = try await messenger.webView.evaluateJavaScript("""
            document.body.innerHTML = '<div role="row"><a href="/messages/t/123"><span aria-label="Unread messages"></span></a></div>';
            """)
        try await waitFor("Messenger DOM polling") { center.badge(for: messengerID) == "•" }
        center.dismiss(messengerID)
        await messenger.refreshUnread()
        try require(center.badge(for: messengerID).isEmpty, "Unchanged row restored dismissed unread marker")
        _ = try await messenger.webView.evaluateJavaScript("document.querySelector('a').href = '/messages/t/456';")
        try await waitFor("new unread row after dismissal") { center.badge(for: messengerID) == "•" }
        try require(center.states[messengerID]?.current.count == nil, "Virtualized rows must not become a fabricated total")

        let beforeClose = center.activity.count
        center.dismiss(messengerID)
        let dismissedReading = center.states[messengerID]!.current
        messenger.close()
        center.forget(messengerID, removeActivity: false)
        await messenger.refreshUnread()
        try require(center.badge(for: messengerID).isEmpty && center.activity.count <= beforeClose, "Closed browser reported stale unread")
        center.receive(dismissedReading, for: messengerID)
        try require(center.badge(for: messengerID).isEmpty, "Unloading lost the account's dismissed signal")
        // A finite history even when the service continuously increments its title.
        for count in 10...90 { center.receive(UnreadReading(count: count, attention: false, key: "fixture:\(count)"), for: firstID) }
        try require(center.activity.count == 60, "Activity history exceeded its bound")
        center.forget(firstID, removeActivity: true)
        try require(!center.activity.contains { $0.accountID == firstID }, "Removed account retained activity")
    }
}
