import SwiftUI

struct MusicAwareTitlebarPet: View {
    let theme: ShellTheme
    @ObservedObject var media: MediaCenter
    @ObservedObject var store: RelayStore
    var body: some View {
        TitlebarPet(theme: theme, musicPlaying: media.active?.reading.playing == true, selectedCompanion: store.titlebarCompanion)
    }
}

struct MediaControlsView: View {
    @ObservedObject var store: RelayStore
    @ObservedObject var center: MediaCenter
    let theme: ShellTheme
    var body: some View {
        if let active = center.active {
            HStack(spacing: 2) {
                Button {
                    if let account = store.preferences.accounts.first(where: { $0.id == active.accountID }) { store.select(account) }
                } label: {
                    MediaTitle(text: active.reading.title.isEmpty ? "Now playing" : active.reading.title)
                }.help([active.reading.title, active.reading.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                control("Previous track", "backward.end.fill", .previous, enabled: active.reading.previous)
                control(active.reading.playing ? "Pause" : "Play", active.reading.playing ? "pause.fill" : "play.fill",
                        active.reading.playing ? .pause : .play, enabled: true)
                control("Next track", "forward.end.fill", .next, enabled: active.reading.next)
                Button { Task { await center.floatActive() } } label: {
                    Image(systemName: "pip.enter").font(.system(size: 11)).frame(width: 26, height: 28)
                }.help("Float player").accessibilityLabel("Float player")
            }
            .onAppear { updatePlayerAppearance() }
            .onChange(of: theme.dark) { _, _ in updatePlayerAppearance() }
            .onChange(of: store.appearance) { _, _ in updatePlayerAppearance() }
            .foregroundStyle(theme.muted).buttonStyle(ShellButtonStyle(theme: theme))
            .alert("Playback", isPresented: Binding(get: { center.error != nil }, set: { if !$0 { center.error = nil } })) {
                Button("OK") { center.error = nil }
            } message: { Text(center.error ?? "") }
        }
    }
    private func updatePlayerAppearance() {
        center.updatePlayerAppearance(dark: theme.dark, background: NSColor(theme.panel), foreground: NSColor(theme.ink), accent: NSColor(theme.accent))
    }
    private func control(_ name: String, _ symbol: String, _ action: MediaAction, enabled: Bool) -> some View {
        Button { Task { await center.act(action) } } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 28)
        }.disabled(!enabled || center.performingAction).help(name).accessibilityLabel(name)
    }
}

private struct MediaTitle: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var started = Date()

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
    }

    var body: some View {
        let width = min(textWidth, 160)
        let overflow = max(0, textWidth - width)
        Group {
            if overflow > 0 && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    // Pause at both ends; travel at a constant, readable speed.
                    let travel = Double(overflow) / 28
                    let phase = max(0, context.date.timeIntervalSince(started))
                        .truncatingRemainder(dividingBy: 2 * travel + 4)
                    let distance = phase < 2 ? 0 : phase < 2 + travel ? (phase - 2) * 28
                        : phase < 4 + travel ? Double(overflow) : (2 * travel + 4 - phase) * 28
                    Text(text).fixedSize().offset(x: -distance)
                        .frame(width: width, alignment: .leading).clipped()
                }
            } else {
                Text(text).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .font(.system(size: 11))
        .frame(width: width, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { _, _ in started = Date() }
        .onAppear { started = Date() }
    }
}

struct AudioAccountIndicator: View {
    @ObservedObject var center: MediaCenter
    let account: Account
    var body: some View {
        let playing = center.audioAccounts.contains(account.id)
        if playing && account.audioMuted != true {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9)).padding(3)
                .help("Playing audio")
                .accessibilityLabel(account.name + " · Playing audio")
        }
    }
}
