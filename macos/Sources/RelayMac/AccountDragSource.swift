import SwiftUI
import AppKit

// AppKit owns the pointer sequence so SwiftUI Button tracking cannot swallow it.
struct AccountDragSource: NSViewRepresentable {
    let payload: String
    let serviceID: String
    let activate: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.payload = payload
        view.serviceID = serviceID
        view.activate = activate
    }

    class DragView: NSView, NSDraggingSource {
        var payload = ""
        var serviceID = ""
        var activate: () -> Void = {}
        private var start: NSPoint?
        private var dragging = false
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Leave context menus and control-clicks with the SwiftUI button.
            if let event = NSApp.currentEvent,
               event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            dragging = false
        }
        override func mouseUp(with event: NSEvent) {
            if start != nil && !dragging && bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
            start = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
            dragging = true
            let item = NSDraggingItem(pasteboardWriter: payload as NSString)
            let icon = Bundle.main.url(forResource: serviceID, withExtension: "svg", subdirectory: "ServiceIcons")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
            let size = NSSize(width: 40, height: 40)
            let preview = NSImage(size: size, flipped: false) { rect in
                icon?.draw(in: rect.insetBy(dx: 9, dy: 9))
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            let point = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 20, y: point.y - 20, width: size.width, height: size.height), contents: preview)
            beginAccountDrag(item, event: event)
        }
        func beginAccountDrag(_ item: NSDraggingItem, event: NSEvent) {
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            start = nil
            dragging = false
        }
    }
}
