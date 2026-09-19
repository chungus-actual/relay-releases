import AppKit
import SwiftUI

@main
struct ControlChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            for mode in ["Dark", "Light"] {
                var clicks = 0
                let theme = ShellTheme(settings: AppearancePreferences(mode: mode), system: .dark)
                let host = NSHostingView(rootView: AddAccountButton(theme: theme) { clicks += 1 }
                    .frame(width: 188, height: 80))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 188, height: 80),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                // Real AppKit mouse events, confined to this offscreen fixture window.
                // The visible button occupies x=20...168, y=20...60.
                for (index, x) in [24.0, 94.0, 164.0].enumerated() {
                    let point = host.convert(NSPoint(x: x, y: 40), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        app.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard clicks == index + 1 else {
                        fputs("FAIL: \(mode) Add account click at x=\(x) produced \(clicks) actions\n", stderr)
                        exit(1)
                    }
                }
                window.close()
            }
            print("PASS: Add account left, center, and right clicks activate exactly once in dark and light themes")
            exit(0)
        }
        app.run()
    }
}
