import AppKit
import WebKit

extension BrowserChecks {
    @MainActor static func terminalChecks() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("ghostty-config")
        try "font-family = Menlo\nfont-size = 18\nbackground = 123456\npalette = 2=#abcdef\ncursor-style = bar\ncommand = /bin/false\nconfig-file = extra.conf\n".write(to: config, atomically: true, encoding: .utf8)
        try "font-size = 19\nconfig-file = ghostty-config\n".write(to: home.appendingPathComponent("extra.conf"), atomically: true, encoding: .utf8)
        let ghost = TerminalProfiles.ghostty(TerminalProfiles.ghosttyValues(url: config))!
        try require(ghost.fontSize == 19 && ghost.colors["green"] == "#abcdef" && ghost.cursorStyle == "bar", "Ghostty imports appearance, relative includes and bounded include cycles")
        let font = try NSKeyedArchiver.archivedData(withRootObject: NSFont(name: "Menlo", size: 17)!, requiringSecureCoding: true)
        let apple = TerminalProfiles.appleTerminal(["Font": font, "CursorBlink": true], name: "Fixture")!
        try require(apple.fontSize == 17 && apple.fontFamily?.contains("Menlo") == true && apple.cursorBlink == true, "Terminal archived font and cursor import")
        let imported = TerminalProfiles.iTerm(["Name": "Fixture", "Guid": "test", "Normal Font": "Menlo-Regular 16", "Scrollback Lines": 8000,
            "Background Color": ["Red Component": 0.1, "Green Component": 0.2, "Blue Component": 0.3]])!
        try require(imported.fontSize == 16 && imported.scrollback == 8000 && imported.colors["background"] == "#1a334d", "iTerm font, scrollback and color import")
        try require(TerminalProfiles.ghostty(["command": "do not execute"]) == nil, "Unsupported shell settings do not become an appearance profile")
        let first = BrowserSession(account: Account(id: UUID(), serviceID: "terminal", name: "Terminal one"), service: .terminal,
            downloads: DownloadCenter(), terminalAssets: root.appendingPathComponent("Assets/Terminal"), terminalShell: "/bin/sh", terminalHome: home.path)
        let second = BrowserSession(account: Account(id: UUID(), serviceID: "terminal", name: "Terminal two"), service: .terminal,
            downloads: DownloadCenter(), terminalAssets: root.appendingPathComponent("Assets/Terminal"), terminalShell: "/bin/sh", terminalHome: home.path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let deck = BrowserDeckView(frame: window.contentView!.bounds); window.contentView = deck
        window.orderFrontRegardless()
        deck.update(views: [first.webView, second.webView], selected: first.webView)
        defer { first.close(); second.close(); window.close() }
        let terminal = first.terminal!, workspace = terminal.workspace
        terminal.detectedProfiles = [imported, ghost, apple]
        defer { UserDefaults.standard.removeObject(forKey: "terminal.profile." + first.accountID.uuidString) }
        terminal.confirmRestart = { true }
        func stage(_ text: String) { print("Terminal: \(text)"); fflush(stdout) }
        func send(_ data: [String: Any], to session: BrowserSession = first) async throws {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            _ = try await session.webView.evaluateJavaScript("window.webkit.messageHandlers.relayTerminal.postMessage(\(json));void 0")
            await Task.yield()
        }
        func history(_ pane: TerminalPane) -> String { String(decoding: pane.history, as: UTF8.self) }
        func input(_ text: String, pane: TerminalPane, session: BrowserSession = first) async throws {
            try await send(["type": "input", "pane": pane.id, "data": text], to: session)
        }
        do { try await waitFor("terminal page and PTY") { workspace.current?.panes.first?.process != nil } }
        catch {
            print("Terminal startup: url=\(String(describing: first.webView.url)), error=\(first.error ?? "none"), tabs=\(workspace.tabs.count), status=\(workspace.current?.panes.first?.status ?? "none")"); fflush(stdout)
            let state = try? await first.webView.evaluateJavaScript("({state:document.readyState,terminal:typeof Terminal,receive:typeof window.__relayTerminalReceive,text:document.body.innerText,width:innerWidth,height:innerHeight,panes:[...document.querySelectorAll('.terminal-host')].map(x=>({width:x.clientWidth,height:x.clientHeight})),children:document.getElementById('workspace').children.length})")
            print("Terminal document: \(String(describing: state))"); fflush(stdout)
            throw error
        }
        let policyFixture = try String(contentsOf: root.appendingPathComponent("Assets/Fixtures/terminal-policy-checks.js"), encoding: .utf8)
        let policyBlocked = try await first.webView.callAsyncJavaScript("return await " + policyFixture, arguments: [:], in: nil, contentWorld: .page) as? Bool
        try require(policyBlocked == true, "Terminal CSP blocks worker creation and remote fetches")
        let tab = workspace.current!, pane = tab.panes[0], originalPID = pane.process!.processID
        try await input("printf '\\n%s%s\\n' RELAY_ READY; tty; stty size\r", pane: pane)
        try await waitFor("PTY output") { history(pane).contains("RELAY_READY") && history(pane).contains("/dev/ttys") }
        try require(first.error == nil && first.chromium == nil && !first.webView.configuration.websiteDataStore.isPersistent, "Terminal uses an isolated local WebKit page")
        try await send(["type": "ready"])
        try await send(["type": "pane-ready", "pane": pane.id, "cols": 91, "rows": 31])
        try await input("stty size\r", pane: pane)
        try await waitFor("PTY resize") { history(pane).contains("31 91") }
        try require(workspace.tabs.count == 1 && pane.process?.processID == originalPID, "Duplicate readiness must not start another shell")
        stage("real PTY, duplicate readiness and resize passed")
        _ = try await first.webView.evaluateJavaScript("const s=document.getElementById('profile');s.value='iterm:test';s.dispatchEvent(new Event('change'));void 0")
        try await waitFor("profile import") { terminal.profile?.id == imported.id }
        try require(pane.process?.processID == originalPID, "Import updates existing shells without restarting them")
        let family = try await first.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.xterm-rows')).fontFamily") as? String
        try require(family?.contains("Menlo") == true, "Imported font reaches the terminal renderer")
        let restored = TerminalSession(accountID: first.accountID)
        try require(restored.profile?.fontSize == 16 && restored.profile?.colors == imported.colors, "Profile snapshot persists across sessions")
        restored.close()
        try await send(["type": "import-profile", "id": "unknown"])
        try require(terminal.profile?.id == imported.id, "Unknown imports cannot change the selected profile")
        try await send(["type": "import-profile", "id": ""])
        try require(terminal.profile == nil, "Relay defaults can be restored")
        stage("detected profile import, live font, persistence and reset passed")

        // Exercise real xterm keyboard delivery through WebKit's native responder.
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(first.webView)
        _ = try await first.webView.evaluateJavaScript("document.querySelector('.xterm-helper-textarea').focus();void 0")
        try await Task.sleep(for: .milliseconds(100))
        for character in "printf '\\n%s%s\\n' NATIVE_ KEY\r" {
            let value = String(character)
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: character == "\r" ? 36 : 0)!
            window.sendEvent(key)
        }
        try await waitFor("native terminal keyboard input") { history(pane).contains("NATIVE_KEY") }
        stage("native keyboard input passed")
        try await input("sleep 300\r", pane: pane)
        try await Task.sleep(for: .milliseconds(100))
        try await input("\u{03}", pane: pane)
        try await input("printf '\\n%s%s\\n' INTERRUPT_ OK\r", pane: pane)
        try await waitFor("foreground job interrupt") { history(pane).contains("INTERRUPT_OK") }

        _ = try await first.webView.evaluateJavaScript("document.getElementById('split').click();void 0")
        try await waitFor("split PTY") { tab.panes.count == 2 && tab.panes[1].process != nil }
        let right = tab.panes[1]
        try await input("printf '\\n%s%s\\n' SPLIT_ RIGHT\r", pane: right)
        try await waitFor("independent split output") { history(right).contains("SPLIT_RIGHT") }
        try require(!history(pane).contains("SPLIT_RIGHT"), "Split output is scoped to its pane")
        _ = try await first.webView.evaluateJavaScript("document.getElementById('split-rows').click();void 0")
        try await waitFor("nested PTY") { tab.panes.count == 3 && tab.panes[2].process != nil }
        let lower = tab.panes[2]
        try require(tab.layout?.direction == "columns" && tab.layout?.second?.direction == "rows", "Mixed-direction nested splits retain structure")
        try await send(["type": "resize-layout", "pane": lower.id, "split": tab.layout!.id, "ratio": 0.7])
        try await send(["type": "zoom", "pane": lower.id])
        try require(tab.zoomed && tab.layout?.ratio == 0.7, "Zoom and divider resizing update only the active tab")
        try await send(["type": "zoom", "pane": lower.id])
        try await send(["type": "rename-tab", "tab": tab.id, "name": "Build"])
        try await send(["type": "rename-pane", "pane": lower.id, "name": "Logs"])
        try await send(["type": "rename-pane", "pane": lower.id, "name": "bad\nname"])
        try require(tab.name == "Build" && lower.name == "Logs", "Renaming preserves identity and rejects control characters")
        // Editing must keep keyboard focus during non-focusing state messages.
        _ = try await first.webView.evaluateJavaScript("document.querySelector('.tab-select').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));void 0")
        try await send(["type": "rename-pane", "pane": lower.id, "name": "Log stream"])
        let editing = try await first.webView.evaluateJavaScript("document.activeElement.classList.contains('session-name-input')") as? Bool
        try require(editing == true, "State publication must preserve the inline rename editor")
        _ = try await first.webView.evaluateJavaScript("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));void 0")
        stage("nested splits, focus-preserving rename, zoom and resize passed")

        _ = try await first.webView.evaluateJavaScript("document.getElementById('new').click();void 0")
        try await waitFor("second tab shell") { workspace.tabs.count == 2 && workspace.current?.panes.first?.process != nil }
        let otherTab = workspace.current!, otherPane = otherTab.panes[0]
        let exitedPID = otherPane.process!.processID
        try await input("exit\r", pane: otherPane)
        try await waitFor("shell exit") { otherPane.status == "Shell exited" }
        try await send(["type": "pane-ready", "pane": otherPane.id])
        try require(otherPane.process?.processID == exitedPID, "Readiness must not restart an exited shell")
        try await send(["type": "restart", "pane": otherPane.id])
        try await waitFor("explicit shell restart") { otherPane.process != nil && otherPane.process?.processID != exitedPID }
        let oldCount = pane.history.count
        try await input("printf STALE_INPUT\r", pane: pane)
        try await send(["type": "focus", "pane": pane.id])
        try await Task.sleep(for: .milliseconds(120))
        try require(workspace.current === otherTab && pane.history.count == oldCount, "Hidden-tab input and focus are ignored")
        try await send(["type": "select-tab", "tab": tab.id])
        deck.update(views: [first.webView, second.webView], selected: second.webView)
        try await waitFor("second account PTY") { second.terminal?.workspace.current?.panes.first?.process != nil }
        let foreign = second.terminal!.workspace.current!.panes[0]
        try await send(["type": "close-pane", "pane": foreign.id])
        try await send(["type": "input", "pane": foreign.id, "data": "printf CROSS_ACCOUNT\r"])
        try require(second.terminal?.workspace.current?.panes.first === foreign && !history(foreign).contains("CROSS_ACCOUNT"), "Cross-account messages cannot address another shell")
        deck.update(views: [first.webView, second.webView], selected: first.webView)
        try require(pane.process?.processID == originalPID && history(pane).contains("RELAY_READY"), "Service switching retains shell and output")

        var closedViews = 0
        terminal.onCloseView = { closedViews += 1 }
        try await send(["type": "close-view"])
        try require(closedViews == 1 && pane.process?.processID == originalPID, "Closing the outer view preserves the workspace")
        var docked = 0
        first.popOutService { docked += 1 }; let child = first.serviceWindow
        first.popOutService { docked += 100 }
        try require(child != nil && child === first.serviceWindow && first.webView.window === child, "Terminal pop-out retains its native view")
        first.setNativeAppearance(dark: false, background: .white, foreground: .black, accent: .systemBlue)
        let light = try await first.webView.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--background').trim()") as? String
        try require(light == "#ffffff", "Terminal colors track Relay appearance")
        func snapshot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(150))
            let image = try await first.webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: root.appendingPathComponent("macos/.build/checks/terminal-\(name).png"))
            }
        }
        try await snapshot("light")
        first.setNativeAppearance(dark: true, background: .black, foreground: .white, accent: .systemGreen)
        try await snapshot("dark")
        if let nerd = NSFontManager.shared.availableFontFamilies.sorted().first(where: { $0.contains("Nerd Font") || $0.hasSuffix(" NF") }),
           let font = NSFont(name: nerd, size: 14),
           let icons = TerminalProfiles.iTerm(["Name": "Nerd Font check", "Guid": "nerd-fixture", "Normal Font": font.fontName + " 14"]) {
            terminal.detectedProfiles.append(icons)
            try await send(["type": "import-profile", "id": icons.id])
            try await send(["type": "focus", "pane": pane.id])
            try await input("printf '\\nNerd Font:           ✓\\n'\r", pane: pane)
            try await Task.sleep(for: .milliseconds(250))
            let glyphsAvailable = try await first.webView.callAsyncJavaScript("""
                function render(font) {
                  const c=document.createElement('canvas');c.width=80;c.height=50;
                  const x=c.getContext('2d');x.font='24px '+font;x.fillText('\\uf015',5,35);
                  return c.toDataURL();
                }
                return render(family) !== render('monospace');
                """, arguments: ["family": icons.fontFamily!], in: nil, contentWorld: .page) as? Bool
            try require(glyphsAvailable == true, "Installed Nerd Font glyphs must render in WebKit rather than missing-glyph boxes")
            try await snapshot("nerd-font")
            try await send(["type": "import-profile", "id": ""])
            stage("installed Nerd Font glyph rendering passed")
        }
        child?.close(); child?.close()
        try require(docked == 1 && first.webView.superview === deck && pane.process?.processID == originalPID, "Duplicate docking keeps sessions and browser ownership intact")
        first.reload()
        try await waitFor("terminal reattachment") { !first.webView.isLoading && first.webView.url == TerminalSession.address }
        try await Task.sleep(for: .milliseconds(300))
        try require(pane.process?.processID == originalPID && tab.name == "Build" && lower.name == "Log stream", "Reload retains shells, tab names and splits")
        let rendered = try await first.webView.evaluateJavaScript("document.querySelectorAll('.terminal-pane').length") as? Int
        try require(rendered == 4, "Reattached page restores all runtime panes")
        stage("account isolation, tabs, retained views, pop-out and themes passed")

        let rejected = try await first.webView.callAsyncJavaScript("try { await fetch('https://example.com/'); return false; } catch { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try require(rejected == true, "Terminal CSP blocks network requests")
        first.webView.load(URLRequest(url: URL(string: "https://example.com/")!))
        try await Task.sleep(for: .milliseconds(200))
        try require(first.webView.url == TerminalSession.address, "Remote navigation cannot replace the shell page")
        _ = try await first.webView.evaluateJavaScript("window.open('https://example.com/');void 0")
        try require(first.browserViews.count == 1, "Terminal cannot open browser popups")
        let web = BrowserSession(account: Account(id: UUID(), serviceID: "fixture", name: "Web"), service: Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test/")!, glyph: "F", hosts: ["relay.test"]), downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { web.close() }
        web.webView.loadHTMLString("<html><body>web</body></html>", baseURL: web.service.url)
        try await waitFor("unprivileged web page") { !web.webView.isLoading && web.webView.url != nil }
        let exposed = try await web.webView.evaluateJavaScript("!!window.webkit?.messageHandlers?.relayTerminal") as? Bool
        try require(exposed == false, "Web services have no terminal bridge")

        let rightPID = right.process!.processID
        try await send(["type": "close-pane", "pane": right.id])
        try await send(["type": "pane-ready", "pane": right.id])
        try await send(["type": "close-pane", "pane": right.id])
        try require(tab.panes.count == 2 && kill(rightPID, 0) == -1 && errno == ESRCH, "Closing a pane ends its PTY and stale messages cannot resurrect it")
        let tabPID = otherPane.process!.processID
        try await send(["type": "close-tab", "tab": otherTab.id])
        try require(workspace.tabs.count == 1 && kill(tabPID, 0) == -1 && errno == ESRCH, "Closing a tab only ends that tab's shells")
        try await send(["type": "focus", "pane": pane.id])
        try await input("yes RELAY_FLOOD | head -c 600000; printf '\\n%s%s\\n' FLOOD_ DONE\r", pane: pane)
        try await waitFor("bounded output flood") { history(pane).contains("FLOOD_DONE") }
        try require(pane.history.count <= 262_144, "Output history remains bounded under sustained output")
        try await input("sleep 300 & printf '\\nCHILD_%s\\n' $!\r", pane: pane)
        try await waitFor("background child") { history(pane).range(of: "CHILD_[0-9]+", options: .regularExpression) != nil }
        let childRange = history(pane).range(of: "CHILD_[0-9]+", options: .regularExpression)!
        let childPID = Int32(history(pane)[childRange].dropFirst(6))!
        first.close(); first.close()
        try require(kill(originalPID, 0) == -1 && errno == ESRCH, "Unload reaps the shell")
        try await waitFor("background child teardown") { kill(childPID, 0) == -1 && errno == ESRCH }
        try require(workspace.tabs.isEmpty && second.terminal?.workspace.tabs.count == 1, "Unload clears only its account")
        stage("navigation security, stale events and descendant teardown passed")
        let remainingPID = foreign.process!.processID
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        try require(second.terminal?.workspace.tabs.isEmpty == true && kill(remainingPID, 0) == -1 && errno == ESRCH,
                    "Application termination closes and reaps retained terminal sessions")
        print("PASS: embedded terminal PTY input/output/resize, native keys, tabs/splits/rename, isolation, retention, security, themes and teardown")
    }
}
