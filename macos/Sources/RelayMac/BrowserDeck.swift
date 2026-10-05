import SwiftUI
import AppKit
import QuartzCore

// A single native hierarchy retains every loaded browser across arrangement changes.
@MainActor
final class BrowserDeckView: NSView {
    private(set) weak var selectedView: NSView?
    var onActivation: (() -> Void)?
    var onFocus: ((NSView) -> Void)?
    var onResize: ((Int, Double, Bool) -> Void)?
    private var browsers: [NSView] = []
    private var visibleBrowsers: [NSView] = []
    private var workspace = WorkspaceLayout()
    private var dividers: [PaneDividerView] = []
    private var focusMonitor: Any?
    private var focusDispatch: DispatchWorkItem?
    private var focusGeneration = 0
    private var lastTransition = 0
    private var animateNextLayout = false
    private var targetFrames: [ObjectIdentifier: NSRect] = [:]
    private var pendingResize: (Int, Double)?
    private var resizeDispatch: DispatchWorkItem?
    private var resizeGeneration = 0
    override var isFlipped: Bool { true }

    func update(views: [NSView], selected: NSView?, visible: [NSView]? = nil, layout: WorkspaceLayout? = nil, transition: Int = 0) {
        let visible = visible ?? selected.map { [$0] } ?? []
        if visible.isEmpty || layout.map({ $0.panes != workspace.panes || $0.arrangement != workspace.arrangement }) == true { cancelPendingResize() }
        if visibleBrowsers != visible { cancelPendingFocus() }
        let changed = visibleBrowsers != visible
        animateNextLayout = transition != lastTransition && window != nil && !visibleBrowsers.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastTransition = transition
        browsers = views; visibleBrowsers = visible
        selectedView = selected
        if let layout { workspace = layout }
        else { workspace = WorkspaceLayout(panes: visible.map { _ in UUID() }); workspace.normalizeSizes() }
        // Outgoing SwiftUI hosts must not reclaim views from their replacement.
        guard window != nil else { return }
        for child in subviews where !views.contains(where: { $0 === child }) && !(child is PaneDividerView) { targetFrames.removeValue(forKey: ObjectIdentifier(child)); child.removeFromSuperview() }
        for view in views where !(view.window is RetainedBrowserPanel) {
            if view.superview !== self {
                view.isHidden = true; view.frame = bounds
                targetFrames.removeValue(forKey: ObjectIdentifier(view))
                view.autoresizingMask = []
                addSubview(view)
            }
            view.isHidden = !visible.contains(where: { $0 === view })
        }
        let geometry = visible.count > 1 ? workspace.dividers() : []
        if dividers.count != geometry.count {
            dividers.forEach { targetFrames.removeValue(forKey: ObjectIdentifier($0)); $0.removeFromSuperview() }
            dividers = geometry.map { _ in PaneDividerView() }
            dividers.forEach { addSubview($0) }
        }
        for (view, divider) in zip(dividers, geometry) {
            view.divider = divider
            view.resetPosition = divider.index < 0 ? 0.5 : Double(divider.index + 1) / Double(workspace.cuts.count + 1)
            view.onResize = { [weak self] position, finished in self?.requestResize(divider.index, position: position, finished: finished) }
        }
        sortSubviews({ first, second, _ in
            let a = first is PaneDividerView ? 2 : first.isHidden ? 0 : 1
            let b = second is PaneDividerView ? 2 : second.isHidden ? 0 : 1
            return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        }, context: nil)
        needsLayout = true; layoutSubtreeIfNeeded()
        if changed { visible.forEach { $0.needsDisplay = true }; onActivation?() }
    }

    func restoreFloatingBrowser(_ browser: NSView) {
        addSubview(browser)
        browser.isHidden = !visibleBrowsers.contains(where: { $0 === browser })
        targetFrames.removeValue(forKey: ObjectIdentifier(browser))
        needsLayout = true; layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        if workspace.panes.count <= 1 {
            for view in browsers where !(view.window is RetainedBrowserPanel) && view.isHidden && view.frame != bounds { view.frame = bounds; targetFrames[ObjectIdentifier(view)] = bounds }
        }
        let animated = animateNextLayout
        animateNextLayout = false
        let multi = visibleBrowsers.count > 1
        for (index, view) in visibleBrowsers.enumerated() {
            if view.window is RetainedBrowserPanel { continue }
            let cell = workspace.cell(index), inset = multi ? 3.0 : 0
            let frame = NSRect(x: cell.x * bounds.width + inset, y: cell.y * bounds.height + inset,
                               width: max(0, cell.width * bounds.width - 2 * inset), height: max(0, cell.height * bounds.height - 2 * inset))
            place(view, frame: frame, animated: animated)
        }
        for (view, divider) in zip(dividers, workspace.dividers()) {
            let frame = NSRect(x: divider.vertical ? divider.position * bounds.width - 3 : divider.start * bounds.width,
                                y: divider.vertical ? divider.start * bounds.height : divider.position * bounds.height - 3,
                                width: divider.vertical ? 6 : divider.length * bounds.width,
                                height: divider.vertical ? divider.length * bounds.height : 6)
            place(view, frame: frame, animated: animated)
            window?.invalidateCursorRects(for: view)
        }
    }

    private func place(_ view: NSView, frame: NSRect, animated: Bool) {
        let key = ObjectIdentifier(view)
        guard targetFrames[key] != frame else { return }
        targetFrames[key] = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            view.animator().frame = frame
        }
    }
    private func cancelPendingResize() {
        resizeGeneration &+= 1
        resizeDispatch?.cancel(); resizeDispatch = nil; pendingResize = nil
    }
    private func requestResize(_ index: Int, position: Double, finished: Bool) {
        guard window != nil else { return }
        if finished {
            cancelPendingResize()
            onResize?(index, position, true)
            return
        }
        pendingResize = (index, position)
        guard resizeDispatch == nil else { return }
        let generation = resizeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.resizeDispatch = nil
            guard self.window != nil, let (index, position) = self.pendingResize else { return }
            self.pendingResize = nil
            self.onResize?(index, position, false)
        }
        resizeDispatch = work; DispatchQueue.main.async(execute: work)
    }

    private func cancelPendingFocus() {
        focusGeneration &+= 1; focusDispatch?.cancel(); focusDispatch = nil
    }
    private func requestFocus(_ target: NSView) {
        cancelPendingFocus()
        guard target !== selectedView else { return }
        let generation = focusGeneration
        let work = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.focusGeneration == generation else { return }
            self.focusDispatch = nil
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor, target.superview === self,
                  self.visibleBrowsers.contains(where: { $0 === target }), target !== self.selectedView else { return }
            self.onFocus?(target)
        }
        focusDispatch = work; DispatchQueue.main.async(execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = focusMonitor { NSEvent.removeMonitor(monitor); focusMonitor = nil }
        guard window != nil else { cancelPendingResize(); cancelPendingFocus(); return }
        update(views: browsers, selected: selectedView, visible: visibleBrowsers, layout: workspace, transition: lastTransition)
        onActivation?()
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, !self.isHiddenOrHasHiddenAncestor, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let responder = self.window?.firstResponder as? NSView
            let target = self.visibleBrowsers.first { view in
                event.type != .keyDown ? view.frame.contains(point) : (responder === view || responder?.isDescendant(of: view) == true)
            }
            if let target { self.requestFocus(target) }
            return event
        }
    }
    deinit { focusDispatch?.cancel(); resizeDispatch?.cancel(); if let focusMonitor { NSEvent.removeMonitor(focusMonitor) } }
}

@MainActor
private final class PaneDividerView: NSView {
    var divider = WorkspaceLayout.Divider(index: -1, vertical: true, position: 0.6, start: 0, length: 1)
    var onResize: ((Double, Bool) -> Void)?
    var resetPosition = 0.5
    private var resetOnMouseDown = false
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: divider.vertical ? .resizeLeftRight : .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resetOnMouseDown = event.clickCount == 2
        if resetOnMouseDown { onResize?(resetPosition, true); return }
        resize(event, finished: false)
    }
    override func mouseDragged(with event: NSEvent) { resize(event, finished: false) }
    override func mouseUp(with event: NSEvent) {
        if !resetOnMouseDown { resize(event, finished: true) }
        resetOnMouseDown = false
    }
    private func resize(_ event: NSEvent, finished: Bool) {
        guard let host = superview else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        onResize?(divider.vertical ? point.x / max(1, host.bounds.width) : point.y / max(1, host.bounds.height), finished)
    }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) {
            onResize?(divider.position + ([123, 126].contains(event.keyCode) ? -0.02 : 0.02), true)
        } else { super.keyDown(with: event) }
    }
    override func accessibilityLabel() -> String? { divider.vertical ? "Resize pane widths" : "Resize pane heights" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
}

struct BrowserDeck: NSViewRepresentable {
    let sessions: [BrowserSession]
    let selected: BrowserSession?
    let dark: Bool
    var background: NSColor? = nil
    var foreground: NSColor? = nil
    var accent: NSColor = .controlAccentColor
    var visible: [BrowserSession]? = nil
    var workspace: WorkspaceLayout? = nil
    var transition: Int = 0
    var onFocus: ((BrowserSession) -> Void)? = nil
    var onResize: ((Int, Double, Bool) -> Void)? = nil

    func makeNSView(context: Context) -> BrowserDeckView { BrowserDeckView() }
    func updateNSView(_ view: BrowserDeckView, context: Context) {
        let shown = visible ?? selected.map { [$0] } ?? []
        view.onActivation = {
            Task { @MainActor in
                for session in shown where !session.contentView.isHiddenOrHasHiddenAncestor {
                    await session.becameVisible(); await session.refreshUnread()
                }
            }
        }
        view.onFocus = { browser in if let session = shown.first(where: { $0.contentView === browser }) { onFocus?(session) } }
        view.onResize = onResize
        view.update(views: sessions.map(\.contentView), selected: selected?.contentView,
                    visible: shown.map(\.contentView), layout: workspace, transition: transition)
        for session in sessions {
            session.setNativeAppearance(dark: dark, background: background, foreground: foreground, accent: accent)
        }
    }
}
