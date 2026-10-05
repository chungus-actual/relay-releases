import AppKit

@MainActor
final class Checks: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var sessions: [ChromiumSession] = []
    var browsers: [BrowserSession] = []
    let downloads = DownloadCenter()
    var notifications = Set<String>()
    var loaded = Set<Int>()
    var downloadComplete = false
    var downloadURL: URL!
    var failure: String?
    let interactive = CommandLine.arguments.contains("--interactive")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        browsers.forEach { $0.close() }
        sessions.removeAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Relay Chromium bridge checks"
        window.isReleasedWhenClosed = false
        do {
            let base = URL(string: CommandLine.arguments[1])!
            downloadURL = URL(fileURLWithPath: CommandLine.arguments[2])
            downloads.destinationForTesting = { [weak self] _ in self?.downloadURL }
            for index in 0..<2 {
                let service = Service(id: "fixture", name: "Fixture", url: base, glyph: "", hosts: ["127.0.0.1"])
                let account = Account(id: UUID(), serviceID: service.id, name: "Fixture \(index)", pageZoom: index == 0 ? 1.25 : 1, audioMuted: index == 0, browserEngine: "chromium")
                let browser = BrowserSession(account: account, service: service, downloads: downloads, loadImmediately: false, chromiumTesting: true)
                browsers.append(browser)
                guard let session = browser.chromium else { throw ChromiumSession.Failure(message: browser.error ?? "Chromium missing") }
                sessions.append(session)
                session.view.frame = NSRect(x: index * 500, y: 0, width: 500, height: 650)
                window.contentView!.addSubview(session.view)
                session.notificationsAllowed = { true }
                session.onLoaded = { [weak self] page, ok in
                    if page == 0 && ok { self?.loaded.insert(index) }
                }
                session.onNotification = { [weak self, weak session] id, title, body in
                    guard let self else { return }
                    if !title.hasSuffix("-\(index)") || body != "fixture body" { self.failure = "Notification crossed accounts or lost its body" }
                    self.notifications.insert(title)
                    session?.command("notification", ["id": id, "click": true])
                }
                browser.load(base.appendingPathComponent(String(index)))
            }
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await run() }
        } catch { finish(error.localizedDescription) }
    }

    func require(_ value: Bool, _ description: String) throws {
        if !value { throw ChromiumSession.Failure(message: description) }
    }
    func run() async {
        do {
            for _ in 0..<100 {
                if loaded.count == 2 && notifications.count == 4 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try require(loaded.count == 2 && notifications.count == 4, "Missing page/worker notifications: \(notifications)")
            for (index, session) in sessions.enumerated() {
                session.command("state")
                let state = session.pages[0]!
                try require(state.muted == (index == 0), "Native audio mute mismatch")
                try require(state.zoom == (index == 0 ? 1.25 : 1), "Native zoom mismatch")
                let desktop = try await session.evaluate("return (async()=>({ua:navigator.userAgent,mobile:navigator.userAgentData?.mobile,width:innerWidth,headers:await (await fetch('/headers')).json()}))();") as! [String: Any]
                let ua = desktop["ua"] as? String ?? ""
                try require(ua.contains("Macintosh") && ua.contains("Chrome/") && !ua.contains("QtWebEngine") && !ua.contains("Mobile"), "Desktop user agent mismatch: \(ua)")
                try require(desktop["mobile"] as? Bool == false, "Mobile client hint enabled")
                let headers = desktop["headers"] as! [String: String]
                let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
                try require(normalized["user-agent"] == ua && normalized["sec-ch-ua-mobile"] == "?0", "HTTP desktop identity mismatch: \(headers)")
                try require(abs((desktop["width"] as? Double ?? 0) - 500 / state.zoom) <= 1, "Viewport does not match native host: \(desktop)")
                let value = try await session.evaluate("return {initial:window.initial, cookie:document.cookie, local:localStorage.getItem('relay'), clicks:window.clicks};") as! [String: Any]
                let initial = value["initial"] as! [String: Any]
                try require(initial["cookie"] as? String == "" && initial["local"] is NSNull, "Profile storage leaked")
                try require(value["local"] as? String == String(index) && value["cookie"] as? String == "relay=\(index)", "Account storage changed")
                try require(Set(value["clicks"] as? [String] ?? []) == Set(["page", "worker"]), "Page/worker click callback missing: \(value)")
            }
            let pids = Set(sessions.compactMap { $0.pages[0]?.pid })
            let rows = ChromiumRuntime.shared.processes()
            print("PROCESS READINGS \(rows); RENDERERS \(pids)")
            try require(pids.count == 2 && !pids.contains(0), "Renderer identity missing")
            for pid in pids {
                try require(rows.contains { ($0["pid"] as? Int) == Int(pid) && ($0["memory"] as? Double ?? 0) > 0 }, "Renderer resource reading missing for \(pid)")
            }
            let first = sessions[0]
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let mediaFixture = try String(contentsOf: root.appendingPathComponent("Assets/Fixtures/media-playback-checks.js"), encoding: .utf8)
            let mediaResult = try await first.evaluate("return " + mediaFixture) as? [String: Any]
            try require((mediaResult?["failures"] as? [String]) == [], "Shared Chromium media regressions: \(String(describing: mediaResult))")
            _ = try await first.evaluate("window.savedMediaBridge=window.__relayMedia;window.__relayMedia={read:()=>({playing:true}),act:async action=>{window.floatingAction=action;return true;}};return true;")
            await browsers[0].toggleFloatingPlayback()
            let floatingAction = try await first.evaluate("const action=window.floatingAction;window.__relayMedia=window.savedMediaBridge;delete window.savedMediaBridge;return action;") as? String
            try require(floatingAction == "pause", "Native floating playback must await the Chromium media action")
            let renderer = Int(first.pages[0]!.pid)
            let before = rows.first { $0["pid"] as? Int == renderer }?["timeTicks"] as? Double ?? 0
            _ = try await first.evaluate("const end=performance.now()+250;while(performance.now()<end){};return true;")
            let sampled = await ChromiumRuntime.shared.processData()
            let afterRows = try JSONSerialization.jsonObject(with: sampled ?? Data()) as! [[String: Any]]
            let after = afterRows.first { $0["pid"] as? Int == renderer }?["timeTicks"] as? Double ?? 0
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            let seconds = (after - before) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
            try require(seconds > 0.1 && seconds < 2, "Renderer CPU tick conversion failed: \(seconds)")
            let codecs = try await first.evaluate("const v=document.createElement('video');return {userAgent:navigator.userAgent,h264:v.canPlayType('video/mp4; codecs=\"avc1.42E01E\"'),aac:v.canPlayType('audio/mp4; codecs=\"mp4a.40.2\"'),vp9:v.canPlayType('video/webm; codecs=\"vp9\"')};")
            print("CAPABILITIES \(codecs)")
            _ = try await first.evaluate("const a=document.createElement('a');a.href='/download';a.download='fixture.bin';document.body.append(a);a.click();return true;")
            for _ in 0..<50 {
                if downloads.items.first?.status == .complete || failure != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try require(downloads.items.first?.status == .complete, "Relay download did not complete")
            try require(!downloads.hasActiveDownloads(browsers[0].accountID), "Completed transfer blocked unload")
            try require(browsers[0].address == sessions[0].pages[0]?.url, "Shell address did not update")
            try require(try Data(contentsOf: downloadURL) == Data(repeating: 42, count: 65536), "Download bytes differ")
            if let failure { throw ChromiumSession.Failure(message: failure) }
            let deck = BrowserDeckView(frame: window.contentView!.bounds)
            for session in sessions {
                _ = try await session.evaluate("window.switchToken=Math.random();window.originalSwitchToken=window.switchToken;return true;")
            }
            window.contentView = deck
            for selection in [0, 1, 0, 1] {
                deck.update(views: sessions.map(\.view), selected: sessions[selection].view)
                try await Task.sleep(for: .milliseconds(150))
                for (index, session) in sessions.enumerated() {
                    try require(session.view.window === window, "Chromium switch detached a loaded browser")
                    let state = try await session.evaluate("return {hidden:document.hidden,intact:window.switchToken===window.originalSwitchToken};") as! [String: Any]
                    try require(state["hidden"] as? Bool == (index != selection), "Chromium native visibility did not follow service selection")
                    try require(state["intact"] as? Bool == true, "Chromium switch reloaded the document")
                }
            }
            var docked = 0
            browsers[0].popOutService { docked += 1 }
            let child = browsers[0].serviceWindow
            browsers[0].popOutService { docked += 100 }
            browsers[1].popOutService { docked += 1 }
            try require(child != nil && browsers[0].serviceWindow === child && sessions[0].view.window === child && browsers[1].serviceWindow != nil,
                        "Chromium accounts retain separate reusable pop-out windows")
            deck.update(views: sessions.map(\.view), selected: nil, visible: [])
            let poppedState = try await sessions[0].evaluate("return {hidden:document.hidden,intact:window.switchToken===window.originalSwitchToken};") as! [String: Any]
            try require(!sessions[0].view.isHidden && poppedState["hidden"] as? Bool == false && poppedState["intact"] as? Bool == true,
                        "Chromium pop-outs stay visible and retain their document across local pages")
            browsers[0].setNativeAppearance(dark: false, background: .white, foreground: .black)
            try require(child?.appearance?.name == .aqua && child?.backgroundColor == .white, "Chromium pop-out follows native appearance")
            child?.close(); child?.close(); browsers[1].dockServiceWindow(select: false)
            try require(docked == 1 && sessions.allSatisfy { $0.view.superview === deck } && browsers.allSatisfy { $0.serviceWindow == nil },
                        "Chromium dock/close restores each native view exactly once")
            var panes = WorkspaceLayout(panes: browsers.map(\.accountID), arrangement: "columns")
            panes.normalizeSizes()
            deck.update(views: sessions.map(\.view), selected: sessions[0].view, visible: sessions.map(\.view), layout: panes)
            var focused = 0
            let paneViews = sessions.map(\.view)
            deck.onFocus = { target in
                focused += 1
                deck.update(views: paneViews, selected: target, visible: paneViews, layout: panes)
            }
            let frame = sessions[1].view.frame
            let location = deck.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
            try require(deck.selectedView === sessions[1].view && focused == 1, "Native Chromium clicks must select their pane exactly once")
            deck.onFocus = nil
            panes.resize(0, position: 0.7)
            deck.update(views: sessions.map(\.view), selected: sessions[1].view, visible: sessions.map(\.view), layout: panes)
            try await Task.sleep(for: .milliseconds(150))
            try require(sessions[0].view.frame.width > sessions[1].view.frame.width && !sessions[0].view.frame.intersects(sessions[1].view.frame), "Chromium panes must resize without overlapping")
            for session in sessions {
                let state = try await session.evaluate("return {hidden:document.hidden,intact:window.switchToken===window.originalSwitchToken};") as! [String: Any]
                try require(state["hidden"] as? Bool == false && state["intact"] as? Bool == true, "Both Chromium panes remain visible and retain documents after resizing")
            }
            panes.arrangement = "rows"; panes.cuts = []; panes.normalizeSizes()
            deck.update(views: sessions.map(\.view), selected: sessions[0].view, visible: sessions.map(\.view), layout: panes, transition: 1)
            panes.arrangement = "main-left"; panes.cuts = []; panes.normalizeSizes()
            deck.update(views: sessions.map(\.view), selected: sessions[0].view, visible: sessions.map(\.view), layout: panes, transition: 2)
            try await Task.sleep(for: .milliseconds(300))
            try require(abs(sessions[0].view.frame.width - (deck.bounds.width * panes.primary - 6)) < 1,
                        "Chromium frame transitions finish at the latest requested geometry")
            for session in sessions {
                let intact = try await session.evaluate("return window.switchToken===window.originalSwitchToken;") as? Bool
                try require(intact == true, "Chromium animation must retain its document")
            }
            deck.update(views: sessions.map(\.view), selected: nil)
            try await Task.sleep(for: .milliseconds(150))
            for session in sessions {
                let hidden = try await session.evaluate("return document.hidden;") as? Bool
                try require(hidden == true, "Local pages must hide Chromium content")
            }
            deck.update(views: sessions.map(\.view), selected: sessions[0].view)
            print("PASS: Chromium retained switching, page visibility, local pages, and document preservation")
            if interactive {
                window.title = "Relay Chromium prototype — checks passed"
                print("READY: Chromium prototype is open; close its window to exit.")
                fflush(stdout)
            } else { finish(nil) }
        } catch { finish(error.localizedDescription) }
    }
    func finish(_ failure: String?) {
        browsers.forEach { $0.close() }; sessions.removeAll()
        print(failure.map { "FAIL: \($0)" } ?? "PASS: Swift/AppKit host, isolated profiles, page + worker notifications and clicks, mute, zoom, renderer resources, Relay download integration, teardown")
        fflush(stdout)
        exit(failure == nil ? 0 : 1)
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Checks(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
