import SwiftUI
import WebKit

struct BrowserCaption: View {
    @ObservedObject var session: BrowserSession
    let account: Account
    let theme: ShellTheme
    private var address: URL { session.address ?? session.service.url }
    private var displayDomain: String {
        let host = address.host?.lowercased() ?? ""
        // These are the catalog providers' base domains, not a general suffix rule.
        // Keep unfamiliar domains intact rather than reducing e.g. example.co.uk to co.uk.
        let domains = ["facebook.com", "messenger.com", "whatsapp.com", "telegram.org",
                       "google.com", "slack.com", "youtube.com", "spotify.com", "bandcamp.com", "discord.com"]
        if let domain = domains.first(where: { host == $0 || host.hasSuffix("." + $0) }) { return domain }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var body: some View {
        HStack(spacing: 8) {
            if session.service.isTerminal {
                Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("Local shell").font(.system(size: 11)).foregroundStyle(theme.muted)
            } else {
                Menu {
                    Text(address.absoluteString)
                    Button("Copy address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address.absoluteString, forType: .string)
                    }
                    Button("Open in browser") { NSWorkspace.shared.open(address) }
                } label: {
                    Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle((account.identityColor ?? "").isEmpty ? theme.ink : theme.accent(account.identityColor!))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(account.name + "\n" + address.absoluteString)
                Text(displayDomain).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct CompactNavigation: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var store: RelayStore
    let account: Account
    var body: some View {
        Menu {
            if !session.service.isTerminal {
                Button("Back") { session.goBack() }.disabled(!session.canGoBack)
                Button("Forward") { session.goForward() }.disabled(!session.canGoForward)
                Button("Reload") { session.reload() }
                Button("Service home") { session.load(session.service.url) }
            }
            if session.service.isTerminal { Button("Reload terminal view") { session.reload() } }
            Divider()
            Button("Zoom in") { store.setZoom(account, to: account.zoom + 0.1) }.disabled(account.zoom >= 2)
            Button("Zoom out") { store.setZoom(account, to: account.zoom - 0.1) }.disabled(account.zoom <= 0.5)
            Button("Actual size") { store.setZoom(account, to: 1) }
            if !session.service.isTerminal { Toggle("Mute media audio", isOn: Binding(get: { account.audioMuted == true }, set: { store.setAudioMuted(account, muted: $0) })) }
            Button("Pop out in Relay") { store.popOutService(account) }
            if !session.service.isTerminal { Button("Open in default browser") { session.openExternalURL(session.address ?? session.service.url) } }
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Page controls")
    }
}
