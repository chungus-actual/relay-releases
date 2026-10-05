import SwiftUI

struct UnreadBadge: View {
    let text: String
    let theme: ShellTheme
    var compact = false
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.system(size: compact ? 8 : 9, weight: .bold))
                .foregroundStyle(theme.dark ? Color(hex: "13251F") : .white)
                .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                .background(theme.accent, in: Capsule())
                .accessibilityLabel(text == "•" ? "Unread activity" : "\(text) unread")
        }
    }
}

struct ActivityFeed: View {
    @ObservedObject var store: RelayStore
    @ObservedObject var center: UnreadCenter
    let theme: ShellTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent activity").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { center.clearActivity() } label: {
                    Text("Clear").font(.system(size: 11)).foregroundStyle(theme.muted).padding(.horizontal, 10).padding(.vertical, 4)
                }.buttonStyle(ShellButtonStyle(theme: theme)).disabled(center.activity.isEmpty)
                    .help("Clear activity history")
            }
            if center.activity.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).stroke(theme.line).frame(width: 35, height: 29)
                            .rotationEffect(.degrees(-10)).offset(x: -7, y: -6)
                        RoundedRectangle(cornerRadius: 9).fill(theme.soft).frame(width: 35, height: 29).offset(x: 8, y: 6)
                        Image(systemName: "checkmark").foregroundStyle(theme.accent).offset(x: 8, y: 6)
                    }.frame(width: 64, height: 48)
                    Text("Nobody is yapping. Suspicious.").font(.system(size: 14, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 36).shellCard(theme)
            } else {
                ForEach(center.activity) { item in
                    if let account = store.preferences.accounts.first(where: { $0.id == item.accountID }) {
                        HStack(alignment: .top, spacing: 8) {
                            Button { store.openActivity(item, account: account) } label: {
                                HStack(alignment: .top, spacing: 16) {
                                    ServiceIcon(id: account.serviceID, size: 18).foregroundStyle(theme.accent).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(spacing: 4) {
                                            Text(account.name).lineLimit(1)
                                            Text("·")
                                            Text(item.time, style: .time)
                                        }.font(.system(size: 10)).foregroundStyle(theme.muted)
                                        Text(item.summary).font(.system(size: 13, weight: .semibold))
                                    }
                                    Spacer(minLength: 0)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(ShellButtonStyle(theme: theme))
                            Button { center.dismiss(account.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(theme.muted).frame(width: 28, height: 28)
                            }.buttonStyle(ShellButtonStyle(theme: theme)).padding(8)
                                .help("Dismiss \(account.name)")
                                .accessibilityLabel("Dismiss \(account.name) in Relay")
                        }.shellCard(theme)
                    }
                }
            }
        }
    }
}
