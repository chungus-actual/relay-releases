import SwiftUI

struct RelayMenuBar: View {
    @ObservedObject var store: RelayStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Relay") { showWindow() }
        Button("Activity") { store.showLocal("activity"); showWindow() }
        Divider()
        ForEach(store.shortcutAccounts) { account in
            Button(account.name) { store.select(account); showWindow() }
        }
        Divider()
        Button("Downloads") { store.downloads.isOpen = true; showWindow() }
        Button("Settings…") { store.showLocal("settings"); showWindow() }
        Divider()
        Button("Quit Relay") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
