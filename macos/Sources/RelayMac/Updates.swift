import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class RelayUpdates: ObservableObject {
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    func start() {
        guard controller == nil,
              !ProcessInfo.processInfo.arguments.contains("--shell-check"),
              !ProcessInfo.processInfo.arguments.contains("--snapshot-directory"),
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in if self?.canCheck != value { self?.canCheck = value } }
        }
        controller.startUpdater()
    }

    func check() { if canCheck { controller?.checkForUpdates(nil) } }
}

struct UpdateMenu: View {
    @ObservedObject var updates: RelayUpdates
    var body: some View {
        Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
    }
}
