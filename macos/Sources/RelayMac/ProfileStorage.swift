import WebKit

@MainActor
enum ProfileStorage {
    static func erase(_ id: UUID) async throws {
        // Profile enumeration can crash inside WebKit's RunLoop dispatch before
        // the first web view exists. Initialize it with an empty ephemeral view;
        // no website or persistent profile is loaded by this bootstrap.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bootstrap = WKWebView(frame: .zero, configuration: configuration)
        defer { bootstrap.stopLoading() }
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        if identifiers.contains(id) { try await WKWebsiteDataStore.remove(forIdentifier: id) }
        let chromium = URL.applicationSupportDirectory.appendingPathComponent("Relay/macOS/Chromium/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: chromium.path) { try FileManager.default.removeItem(at: chromium) }
    }
}
