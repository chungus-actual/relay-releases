import SwiftUI
import UniformTypeIdentifiers

private struct AccountDropTarget: ViewModifier {
    @ObservedObject var store: RelayStore
    let account: Account
    let horizontal: Bool
    let theme: ShellTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var targeted = false
    @ViewState private var after = false
    @ViewState private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { size = geometry.size }
                        .onChange(of: geometry.size) { _, value in size = value }
                }
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 2).fill(theme.accent)
                        .frame(width: horizontal ? 3 : nil, height: horizontal ? nil : 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: horizontal ? (after ? .trailing : .leading) : (after ? .bottom : .top))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.text], delegate: AccountDropDelegate(
                store: store, account: account, horizontal: horizontal, size: size,
                targeted: $targeted, after: $after, reduceMotion: reduceMotion))
            .padding(horizontal ? .horizontal : .vertical, targeted ? 5 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: targeted)
    }
}

private struct AccountDropDelegate: DropDelegate {
    let store: RelayStore
    let account: Account
    let horizontal: Bool
    let size: CGSize
    @Binding var targeted: Bool
    @Binding var after: Bool
    let reduceMotion: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [UTType.text]).count == 1
    }
    func dropEntered(info: DropInfo) { updatePosition(info); targeted = true }
    private func updatePosition(_ info: DropInfo) {
        after = horizontal ? info.location.x >= size.width / 2 : info.location.y >= size.height / 2
    }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePosition(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let providers = info.itemProviders(for: [UTType.text])
        guard providers.count == 1, let provider = providers.first,
              provider.canLoadObject(ofClass: NSString.self) else { return false }
        let after = horizontal ? info.location.x >= size.width / 2 : info.location.y >= size.height / 2
        _ = provider.loadObject(ofClass: NSString.self) { value, error in
            guard error == nil, let payload = value as? String else { return }
            Task { @MainActor in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    _ = store.reorder([payload], relativeTo: account, after: after)
                }
            }
        }
        return true
    }
}

extension View {
    func accountDropTarget(store: RelayStore, account: Account, horizontal: Bool = false,
                           theme: ShellTheme) -> some View {
        modifier(AccountDropTarget(store: store, account: account, horizontal: horizontal, theme: theme))
    }
}
