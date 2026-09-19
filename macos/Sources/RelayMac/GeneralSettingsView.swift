import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var loginStatus = SMAppService.Status.notRegistered
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General").font(.system(size: 15, weight: .semibold))
            Toggle("Capture links", isOn: $store.captureLinks).toggleStyle(.checkbox)
            Toggle("Keep running when window closes", isOn: $store.closeToMenuBar).toggleStyle(.checkbox)
            Toggle("Show Relay in the menu bar", isOn: $store.menuBarEnabled).toggleStyle(.checkbox)
            Toggle("Open Relay at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { enabled in Task { await updateLogin(enabled) } }))
                .toggleStyle(.checkbox).disabled(busy)
            if loginStatus == .requiresApproval {
                Text("Approve Relay in Login Items to finish enabling startup.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(theme.muted) }
        }
        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(20).shellCard(theme)
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }
    private func refresh() {
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot-directory") else { return }
        let status = SMAppService.mainApp.status
        if loginStatus != status { loginStatus = status }
    }
    @MainActor private func updateLogin(_ enabled: Bool) async {
        guard !busy, !ProcessInfo.processInfo.arguments.contains("--snapshot-directory") else { return }
        busy = true
        error = nil
        defer { busy = false; refresh() }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try await SMAppService.mainApp.unregister()
            }
        } catch { self.error = "Could not update login startup: \(error.localizedDescription)" }
    }
}
