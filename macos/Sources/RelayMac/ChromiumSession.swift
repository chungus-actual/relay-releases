import AppKit
import Combine
import Darwin

@MainActor
final class ChromiumRuntime {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Initialize = @convention(c) (UnsafePointer<CChar>) -> Int32
    typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer, UnsafeMutableRawPointer, Callback) -> UnsafeMutableRawPointer?
    typealias Command = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Processes = @convention(c) () -> UnsafeMutablePointer<CChar>?
    typealias Free = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    static let shared = ChromiumRuntime()
    static var isBundled: Bool { FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libRelayChromium.dylib").path) }
    static var isEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "RelayExperimentalChromium") as? Bool == true && isBundled }
    private var library: UnsafeMutableRawPointer?
    private(set) var create: Create?
    private var commandFunction: Command?
    private var destroyFunction: Destroy?
    private var processesFunction: Processes?
    private var freeFunction: Free?
    private(set) var failure: String?
    var available: Bool { create != nil }

    private init() {
        guard Self.isEnabled else { return }
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libRelayChromium.dylib").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { failure = dlerror().map { String(cString: $0) }; return }
        self.library = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: type) } }
        guard let initialize = symbol("relay_chromium_initialize", Initialize.self),
              let create = symbol("relay_chromium_create", Create.self),
              let command = symbol("relay_chromium_command", Command.self),
              let destroy = symbol("relay_chromium_destroy", Destroy.self) else { failure = "Chromium bridge is incomplete."; return }
        let plugins = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns").path
        guard initialize(plugins) == 1 else { failure = "Chromium could not start."; return }
        self.create = create; commandFunction = command; destroyFunction = destroy
        processesFunction = symbol("relay_chromium_processes", Processes.self)
        freeFunction = symbol("relay_chromium_free", Free.self)
    }
    func command(_ handle: UnsafeMutableRawPointer?, _ name: String, _ values: [String: Any] = [:]) {
        guard let handle, let data = try? JSONSerialization.data(withJSONObject: values), let text = String(data: data, encoding: .utf8) else { return }
        commandFunction?(handle, name, text)
    }
    func destroy(_ handle: UnsafeMutableRawPointer) { destroyFunction?(handle) }
    func processes() -> [[String: Any]] {
        guard let data = processesFunction?() else { return [] }
        defer { freeFunction?(data) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: data).utf8))) as? [[String: Any]] ?? []
    }
    func processData() async -> Data? {
        let read = processesFunction, release = freeFunction
        return await Task.detached(priority: .utility) {
            guard let data = read?() else { return nil }
            defer { release?(data) }
            return Data(String(cString: data).utf8)
        }.value
    }
}

@MainActor
final class ChromiumSession {
    final class Host: NSView {
        weak var session: ChromiumSession?
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); session?.resize(newSize) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            session?.resize(bounds.size)
            session?.command("visible", ["value": window != nil && !isHiddenOrHasHiddenAncestor])
        }
        override func viewDidHide() {
            super.viewDidHide()
            session?.command("visible", ["value": false])
        }
        override func viewDidUnhide() {
            super.viewDidUnhide()
            session?.command("visible", ["value": window != nil && !isHiddenOrHasHiddenAncestor])
        }
    }
    struct PageState {
        var url: URL?
        var title = ""
        var back = false
        var forward = false
        var pid: Int32 = 0
        var audible = false
        var sleeping = false
        var muted = false
        var zoom = 1.0
    }
    let view = Host(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    let service: Service
    let account: Account
    private var handle: UnsafeMutableRawPointer?
    var captureLinks = false
    var onState: (() -> Void)?
    var onLoading: ((Int) -> Void)?
    var onLoaded: ((Int, Bool) -> Void)?
    var onTerminated: ((Int) -> Void)?
    var onNotification: ((String, String, String) -> Void)?
    var notificationsAllowed: (() -> Bool)?
    var onDownload: ((String, [String: Any]) -> Void)?
    private(set) var pages: [Int: PageState] = [0: PageState()]
    private var popupOrigins: [Int: (URL?, Bool)] = [:]
    private var evaluations: [String: (Int, CheckedContinuation<Any, Error>)] = [:]
    private let testing: Bool

    init(account: Account, service: Service, testing: Bool = false) throws {
        self.account = account; self.service = service; self.testing = testing
        let runtime = ChromiumRuntime.shared
        guard let create = runtime.create else { throw Failure(message: runtime.failure ?? "Chromium is not bundled in this build.") }
        view.session = self
        let path = testing ? "" : URL.applicationSupportDirectory.appendingPathComponent("Relay/macOS/Chromium/\(account.id.uuidString)").path
        handle = create(path, Unmanaged.passUnretained(view).toOpaque(), Unmanaged.passUnretained(self).toOpaque()) { context, name, payload in
            guard let context, let name, let payload else { return 0 }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<ChromiumSession>.fromOpaque(context).takeUnretainedValue()
                let values = (try? JSONSerialization.jsonObject(with: Data(String(cString: payload).utf8))) as? [String: Any] ?? [:]
                return owner.receive(String(cString: name), values) ? 1 : 0
            }
        }
        guard handle != nil else { throw Failure(message: "Chromium could not create this account.") }
        command("mute", ["value": account.audioMuted == true]); command("zoom", ["value": account.zoom])
        command("awake", ["value": account.staysAwake])
        if MediaBridge.supports(service.id) { command("script", ["name": "RelayMedia", "source": MediaBridge.script(for: service.id)]) }
        if service.id == "messenger" { command("script", ["name": "RelayMessenger", "source": MessengerChrome.script]) }
    }
    func command(_ name: String, _ values: [String: Any] = [:]) { ChromiumRuntime.shared.command(handle, name, values) }
    func resize(_ size: NSSize) { command("resize", ["width": max(1, Int(size.width)), "height": max(1, Int(size.height))]) }
    func close() {
        guard let handle else { return }
        self.handle = nil
        evaluations.values.forEach { $0.1.resume(throwing: CancellationError()) }; evaluations.removeAll()
        ChromiumRuntime.shared.destroy(handle)
        view.session = nil; pages.removeAll()
    }
    func evaluate(_ source: String, page: Int = 0) async throws -> Any {
        guard handle != nil, pages[page] != nil else { throw CancellationError() }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            evaluations[id] = (page, continuation)
            command("evaluate", ["id": id, "page": page, "source": source])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let pending = self?.evaluations.removeValue(forKey: id) {
                    self?.command("cancelEvaluation", ["id": id])
                    pending.1.resume(throwing: Failure(message: "The page did not respond."))
                }
            }
        }
    }
    private func receive(_ event: String, _ data: [String: Any]) -> Bool {
        let page = data["page"] as? Int ?? 0
        switch event {
        case "navigate":
            guard let text = data["url"] as? String, let url = URL(string: text) else { return false }
            if page != 0, var origin = popupOrigins[page], BrowserRules.googleSignIn(url) { origin.1 = true; popupOrigins[page] = origin }
            if testing, url.host == "127.0.0.1" || url.host == "relay.test" || url.scheme == "data" { return true }
            if ["about", "blob"].contains(url.scheme ?? "") { return true }
            if data["main"] as? Bool != false, data["link"] as? Bool == true || (page != 0 && pages[page]?.url == nil),
               !captureLinks, let target = BrowserRules.webLink(url), !service.allowsEmbedded(target),
               !BrowserRules.providerAttachment(target, service: service.id), !BrowserRules.googleLanding(target, service: service.id) {
                NSWorkspace.shared.open(target); return false
            }
            return url.scheme == "https" || (captureLinks && url.scheme == "http")
        case "state":
            pages[page] = PageState(url: (data["url"] as? String).flatMap(URL.init(string:)), title: data["title"] as? String ?? "",
                back: data["back"] as? Bool ?? false, forward: data["forward"] as? Bool ?? false,
                pid: Int32(data["pid"] as? Int ?? 0), audible: data["audible"] as? Bool ?? false, sleeping: data["sleeping"] as? Bool ?? false,
                muted: data["muted"] as? Bool ?? false, zoom: data["zoom"] as? Double ?? 1)
            onState?()
        case "loading": onLoading?(page)
        case "loaded":
            if let origin = popupOrigins[page], pages[0]?.url == origin.0, BrowserRules.googleApp(pages[page]?.url, service: service.id),
               origin.1 || BrowserRules.googleLanding(origin.0, service: service.id), let url = pages[page]?.url {
                command("load", ["url": url.absoluteString]); command("close", ["page": page])
            } else { onLoaded?(page, data["ok"] as? Bool == true) }
        case "popup": popupOrigins[page] = (pages[0]?.url, false); pages[page] = PageState()
        case "closed": pages.removeValue(forKey: page); popupOrigins.removeValue(forKey: page); onState?()
        case "terminated": onTerminated?(page)
        case "notification":
            if let origin = (data["origin"] as? String).flatMap(URL.init(string:)), service.contains(origin) || (testing && origin.host == "127.0.0.1"),
               let id = data["id"] as? String { onNotification?(id, String((data["title"] as? String ?? "").prefix(200)), String((data["body"] as? String ?? "").prefix(1000))) }
        case "permission": permission(data)
        case "evaluation":
            if let id = data["id"] as? String, let pending = evaluations.removeValue(forKey: id) {
                if let error = data["error"] as? String { pending.1.resume(throwing: Failure(message: error)) }
                else { pending.1.resume(returning: data["result"] ?? NSNull()) }
            }
        case "download", "downloadRequest": onDownload?(event, data)
        default: break
        }
        return true
    }
    private func permission(_ data: [String: Any]) {
        guard let id = data["id"] as? String, let type = data["type"] as? Int else { return }
        let origin = (data["origin"] as? String).flatMap(URL.init(string:))
        let allowedOrigin = origin.map { service.contains($0) || (testing && $0.host == "127.0.0.1") } == true
        if type == 7 { command("permission", ["id": id, "allow": allowedOrigin && notificationsAllowed?() == true]); return }
        guard allowedOrigin, [1,2,3].contains(type), let origin,
              service.allowsMediaPermissionRequest(origin: origin, page: pages[data["page"] as? Int ?? 0]?.url) else {
            command("permission", ["id": id, "allow": false]); return
        }
        let alert = NSAlert(); alert.messageText = "Allow \(origin.host ?? service.name) to use your \(type == 1 ? "microphone" : type == 2 ? "camera" : "camera and microphone")?"
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Don't Allow")
        if let window = view.window { alert.beginSheetModal(for: window) { [weak self] response in self?.command("permission", ["id": id, "allow": response == .alertFirstButtonReturn]) } }
        else { command("permission", ["id": id, "allow": false]) }
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
}
