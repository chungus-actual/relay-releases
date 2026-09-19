import SwiftUI

struct DownloadsView: View {
    @ObservedObject var center: DownloadCenter
    let theme: ShellTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Downloads").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Clear") { center.clearFinished() }.font(.system(size: 11))
                    .disabled(!center.items.contains { !$0.isActive && !$0.canResume })
                Button { center.isOpen = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .help("Close downloads").accessibilityLabel("Close downloads")
            }.buttonStyle(.plain)
            if center.items.isEmpty {
                Text("No downloads").font(.system(size: 12)).foregroundStyle(theme.muted)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(center.items) { item in DownloadRow(item: item, center: center, theme: theme) }
                }
            }
        }.padding(14).frame(width: 300).frame(maxHeight: .infinity)
            .background(theme.panel).overlay(alignment: .leading) { Rectangle().fill(theme.line).frame(width: 1) }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let center: DownloadCenter
    let theme: ShellTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                if item.destination != nil {
                    Button { item.showInFinder() } label: { Image(systemName: "folder") }
                        .help("Show in Finder").accessibilityLabel("Show \(item.name) in Finder")
                }
            }
            Text(item.account.name).font(.system(size: 10)).foregroundStyle(theme.muted)
            Text(item.status.rawValue + " · " + ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file))
                .font(.system(size: 10)).foregroundStyle(theme.muted)
            if let failure = item.failure {
                Text(failure).font(.system(size: 10)).foregroundStyle(theme.muted).textSelection(.enabled)
            }
            if item.status == .downloading {
                if item.total > 0 {
                    let fraction = min(max(Double(item.received) / Double(item.total), 0), 1)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.line)
                            Capsule().fill(theme.accent).frame(width: geometry.size.width * fraction)
                        }
                    }.frame(height: 3).padding(.vertical, 4)
                        .accessibilityLabel("Download progress").accessibilityValue("\(Int(fraction * 100)) percent")
                } else { ProgressView().controlSize(.small) }
            }
            HStack {
                if item.canResume { Button("Resume") { center.resume(item) } }
                if item.isActive || item.canResume { Button("Cancel") { center.cancel(item) } }
                if item.status == .complete, let url = item.revealURL {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }.font(.system(size: 11)).foregroundStyle(theme.accent)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).shellCard(theme).buttonStyle(.plain)
    }
}
