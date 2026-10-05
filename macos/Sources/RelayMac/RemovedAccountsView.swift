import SwiftUI

struct RemovedAccountsView: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    @ViewState private var deleting: RemovedAccount?
    var body: some View {
        if let entries = store.preferences.removedAccounts, !entries.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Removed accounts").font(.system(size: 15, weight: .semibold))
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        ServiceIcon(id: entry.account.serviceID, size: 22).foregroundStyle(theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.account.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(store.services.first { $0.id == entry.account.serviceID }?.name ?? entry.account.serviceID)
                                .font(.system(size: 11)).foregroundStyle(theme.muted)
                            if entry.deletionPending == true {
                                Text("Deletion unfinished — retry to finish.").font(.system(size: 11)).foregroundStyle(theme.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        Button { store.restore(entry) } label: {
                            Text("Restore").padding(.horizontal, 14).padding(.vertical, 8)
                        }
                            .buttonStyle(ShellButtonStyle(theme: theme, bordered: true))
                            .disabled(entry.deletionPending == true || store.erasingProfile != nil || !store.services.contains { $0.id == entry.account.serviceID })
                            .accessibilityLabel("Restore \(entry.account.name)")
                        if store.erasingProfile == entry.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { deleting = entry } label: {
                                Image(systemName: "trash").frame(width: 28, height: 28)
                            }.buttonStyle(ShellButtonStyle(theme: theme))
                                .disabled(store.erasingProfile != nil)
                                .help("Delete saved website data…")
                                .accessibilityLabel("Delete saved data for \(entry.account.name)")
                        }
                    }.padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20).shellCard(theme)
            .confirmationDialog("Delete saved website data?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
                    Button("Delete Saved Data", role: .destructive) { Task { await store.eraseProfile(entry) } }
                    Button("Cancel", role: .cancel) {}
                } message: { entry in
                    Text("Permanently delete saved logins and website data for \(entry.account.name) on this Mac? This cannot be undone.")
                }
        }
    }
}
