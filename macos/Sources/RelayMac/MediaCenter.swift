import Combine
import Foundation

struct ActiveMedia: Equatable {
    let accountID: UUID
    let reading: MediaReading
}

@MainActor
final class MediaCenter: ObservableObject {
    private struct Entry { weak var session: BrowserSession? }
    @Published private(set) var active: ActiveMedia?
    @Published private(set) var performingAction = false
    @Published var error: String?
    private var entries: [UUID: Entry] = [:]
    private var polling: Task<Void, Never>?
    private var refreshing = false
    private var generation = 0

    init(preview: ActiveMedia? = nil) { self.active = preview }

    func register(_ session: BrowserSession) {
        guard MediaBridge.supports(session.service.id) else { return }
        entries[session.accountID] = Entry(session: session)
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func unregister(_ id: UUID) {
        generation += 1
        entries.removeValue(forKey: id)
        if active?.accountID == id { active = nil }
        if entries.isEmpty { polling?.cancel(); polling = nil }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let version = generation
        let prior = active?.accountID
        var readings: [ActiveMedia] = []
        for (id, entry) in entries.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let session = entry.session, let reading = await session.readMedia(),
                  reading.available || reading.playing else { continue }
            guard version == generation, !Task.isCancelled else { return }
            readings.append(ActiveMedia(accountID: id, reading: reading))
        }
        guard version == generation, !Task.isCancelled else { return }
        let playing = readings.filter { $0.reading.playing }
        let candidates = playing.isEmpty ? readings : playing
        let chosen = candidates.first { $0.accountID == prior } ?? candidates.first
        if active != chosen { active = chosen }
    }
    func act(_ action: MediaAction) async {
        guard !performingAction, let current = active, let session = entries[current.accountID]?.session else { return }
        performingAction = true
        defer { performingAction = false }
        let version = generation
        if !(await session.actOnMedia(action)), version == generation {
            error = "The service could not perform that media action. Open its page to continue playback."
        }
        await refresh()
    }
    deinit { polling?.cancel() }
}
