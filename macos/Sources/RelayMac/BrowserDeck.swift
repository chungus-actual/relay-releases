import SwiftUI
import AppKit

// Retain loaded browsers in one native hierarchy, as the Windows WebHost does.
// Switching services changes visibility, not the browser's window or viewport.
@MainActor
final class BrowserDeckView: NSView {
    private(set) weak var selectedView: NSView?
    var onActivation: (() -> Void)?
    private var browsers: [NSView] = []

    func update(views: [NSView], selected: NSView?) {
        browsers = views
        // SwiftUI may update the outgoing representable during a layout change.
        // A detached host must not reclaim browsers from the incoming host.
        guard window != nil else { selectedView = selected; return }
        let changed = selectedView !== selected
        selectedView = selected
        for child in subviews where !views.contains(where: { $0 === child }) {
            child.removeFromSuperview()
        }
        for view in views {
            if view.superview !== self {
                view.isHidden = true
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            let hidden = view !== selected
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        // AppKit's native drag destination search can still find a retained
        // WebKit child behind a hidden browser. Keep the selected browser above
        // inactive siblings without detaching any view from its window.
        if let selected, subviews.last !== selected {
            sortSubviews({ first, second, _ in
                if first.isHidden == second.isHidden { return .orderedSame }
                return first.isHidden ? .orderedAscending : .orderedDescending
            }, context: nil)
        }
        if changed {
            needsLayout = true
            layoutSubtreeIfNeeded()
            selected?.needsDisplay = true
            if window != nil { onActivation?() }
        }
    }

    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            update(views: browsers, selected: selectedView)
            onActivation?()
        }
    }
}

struct BrowserDeck: NSViewRepresentable {
    let sessions: [BrowserSession]
    let selected: BrowserSession?
    let dark: Bool

    func makeNSView(context: Context) -> BrowserDeckView { BrowserDeckView() }
    func updateNSView(_ view: BrowserDeckView, context: Context) {
        view.onActivation = { [weak selected] in
            Task { @MainActor [weak selected] in
                guard let selected, !selected.contentView.isHiddenOrHasHiddenAncestor else { return }
                await selected.becameVisible()
                await selected.refreshUnread()
            }
        }
        view.update(views: sessions.map(\.contentView), selected: selected?.contentView)
        for session in sessions {
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if session.contentView.appearance?.name != name { session.contentView.appearance = NSAppearance(named: name) }
        }
    }
}
