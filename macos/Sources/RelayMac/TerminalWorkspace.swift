import Foundation

final class TerminalWorkspace {
    var tabs: [TerminalTab] = []
    var activeTab: String?
    private var nextTab = 1
    var current: TerminalTab? { tabs.first { $0.id == activeTab } }
    @discardableResult func addTab() -> TerminalTab {
        let tab = TerminalTab(name: "Session \(nextTab)"); nextTab += 1
        tabs.append(tab); activeTab = tab.id; return tab
    }
    func closeTab(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index); tab.close()
        if activeTab == tab.id { activeTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }
    func close() { tabs.forEach { $0.close() }; tabs.removeAll(); activeTab = nil }
    var message: [String: Any] { ["type": "workspace", "activeTab": activeTab as Any? ?? NSNull(), "tabs": tabs.map(\.message)] }
}

final class TerminalTab {
    let id = UUID().uuidString
    var name: String
    var panes: [TerminalPane] = []
    var activePane: String?
    var layout: TerminalSplit?
    var zoomed = false
    private var nextPane = 1
    init(name: String) { self.name = name }
    @discardableResult func addPane(beside: String? = nil, direction: String = "columns") -> TerminalPane? {
        let pane = TerminalPane(name: "Shell \(nextPane)")
        if layout == nil { layout = TerminalSplit(pane: pane.id) }
        else if let leaf = layout?.findPane(beside ?? activePane) {
            leaf.first = TerminalSplit(pane: leaf.pane); leaf.second = TerminalSplit(pane: pane.id)
            leaf.pane = nil; leaf.direction = direction; leaf.ratio = 0.5
        } else { return nil }
        nextPane += 1; panes.append(pane); activePane = pane.id; zoomed = false
        return pane
    }
    func closePane(_ pane: TerminalPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: index); pane.close(); layout = layout?.removing(pane.id)
        if activePane == pane.id { activePane = panes.isEmpty ? nil : panes[min(index, panes.count - 1)].id }
        if panes.count < 2 { zoomed = false }
    }
    func close() { panes.forEach { $0.close() }; panes.removeAll(); layout = nil; activePane = nil }
    var message: [String: Any] {
        ["id": id, "name": name, "activePane": activePane as Any? ?? NSNull(), "zoomed": zoomed,
         "layout": layout?.message as Any? ?? NSNull(), "panes": panes.map { ["id": $0.id, "name": $0.name, "status": $0.status] }]
    }
}
final class TerminalPane {
    let id = UUID().uuidString
    var name: String
    var status = "Starting…"
    var columns = 80, rows = 24
    var process: MacPTY?
    var started = false
    var generation = 0
    var history = Data()
    init(name: String) { self.name = name }
    func remember(_ data: Data) {
        history.append(data)
        if history.count > 262_144 { history.removeFirst(history.count - 262_144) }
    }
    func close() { generation += 1; process?.close(); process = nil; started = false; history.removeAll() }
}
final class TerminalSplit {
    let id = UUID().uuidString
    var pane: String?
    var direction = "columns", ratio = 0.5
    var first: TerminalSplit?, second: TerminalSplit?
    init(pane: String?) { self.pane = pane }
    func findPane(_ id: String?) -> TerminalSplit? {
        if id != nil && pane == id { return self }
        return first?.findPane(id) ?? second?.findPane(id)
    }
    func find(_ id: String?) -> TerminalSplit? { self.id == id ? self : first?.find(id) ?? second?.find(id) }
    func removing(_ id: String) -> TerminalSplit? {
        if let pane { return pane == id ? nil : self }
        first = first?.removing(id); second = second?.removing(id)
        return first == nil ? second : second == nil ? first : self
    }
    var message: [String: Any] {
        ["id": id, "pane": pane as Any? ?? NSNull(), "direction": direction, "ratio": ratio,
         "first": first?.message as Any? ?? NSNull(), "second": second?.message as Any? ?? NSNull()]
    }
}
