import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class RelayNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var requesting = false
    @Published private(set) var status: String?
    var openAccount: ((UUID) -> Void)?
    var activateNotification: ((UUID, String) -> Void)?
    var shouldPresent: ((UUID) -> Bool)?

    func configure() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() async -> Bool {
        guard !requesting else { return false }
        requesting = true
        defer { requesting = false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            status = granted ? nil : "Allow Relay notifications in System Settings → Notifications, then try again."
            return granted
        } catch {
            status = "Could not request notifications: \(error.localizedDescription)"
            return false
        }
    }

    func post(_ activity: UnreadActivity, account: Account) {
        let content = UNMutableNotificationContent()
        content.title = account.name
        content.body = activity.summary
        content.sound = .default
        content.userInfo = ["accountID": account.id.uuidString]
        if let id = activity.notificationID { content.userInfo["notificationID"] = id }
        content.threadIdentifier = account.id.uuidString
        let request = UNNotificationRequest(identifier: account.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.status = "Could not show a notification: \(error.localizedDescription)" }
        }
    }
    func clear(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
    func clearAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        let notificationID = response.notification.request.content.userInfo["notificationID"] as? String
        Task { @MainActor [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let id {
                NSApp.activate(ignoringOtherApps: true)
                self?.openAccount?(id)
                if let notificationID { self?.activateNotification?(id, notificationID) }
            }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = (notification.request.content.userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            let present = id.map { self?.shouldPresent?($0) == true } ?? false
            completionHandler(present ? [.banner, .sound] : [])
        }
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var store: RelayStore
    @ObservedObject var notifications: RelayNotifications
    let theme: ShellTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notifications").font(.system(size: 15, weight: .semibold))
            Toggle("Show notifications", isOn: Binding(
                get: { store.preferences.notificationsEnabled == true },
                set: { value in Task { await store.setNotificationsEnabled(value) } }))
                .toggleStyle(.checkbox).disabled(notifications.requesting)
            Toggle("Quiet mode", isOn: $store.quiet).toggleStyle(.checkbox)
            if notifications.requesting { ProgressView().controlSize(.small) }
            if let status = notifications.status { Text(status).font(.system(size: 11)).foregroundStyle(theme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).shellCard(theme)
    }
}
