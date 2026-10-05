import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor final class BugReportDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var report: BugReport
    @Published var preview: NSImage?
    @Published var status = ""
    @Published var busy = false
    @Published var sent = false
    @Published var pending: Data?
    @Published var code = ""
    weak var session: BrowserSession?
    let configuration = BugReport.configuration

    init(store: RelayStore, session: BrowserSession?, account: Account? = nil) {
        self.session = session
        let window = session?.contentView.window ?? NSApp.mainWindow
        report = BugReport(diagnostics: [
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": session == nil ? "not loaded" : (session?.chromium != nil ? "Chromium" : "WebKit"),
            "engineVersion": session == nil ? "not loaded" : (session?.chromium != nil ? "experimental Chromium bridge" : (Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "system")),
            "provider": session?.service.id ?? account?.serviceID ?? "shell",
            "loaded": String(session != nil),
            "visible": String(session?.contentView.window != nil && session?.contentView.isHiddenOrHasHiddenAncestor == false),
            "keepLive": String(session?.keepLive == true),
            "zoom": String(session?.chromium?.pages[0]?.zoom ?? session?.webView.pageZoom ?? 1),
            "window": window.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none",
            "loadedAccounts": String(store.loadedSessions.count)
        ], events: ReportEvents.snapshot)
        #if arch(arm64)
        report.diagnostics["architecture"] = "arm64"
        #else
        report.diagnostics["architecture"] = "x86_64"
        #endif
        if configuration.endpoint == nil { status = "Online reporting is not configured in this build. Save the report and send it to the maintainer privately." }
    }
    var canCapture: Bool { session?.chromium == nil && session?.contentView.window != nil && session?.contentView.isHiddenOrHasHiddenAncestor == false }
    func setImage(_ data: Data) throws {
        guard data.count <= 6 * 1024 * 1024, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        preview = image
        report.screenshot = data.base64EncodedString()
    }
    func capture() async {
        guard canCapture, let session, !busy, pending == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let image = try await session.webView.takeSnapshot(configuration: nil)
            guard self.session === session, canCapture, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadUnknown) }
            try setImage(png)
            status = "Review the image before sending. A page capture may redraw a rendering glitch; you can attach an OS screenshot instead."
        } catch { status = "Could not capture this page. Attach a PNG screenshot instead." }
    }
    func attach() {
        guard !busy, pending == nil else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 6 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            try setImage(Data(contentsOf: url))
            status = "Review the image before sending."
        } catch { status = "Choose a valid PNG smaller than 6 MB." }
    }
    func save() {
        guard !busy else { return }
        guard let payload = try? (pending ?? report.encoded()) else { status = "Enter a description (up to 8,000 characters)."; return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.json]
        picker.nameFieldStringValue = "relay-report-\(report.id).json"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do { try payload.write(to: url, options: .atomic); status = "Report saved. The file includes any image shown above." }
        catch { status = "Could not save the report. Choose another location." }
    }
    func send() async {
        guard !busy, !sent, let endpoint = configuration.endpoint else { return }
        guard !report.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              report.description.utf16.count <= 8000 else { status = "Enter a description (up to 8,000 characters) and the intake code."; return }
        busy = true
        defer { busy = false }
        do {
            if pending == nil { pending = try report.encoded() }
            status = "Sending…"
            try await ReportTransport.submit(pending!, id: report.id, endpoint: endpoint, code: code)
            sent = true; code = ""; status = "Report received: \(report.id)"
        } catch { status = "Could not confirm delivery. Save the report or retry; retries use the same report ID." }
    }
}

struct BugReportView: View {
    @ObservedObject var draft: BugReportDraft
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Report a problem").font(.title2.bold())
                Text("Describe what happened, what you expected, and how to reproduce it. Reports include the diagnostics below. Screenshots are optional and may show private conversations.")
                TextEditor(text: $draft.report.description).frame(height: 100).disabled(draft.pending != nil)
                Text("Diagnostics (no chat text, URLs, account names, cookies, or sign-in data)").font(.caption)
                ScrollView {
                    Text(draft.report.diagnostics.keys.sorted().map { "\($0): \(draft.report.diagnostics[$0]!)" }.joined(separator: "\n") + "\n\n" + draft.report.events)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120)
                HStack {
                    Button("Capture page") { Task { await draft.capture() } }.disabled(!draft.canCapture)
                    Button("Attach PNG…") { draft.attach() }
                    Button("Remove image") { draft.preview = nil; draft.report.screenshot = nil }.disabled(draft.preview == nil)
                }.disabled(draft.busy || draft.pending != nil)
                if let image = draft.preview { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180) }
                Text("Destination: \(draft.configuration.destination)")
                if draft.configuration.endpoint != nil {
                    SecureField("Intake code (from the Relay maintainer)", text: $draft.code).disabled(draft.busy || draft.sent)
                }
                Text(draft.status).font(.callout).textSelection(.enabled)
                HStack {
                    Button("Save report…") { draft.save() }.disabled(draft.busy)
                    Spacer()
                    Button("Close") { dismiss() }.disabled(draft.busy)
                    if draft.configuration.endpoint != nil {
                        Button(draft.sent ? "Report received" : (draft.pending == nil ? "Send report" : "Retry send")) { Task { await draft.send() } }
                            .disabled(draft.busy || draft.sent)
                    }
                }
            }.padding(24)
        }.frame(width: 600, height: 740).interactiveDismissDisabled(draft.busy)
    }
}
