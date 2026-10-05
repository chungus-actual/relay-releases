import SwiftUI

struct WorkspaceLayoutPicker: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    let compact: Bool
    let horizontal: Bool
    @ViewState private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            LayoutRailGlyph().stroke(presented ? theme.accent : theme.muted, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .frame(width: compact ? 16 : 19, height: compact ? 16 : 19)
                .frame(width: compact ? 30 : 46, height: compact ? 32 : 38)
        }
        .buttonStyle(ShellButtonStyle(theme: theme, selected: presented))
        .help("Layout").accessibilityLabel("Layout")
        .contextMenu { Button("Hide Layout button") { presented = false; store.setLayoutButtonHidden(true) } }
        .popover(isPresented: $presented, arrowEdge: horizontal ? .top : .leading) { picker }
        .onChange(of: horizontal) { _, _ in presented = false }
        .onChange(of: compact) { _, _ in presented = false }
    }
    private var picker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                LayoutPreviewTile(arrangement: "single", name: "Single pane", accounts: store.paneAccounts,
                                  selected: store.preferences.selected, active: store.workspace.panes.count == 1, theme: theme) {
                    if let account = store.paneAccounts.first(where: { $0.id == store.preferences.selected }) ?? store.paneAccounts.first {
                        presented = false; store.soloPane(account)
                    }
                }.disabled(store.paneAccounts.isEmpty)
                ForEach(Array(WorkspaceLayout.arrangements.enumerated()), id: \.element) { index, arrangement in
                    LayoutPreviewTile(arrangement: arrangement, name: WorkspaceLayout.labels[index], accounts: store.paneAccounts,
                                      selected: store.preferences.selected, active: store.workspace.panes.count > 1 && store.workspace.arrangement == arrangement, theme: theme) {
                        presented = false; store.arrangePanes(arrangement)
                    }.disabled(store.workspace.panes.count < 2)
                }
            }
            HStack(spacing: 4) {
                ForEach(store.paneAccounts) { account in
                    Button { store.select(account) } label: {
                        ServiceIcon(id: account.serviceID, size: 16)
                            .foregroundStyle(store.preferences.selected == account.id ? theme.accent : theme.muted)
                            .frame(width: 30, height: 28)
                    }.buttonStyle(ShellButtonStyle(theme: theme, selected: store.preferences.selected == account.id))
                        .help(account.name).accessibilityLabel(account.name)
                }
                Menu {
                    ForEach(store.preferences.accounts.filter { !store.workspace.panes.contains($0.id) }) { account in
                        Button(account.name) { presented = false; store.addPane(account) }
                    }
                } label: {
                    Image(systemName: "plus").foregroundStyle(theme.muted).frame(width: 30, height: 28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(store.workspace.panes.count >= 4).help("Add pane").accessibilityLabel("Add pane")
                Rectangle().fill(theme.line).frame(width: 1, height: 18).padding(.horizontal, 8)
                focusedPaneControls
                Spacer(minLength: 0)
                Button { presented = false; store.resetPaneSizes() } label: {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(theme.muted).frame(width: 30, height: 28)
                }.buttonStyle(ShellButtonStyle(theme: theme)).disabled(store.workspace.panes.count < 2)
                    .help("Reset pane sizes").accessibilityLabel("Reset pane sizes")
            }.padding(.horizontal, 5)
            HStack {
                Button("Save workspace…") { presented = false; store.editWorkspace() }
                Menu("Saved workspaces") {
                    ForEach(store.preferences.savedWorkspaces ?? []) { saved in Button(saved.name) { presented = false; store.openWorkspace(saved) } }
                    Divider()
                    Button("Manage workspaces & bookmarks…") { presented = false; store.showLocal("library") }
                }
                Spacer()
            }.padding(.horizontal, 5)
        }.padding(10).background(theme.panel).fixedSize()
            .preferredColorScheme(theme.dark ? .dark : .light)
    }
    private var focusedAccount: Account? {
        guard store.localPage == "service" else { return nil }
        return store.paneAccounts.first { $0.id == store.preferences.selected }
    }
    private var focusedPaneControls: some View {
        HStack(spacing: 4) {
            Menu {
                if let account = focusedAccount {
                    ForEach(store.preferences.accounts.filter { $0.id == account.id || !store.workspace.panes.contains($0.id) }) { replacement in
                        Button(replacement.name) { presented = false; store.select(replacement) }
                    }
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(theme.muted).frame(width: 30, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Change pane service").accessibilityLabel("Change pane service")
            paneAction("Move pane earlier", "arrow.left") {
                if let account = focusedAccount { presented = false; store.movePane(account, by: -1) }
            }.disabled(focusedAccount?.id == store.workspace.panes.first)
            paneAction("Move pane later", "arrow.right") {
                if let account = focusedAccount { presented = false; store.movePane(account, by: 1) }
            }.disabled(focusedAccount?.id == store.workspace.panes.last)
            paneAction("Only this pane", "arrow.up.left.and.arrow.down.right") {
                if let account = focusedAccount { presented = false; store.soloPane(account) }
            }.disabled(store.paneAccounts.count < 2)
            paneAction("Close pane", "xmark") {
                if let account = focusedAccount { presented = false; store.closePane(account) }
            }
        }.disabled(focusedAccount == nil)
    }
    private func paneAction(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(theme.muted).frame(width: 30, height: 28)
        }.buttonStyle(ShellButtonStyle(theme: theme)).help(name).accessibilityLabel(name)
    }

}

private struct LayoutPreviewTile: View {
    let arrangement: String
    let name: String
    let accounts: [Account]
    let selected: UUID?
    let active: Bool
    let theme: ShellTheme
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovered = false
    private static let placeholders = (0..<4).map { _ in UUID() }
    private var preview: WorkspaceLayout {
        let count = arrangement == "single" ? 1 : accounts.count > 1 ? accounts.count : arrangement == "grid" ? 4 : arrangement.hasPrefix("main-") ? 3 : 2
        var layout = WorkspaceLayout(panes: Array(Self.placeholders.prefix(count)), arrangement: arrangement == "single" ? "grid" : arrangement,
                                     primary: arrangement.hasPrefix("main-") ? 0.6 : 0.5)
        layout.normalizeSizes(); return layout
    }
    private func account(_ index: Int) -> Account? {
        if arrangement == "single" { return accounts.first { $0.id == selected } ?? accounts.first }
        return accounts.indices.contains(index) ? accounts[index] : nil
    }
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<preview.panes.count, id: \.self) { index in
                    let cell = preview.cell(index)
                    let cellWidth = CGFloat(cell.width * 76)
                    let cellHeight = CGFloat(cell.height * 58)
                    let shortestSide = min(cellWidth, cellHeight)
                    let iconSize = max(CGFloat(6), min(CGFloat(12), shortestSide - 9))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(active ? theme.accent.opacity(0.10) : theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(active ? theme.accent : theme.muted.opacity(0.65), lineWidth: 1))
                        .overlay {
                            if let account = account(index), shortestSide - 3 >= 16 {
                                ServiceIcon(id: account.serviceID, size: iconSize)
                                    .foregroundStyle(active ? theme.accent : theme.muted)
                            }
                        }
                        .frame(width: max(0, cellWidth - 3), height: max(0, cellHeight - 3))
                        .offset(x: cell.x * 76 + 1.5, y: cell.y * 58 + 1.5)
                }
            }.frame(width: 76, height: 58)
                .scaleEffect(hovered && enabled ? 1.04 : 1)
                .frame(width: 92, height: 74)
                .background(active ? theme.accent.opacity(0.10) : hovered && enabled ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? theme.accent : .clear, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .help(name).accessibilityLabel(name).accessibilityValue(active ? "Selected" : "")
    }
}

private struct LayoutRailGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: 2, y: 3, width: 20, height: 18), cornerRadius: 2)
        path.move(to: CGPoint(x: 13, y: 3)); path.addLine(to: CGPoint(x: 13, y: 21))
        path.move(to: CGPoint(x: 13, y: 12)); path.addLine(to: CGPoint(x: 22, y: 12))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
