import SwiftUI

struct ShellSettings: View {
    @ObservedObject var store: RelayStore
    let theme: ShellTheme
    @ViewState private var addingAccount = false
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Appearance").font(.system(size: 15, weight: .semibold))
                choice("Mode", values: ["System", "Dark", "Light"], key: \.mode)
                choice("Surface", values: ["Graphite", "Ocean", "Dune"], key: \.surface, previews: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent").font(.system(size: 11)).foregroundStyle(theme.muted)
                    HStack(spacing: 7) {
                        ForEach(["Mint", "Sky", "Iris", "Rose", "Amber"], id: \.self) { name in
                            Button { store.appearance.accent = name } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(theme.accent(name)).frame(width: 12, height: 12)
                                    Text(name).font(.system(size: 11))
                                }.padding(.horizontal, 10).padding(.vertical, 8)
                            }.buttonStyle(ShellButtonStyle(theme: theme, selected: store.appearance.accent == name, bordered: true))
                        }
                    }
                }
                Toggle("Top tabs", isOn: $store.appearance.topTabs).toggleStyle(.checkbox).font(.system(size: 12))
            }.padding(20).shellCard(theme)

            GeneralSettingsView(store: store, theme: theme)

            NotificationSettingsView(store: store, notifications: store.notifications, theme: theme)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Your services").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    AddAccountButton(theme: theme) { addingAccount = true }
                }
                ForEach(store.preferences.accounts) { account in
                    accountRow(account)
                }
            }
            RemovedAccountsView(store: store, theme: theme)
        }
        .sheet(isPresented: $addingAccount) {
            AddAccountPicker(services: store.services, theme: theme) { service in
                addingAccount = false
                store.add(service)
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(theme.muted).frame(width: 20, height: 28)
                .contentShape(Rectangle())
                .help("Drag to reorder \(account.name)")
                .accessibilityLabel("Reorder \(account.name)")
                .onDrag {
                    NSItemProvider(object: store.accountDragScope.payload(for: account.id) as NSString)
                } preview: {
                    ServiceIcon(id: account.serviceID, size: 22)
                        .foregroundStyle(theme.ink).padding(9)
                }
            ServiceIcon(id: account.serviceID, size: 25)
            Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 8)
            Button {
                if store.isLoaded(account) { store.unload(account) } else { store.select(account) }
            } label: {
                Text(store.isLoaded(account) ? "Loaded" : "Load").font(.system(size: 11)).frame(width: 76, height: 32)
            }.buttonStyle(ShellButtonStyle(theme: theme, selected: store.isLoaded(account)))
                .help(store.isLoaded(account) ? "Unload" : "Load")
            Button { store.setVisible(account, !store.isVisible(account)) } label: {
                Image(systemName: store.isVisible(account) ? "eye" : "eye.slash").frame(width: 28, height: 28)
            }.buttonStyle(ShellButtonStyle(theme: theme, selected: !store.isVisible(account)))
                .help(store.isVisible(account) ? "Hide shortcut" : "Show shortcut")
                .accessibilityLabel("Toggle shortcut for \(account.name)")
            Menu {
                Button("Open") { store.select(account) }
                Toggle("Keep awake in background", isOn: Binding(get: { account.staysAwake },
                    set: { store.setKeepLive(account, enabled: $0) }))
                if account.serviceID == "gmail" {
                    Picker("Gmail badge", selection: Binding(get: { account.gmailAllUnread == true },
                        set: { store.setGmailAllUnread(account, enabled: $0) })) {
                        Text("New since launch").tag(false)
                        Text("All unread").tag(true)
                    }
                }
                Toggle("Notifications", isOn: Binding(get: { account.notifications != false },
                    set: { store.setAccountNotifications(account, enabled: $0) }))
                Toggle("Mute media audio", isOn: Binding(get: { account.audioMuted == true },
                    set: { store.setAudioMuted(account, muted: $0) }))
                Button("Add another account") {
                    if let service = store.services.first(where: { $0.id == account.serviceID }) { store.add(service) }
                }
                Button("Rename…") { store.editingAccount = account }
                if ChromiumRuntime.isEnabled {
                    Menu("Browser engine") {
                        Button("WebKit\(account.usesChromium ? "" : " ✓")") { store.setBrowserEngine(account, chromium: false) }
                        Button("Chromium Experimental\(account.usesChromium ? " ✓" : "")") { store.setBrowserEngine(account, chromium: true) }
                            .disabled(!ChromiumRuntime.isEnabled)
                    }
                }
                Button("Move earlier") { store.move(account, by: -1) }
                Button("Move later") { store.move(account, by: 1) }
                Divider()
                Button("Remove…", role: .destructive) { store.removingAccount = account }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Manage \(account.name)")
        }.padding(.horizontal, 16).padding(.vertical, 14).shellCard(theme)
            .accountDropTarget(store: store, account: account, theme: theme)
    }

    private func choice(_ title: String, values: [String], key: WritableKeyPath<AppearancePreferences, String>,
                        previews: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(theme.muted)
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button { store.appearance[keyPath: key] = value } label: {
                        VStack(spacing: 8) {
                            if previews {
                                let color = Color(hex: value == "Ocean" ? "1B3046" : value == "Dune" ? "8E7E66" : "454D58")
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.5))
                                    RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 14)
                                    RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 20, height: 3).padding(.leading, 22)
                                }.frame(height: 23)
                            }
                            Text(value).font(.system(size: 12, weight: store.appearance[keyPath: key] == value ? .semibold : .regular))
                        }.frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 9)
                    }.buttonStyle(ShellButtonStyle(theme: theme, selected: store.appearance[keyPath: key] == value, bordered: true))
                }
            }
        }
    }
}
