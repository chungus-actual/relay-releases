import AppKit
import Combine

@MainActor
final class UnreadCenter: ObservableObject {
    @Published private(set) var states: [UUID: UnreadState] = [:]
    @Published private(set) var activity: [UnreadActivity] = []
    private var gmailCounters: [UUID: GmailUnreadCounter] = [:]
    private var gmailReadings: [UUID: UnreadReading] = [:]
    var onActivity: ((UnreadActivity) -> Void)?
    var onBadgeChanged: ((String?) -> Void)?

    func badge(for id: UUID) -> String { states[id]?.badge ?? "" }
    var dockBadge: String? {
        let total = states.values.reduce(0) { $0 + $1.count }
        if total > 0 { return total > 99 ? "99+" : String(total) }
        return states.values.contains { !$0.badge.isEmpty } ? "•" : nil
    }

    func receive(_ reading: UnreadReading, for id: UUID, recordActivity: Bool = true) {
        guard reading.valid else { return }
        var state = states[id] ?? UnreadState()
        let newActivity = state.receive(reading)
        // Avoid rebuilding the shell on unchanged DOM polls.
        guard states[id] != state || newActivity else { return }
        let oldBadge = states[id]?.badge ?? ""
        states[id] = state
        if newActivity && recordActivity {
            let entry = UnreadActivity(accountID: id, summary: reading.summary, time: Date())
            activity.insert(entry, at: 0)
            onActivity?(entry)
            if activity.count > 60 { activity.removeLast(activity.count - 60) }
        }
        if oldBadge != state.badge { onBadgeChanged?(dockBadge) }
    }

    func receiveGmail(_ reading: UnreadReading, for id: UUID, allUnread: Bool, recordActivity: Bool = true) {
        guard reading.valid else { return }
        if reading.count != nil { gmailReadings[id] = reading }
        var counter = gmailCounters[id] ?? GmailUnreadCounter()
        let displayed = counter.reading(reading, allUnread: allUnread)
        gmailCounters[id] = counter
        receive(displayed, for: id, recordActivity: recordActivity)
    }

    func setGmailMode(for id: UUID, allUnread: Bool) {
        let reading = gmailReadings[id]
        gmailCounters[id] = nil
        states[id] = nil
        activity.removeAll { $0.accountID == id }
        if let reading { receiveGmail(reading, for: id, allUnread: allUnread, recordActivity: false) }
        onBadgeChanged?(dockBadge)
    }

    func recordNotification(for id: UUID, summary: String, notificationID: String? = nil) {
        let entry = UnreadActivity(accountID: id, summary: summary, time: Date(), notificationID: notificationID)
        activity.insert(entry, at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
        onActivity?(entry)
    }

    func dismiss(_ id: UUID) {
        states[id]?.dismiss()
        activity.removeAll { $0.accountID == id }
        onBadgeChanged?(dockBadge)
    }

    func clearActivity() { activity.removeAll() }

    func forget(_ id: UUID, removeActivity: Bool) {
        if removeActivity {
            gmailCounters[id] = nil
            gmailReadings[id] = nil
            states.removeValue(forKey: id)
            activity.removeAll { $0.accountID == id }
        } else if var state = states[id] {
            _ = state.receive(.unknown)
            states[id] = state
        }
        onBadgeChanged?(dockBadge)
    }
}
