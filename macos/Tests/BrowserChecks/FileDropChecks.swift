import AppKit
import WebKit

@MainActor private final class NativeFileDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint(x: 200, y: 200)
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("relay-native-drop-\(UUID())"))
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { [] }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

// Invoke AppKit's native drag destination callbacks, as WebKit's own tests do.
// No CGEvents, pointer movement, focus changes, signed-in accounts, or uploads.
extension BrowserChecks {
    @MainActor static func nativeFileDropChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-native-drop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads: [(String, Data)] = [
            ("Image attachment.png", Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwODDhPwAFJAKA/duKTwAAAABJRU5ErkJggg==")!),
            ("Résumé notes.txt", Data("relay attachment bytes".utf8))
        ]
        let files = try payloads.map { name, bytes in
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }
        let service = Service(id: "fixture", name: "Fixture", url: URL(string: "https://relay.test/")!, glyph: "F", hosts: ["relay.test"])
        let sessions = (0..<2).map { BrowserSession(account: Account(id: UUID(), serviceID: service.id, name: "Drop \($0)"), service: service, downloads: DownloadCenter(), dataStore: .nonPersistent(), loadImmediately: false) }
        let window = NSWindow(contentRect: NSRect(x: -1200, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var host = BrowserDeckView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = host
        window.orderBack(nil)
        defer { sessions.forEach { $0.close() }; window.close() }
        let views = sessions.map(\.webView)
        host.update(views: views, selected: views[0])
        for view in views {
            view.loadHTMLString("""
            <body style='height:100vh'><input id='draft' value='Unsent'><script>
            window.token = Math.random(); window.originalToken = token;
            window.results = []; window.failures = []; window.drops = 0;
            for (const type of ['dragenter','dragover','drop']) document.addEventListener(type, async e => {
              e.preventDefault();
              if (type !== 'drop') return;
              drops++;
              try {
                const files = Array.from(e.dataTransfer.files);
                for (const file of files) results.push({name:file.name, bytes:Array.from(new Uint8Array(await file.arrayBuffer())), trusted:e.isTrusted});
              } catch(error) { failures.push(String(error)); }
            });
            </script>
            """, baseURL: service.url)
            try await waitFor("native drop fixture") { !view.isLoading && view.url != nil }
        }
        var expectedDrops = [0, 0]
        for pass in 0..<8 {
            let selection = pass % 2
            if pass == 3 { host.update(views: views, selected: nil) }
            if pass == 4 {
                let outgoing = host
                host = BrowserDeckView(frame: outgoing.bounds)
                host.update(views: views, selected: views[selection])
                window.contentView = host
                outgoing.update(views: views, selected: views[1-selection])
                try require(views.allSatisfy { $0.window === window && $0.superview === host },
                            "An outgoing host reclaimed the native file-drop destination")
            }
            host.update(views: views, selected: views[selection])
            window.contentView?.layoutSubtreeIfNeeded()
            let view = views[selection]
            var hit = host.hitTest(NSPoint(x: 200, y: 200))
            while hit != nil && !(hit is WKWebView) { hit = hit?.superview }
            try require(hit === view, "Native hit testing must resolve to the selected browser")
            let info = NativeFileDragInfo()
            info.draggingDestinationWindow = window
            info.draggingSequenceNumber = pass + 1
            info.numberOfValidItemsForDrop = files.count
            // Cover both modern file URLs and the legacy Finder filenames flavor.
            if pass % 2 == 0 { info.draggingPasteboard.writeObjects(files.map { $0 as NSURL }) }
            else { info.draggingPasteboard.setPropertyList(files.map(\.path), forType: .init("NSFilenamesPboardType")) }
            defer { info.draggingPasteboard.releaseGlobally() }
            _ = view.draggingEntered(info)
            var operation: NSDragOperation = []
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                operation = view.draggingUpdated(info)
            }
            try require(operation.contains(.copy), "Page did not accept the native file drag")
            if pass == 6 { view.draggingExited(info) }
            else {
                try require(view.prepareForDragOperation(info), "WebKit declined the prepared file drop")
                try require(view.performDragOperation(info), "WebKit declined the native file drop")
                expectedDrops[selection] += 1
            }
            try await Task.sleep(for: .milliseconds(300))
            for (index, browser) in views.enumerated() {
                let report = try await browser.evaluateJavaScript("({drops,results,failures,intact:token===originalToken && document.getElementById('draft').value==='Unsent'})") as? [String: Any]
                guard let report, let results = report["results"] as? [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
                try require(report["drops"] as? Int == expectedDrops[index] && results.count == expectedDrops[index] * files.count,
                            "Missing, duplicate, cancelled, or background drop on pass \(pass): page \(index)")
                try require(report["intact"] as? Bool == true && (report["failures"] as? [String])?.isEmpty == true,
                            "Drop lost document/draft or file access")
                for result in results {
                    let expected = payloads.first { $0.0 == result["name"] as? String }
                    try require(expected != nil && (result["bytes"] as? [UInt8]).map(Data.init) == expected?.1 && result["trusted"] as? Bool == true,
                                "Dropped file name, bytes, or native event trust differ")
                }
            }
        }
        print("Passed: native PNG/multiple-file delivery, file URL/legacy flavors, service/host switching, cancellation, duplicate/background exclusion, and draft retention (no pointer automation)")
    }
}
