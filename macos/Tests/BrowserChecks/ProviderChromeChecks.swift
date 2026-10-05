import AppKit
import WebKit

extension BrowserChecks {
    // Exercise the exact HTML used by Windows smoke checks in WebKit too.
    static func providerFixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("windows/Tests/RelayChecks/FixFixtures.cs"), encoding: .utf8)
        return source.components(separatedBy: "private const string \(name) = \"\"\"")[1].components(separatedBy: "\"\"\";")[0]
    }

    @MainActor static func providerChromeChecks() async throws {
        let window = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 900),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let messenger = Service(id: "messenger", name: "Messenger", url: URL(string: "https://www.facebook.com/messages/nested")!, glyph: "M", hosts: ["facebook.com"])
        let session = BrowserSession(account: Account(id: UUID(), serviceID: messenger.id, name: "Layout fixture"), service: messenger,
                                     downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { session.close() }
        window.contentView = session.contentView
        window.orderBack(nil)
        session.webView.loadHTMLString(try providerFixture("NestedMessengerFixture"), baseURL: messenger.url)
        try await waitFor("Messenger layout fixture") { !session.webView.isLoading && session.webView.url != nil }
        let fits = """
            (()=>{const root=document.documentElement,nav=document.querySelector('nav'),thread=document.querySelector('.thread');
            return getComputedStyle(root).overflowY==='hidden' && getComputedStyle(document.body).overflowY==='hidden' &&
              document.scrollingElement.scrollHeight<=innerHeight+1 &&
              Math.abs(nav.getBoundingClientRect().bottom-innerHeight)<2 &&
              Math.abs(thread.getBoundingClientRect().bottom-(innerHeight-16))<2 &&
              document.getElementById('composer').getBoundingClientRect().bottom<=innerHeight;})()
            """
        for (width, height, zoom) in [(1000.0, 900.0, 1.0), (1100, 1280, 0.8), (700, 500, 1.25)] {
            window.setContentSize(NSSize(width: width, height: height))
            session.setZoom(zoom)
            try await Task.sleep(for: .milliseconds(350))
            let result = try await session.webView.evaluateJavaScript(fits) as? Bool
            try require(result == true, "Messenger has an outer scrollbar or clipped composer at \(width)x\(height), zoom \(zoom)")
        }
        for change in ["document.querySelector('.layout').classList.add('cached')",
                       "document.querySelector('.thread').style.marginTop='32px';document.querySelector('.thread').style.height='calc(100vh - 104px)'"] {
            _ = try await session.webView.evaluateJavaScript(change)
            try await Task.sleep(for: .milliseconds(250))
            let result = try await session.webView.evaluateJavaScript(fits) as? Bool
            try require(result == true, "Reused Messenger panes lost their viewport bounds")
        }
        _ = try await session.webView.evaluateJavaScript("(()=>{const style=document.querySelector('.thread').style;style.boxSizing='content-box';style.paddingBottom='12px';style.borderBottom='1px solid gray';})()")
        try await Task.sleep(for: .milliseconds(250))
        let padded = try await session.webView.evaluateJavaScript("document.querySelector('.thread').getBoundingClientRect().bottom<=innerHeight && document.getElementById('composer').getBoundingClientRect().bottom<=innerHeight") as? Bool
        try require(padded == true, "Messenger content-box padding pushed the chat or composer outside the viewport")
        _ = try await session.webView.evaluateJavaScript("document.querySelector('nav').scrollTop=300;document.getElementById('messages').scrollTop=420;window.__relayMessengerChrome.refresh();window.__relayMessengerChrome.refresh()")
        try await Task.sleep(for: .milliseconds(250))
        let retained = try await session.webView.evaluateJavaScript("document.querySelector('nav').scrollTop===300 && document.getElementById('messages').scrollTop===420 && document.getElementById('draft').value==='Unsent'") as? Bool
        try require(retained == true, "Messenger trimming lost independent chat scrolling or a draft")
        _ = try await session.webView.evaluateJavaScript("history.pushState({},'', '/settings/')")
        try await Task.sleep(for: .milliseconds(250))
        let restored = try await session.webView.evaluateJavaScript("getComputedStyle(document.documentElement).overflowY==='scroll' && document.body.style.overflowY==='' && getComputedStyle(document.querySelector('[role=banner]')).display!=='none' && document.querySelector('.thread').style.boxSizing==='content-box' && Math.abs(document.querySelector('.thread').getBoundingClientRect().bottom-(innerHeight-3))<2") as? Bool
        try require(restored == true, "Leaving Messenger did not restore the site's scrolling and header")
        print("Passed: Messenger viewport, zoom, resize, reused panes, independent scrolling, drafts, and route restoration")

        let whatsapp = Service(id: "whatsapp", name: "WhatsApp", url: URL(string: "https://web.whatsapp.com/")!, glyph: "W", hosts: ["web.whatsapp.com"])
        let chat = BrowserSession(account: Account(id: UUID(), serviceID: whatsapp.id, name: "Theme fixture"), service: whatsapp,
                                  downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false)
        defer { chat.close() }
        window.contentView = chat.contentView
        chat.webView.loadHTMLString(try providerFixture("WhatsAppChromeFixture"), baseURL: whatsapp.url)
        try await waitFor("WhatsApp theme fixture") { !chat.webView.isLoading && chat.webView.url != nil }
        for dark in [true, false, true] {
            // The website's explicit choice must win over the host appearance.
            chat.webView.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = try await chat.webView.evaluateJavaScript("document.body.className='\(dark ? "dark" : "light")';document.querySelector('nav').scrollTop=300")
            try await Task.sleep(for: .milliseconds(250))
            let result = try await chat.webView.evaluateJavaScript("getComputedStyle(document.documentElement).colorScheme==='\(dark ? "dark" : "light")' && getComputedStyle(document.querySelector('nav')).colorScheme==='\(dark ? "dark" : "light")' && document.querySelector('nav').scrollTop===300 && document.getElementById('draft').value==='Unsent'") as? Bool
            try require(result == true, "WhatsApp native scrollbars did not follow the site's theme or retained scroll/draft changed")
            if CommandLine.arguments.contains("--snapshots") {
                let snapshot = try await chat.webView.takeSnapshot(configuration: nil)
                let data = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                try data.write(to: root.appendingPathComponent(".build/whatsapp-\(dark ? "dark" : "light").png"))
            }
        }
        _ = try await chat.webView.evaluateJavaScript(WhatsAppChrome.script)
        _ = try await chat.webView.evaluateJavaScript(WhatsAppChrome.script)
        try await Task.sleep(for: .milliseconds(250))
        let duplicate = try await chat.webView.evaluateJavaScript("getComputedStyle(document.documentElement).colorScheme==='dark' && document.querySelector('nav').scrollTop===300") as? Bool
        try require(duplicate == true, "Duplicate WhatsApp integration changed the theme or scroll position")
        chat.webView.loadHTMLString(try providerFixture("WhatsAppChromeFixture"), baseURL: URL(string: "https://web.whatsapp.com.evil.test/")!)
        try await waitFor("WhatsApp unrelated origin fixture") { !chat.webView.isLoading && chat.webView.url?.host == "web.whatsapp.com.evil.test" }
        try await Task.sleep(for: .milliseconds(250))
        let unrelated = try await chat.webView.evaluateJavaScript("document.documentElement.style.colorScheme==='' && !window.__relayWhatsAppChrome") as? Bool
        try require(unrelated == true, "WhatsApp theme integration changed an unrelated origin")
        print("Passed: WhatsApp dark/light theme changes under strict style CSP, native scrollbar scheme, retained scrolling and draft")
    }
}
