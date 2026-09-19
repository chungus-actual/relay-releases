import SwiftUI

// Render only Relay's own view tree; no screen capture or real account data is used.
@MainActor
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    var closeToMenuBar: (() -> Bool)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(closeToMenuBar?() ?? true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIdentity.icon
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-directory"), arguments.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let cases: [(String, String, String, Bool, Bool, CGFloat)] = [
                    ("activity-dark", "activity", "Dark", false, false, 1180),
                    ("settings-dark", "settings", "Dark", false, false, 1180),
                    ("activity-light", "activity", "Light", false, false, 1180),
                    ("settings-narrow", "settings", "Dark", true, false, 720),
                    ("activity-top-tabs", "activity", "Dark", false, true, 1180),
                    ("downloads-wide", "activity", "Dark", false, false, 1180),
                    ("downloads-narrow", "activity", "Dark", true, false, 720),
                    ("unread-activity", "activity", "Dark", false, false, 1180),
                    ("unread-top-tabs", "activity", "Light", true, true, 720),
                    ("media-narrow", "service", "Dark", true, true, 720),
                    ("media-wide", "activity", "Light", false, false, 1180)
                ]
                for (name, page, mode, compact, top, width) in cases {
                    let mediaPreview = name.hasPrefix("media") ? ActiveMedia(accountID: UUID(), reading: MediaReading(value: [
                        "playing": true, "available": true, "previous": true, "next": true,
                        "title": "A long track title to check the compact caption", "artist": "Fixture artist"
                    ])!) : nil
                    let store = RelayStore(mediaPreview: mediaPreview)
                    store.localPage = page
                    if page == "service" { store.preferences.selected = store.preferences.accounts.first { $0.serviceID == "spotify" }?.id }
                    store.appearance = AppearancePreferences(mode: mode, compact: compact, topTabs: top)
                    if name.hasPrefix("downloads") {
                        let item = DownloadItem(account: store.preferences.accounts[0])
                        item.name = "Weekend plans.pdf"
                        item.status = .downloading
                        item.received = 1_400_000
                        item.total = 3_000_000
                        store.downloads.items = [item]
                        store.downloads.isOpen = true
                    }
                    if name.hasPrefix("unread") {
                        let accounts = store.preferences.accounts
                        store.unread.receive(UnreadReading(count: 3, attention: false, key: "fixture:3"), for: accounts[1].id)
                        store.unread.receive(UnreadReading(count: nil, attention: true, key: "fixture:dot"), for: accounts[0].id)
                        store.unread.receive(UnreadReading(count: 128, attention: false, key: "fixture:128"), for: accounts[3].id)
                    }
                    if name == "settings-narrow" {
                        let id = store.preferences.accounts[0].id
                        try store.preferences.renameAccount(id, to: "Personal Messenger account with a longer label")
                        store.preferences.setVisible(id, false)
                    }
                    let view = NSHostingView(rootView: ContentView(store: store))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    window.orderFront(nil)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                    window.close()
                }
                print("Rendered eleven shell snapshots to \(directory.path)")
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}
