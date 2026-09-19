import AppKit
import Combine
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum Status: String { case resuming = "Resuming", interrupted = "Interrupted", choosing = "Choose location", downloading = "Downloading", complete = "Complete", cancelled = "Canceled", failed = "Failed" }
    let id = UUID()
    let account: Account
    @Published var name = "Download"
    @Published var status = Status.choosing
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var failure: String?
    @Published var resumeData: Data?
    var sourceView: WKWebView?
    weak var chromiumSession: ChromiumSession?
    var chromiumID: String?
    var chromiumResumable = false
    var canResume: Bool { status == .interrupted && ((resumeData != nil && sourceView != nil) || chromiumResumable) }
    var destination: DownloadDestination?
    var download: WKDownload?
    var panel: NSSavePanel?
    var observations: [NSKeyValueObservation] = []
    var isActive: Bool { status == .choosing || status == .downloading || status == .resuming }
    var revealURL: URL? {
        guard let destination else { return nil }
        if status == .complete { return destination.file }
        if status == .failed && FileManager.default.fileExists(atPath: destination.stagingFile.path) { return destination.stagingFile }
        return nil
    }
    func showInFinder() {
        guard let destination else { return }
        let target = revealURL ?? destination.file
        if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        else { NSWorkspace.shared.open(destination.file.deletingLastPathComponent()) }
    }
    init(account: Account, download: WKDownload? = nil) { self.account = account; self.download = download }
}

@MainActor
final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    @Published var isOpen = false
    // Only the isolated integration runner sets this; normal downloads always show NSSavePanel.
    var destinationForTesting: ((String) -> URL?)?
    private var active: [ObjectIdentifier: DownloadItem] = [:]

    func chromiumEvent(_ event: String, data: [String: Any], session: ChromiumSession, account: Account) {
        guard let id = data["id"] as? String else { return }
        if event == "downloadRequest" {
            let item = DownloadItem(account: account)
            item.chromiumSession = session; item.chromiumID = id
            item.name = DownloadDestination.suggestedName(data["name"] as? String ?? "Download")
            items.insert(item, at: 0); isOpen = true
            let choose: (URL?) -> Void = { [weak self, weak session, item] url in
                item.panel = nil
                guard let self, let session else { return }
                guard let url, item.status == .choosing else { self.cancel(item); return }
                do {
                    let destination = try DownloadDestination(file: url)
                    item.destination = destination; item.name = url.lastPathComponent; item.status = .downloading
                    session.command("download", ["id": id, "action": "accept", "path": destination.stagingFile.path])
                } catch {
                    self.cancel(item); item.status = .failed; item.failure = error.localizedDescription
                }
            }
            if let destinationForTesting { choose(destinationForTesting(item.name)); return }
            let panel = NSSavePanel(); item.panel = panel
            panel.title = "Save download · \(account.name)"; panel.nameFieldStringValue = item.name; panel.canCreateDirectories = true
            if let window = session.view.window ?? NSApp.keyWindow { panel.beginSheetModal(for: window) { choose($0 == .OK ? panel.url : nil) } }
            else { panel.begin { choose($0 == .OK ? panel.url : nil) } }
            return
        }
        guard let item = items.first(where: { $0.chromiumID == id && $0.chromiumSession === session }), item.status != .cancelled else { return }
        item.received = (data["received"] as? NSNumber)?.int64Value ?? 0
        item.total = (data["total"] as? NSNumber)?.int64Value ?? 0
        switch data["state"] as? Int {
        case 1: item.status = .downloading
        case 2:
            do {
                guard let destination = item.destination else { throw CocoaError(.fileNoSuchFile) }
                try destination.finish(); item.status = .complete
            } catch { item.status = .failed; item.failure = "Couldn't move the completed file. Use Show in Finder to recover it." }
            releaseChromium(item)
        case 3: item.status = .cancelled; item.destination?.cleanup(); releaseChromium(item)
        case 4:
            item.failure = data["error"] as? String
            item.chromiumResumable = data["finished"] as? Bool == false && item.destination != nil
            item.status = item.chromiumResumable ? .interrupted : .failed
            if !item.chromiumResumable { item.destination?.cleanup(); releaseChromium(item) }
        default: break
        }
    }

    private func releaseChromium(_ item: DownloadItem) {
        let session = item.chromiumSession, id = item.chromiumID
        item.chromiumSession = nil; item.chromiumID = nil; item.chromiumResumable = false; item.panel = nil
        if let id { session?.command("download", ["id": id, "action": "release"]) }
        let excess = Set(items.filter { !$0.isActive && !$0.canResume }.dropFirst(50).map(\.id))
        items.removeAll { excess.contains($0.id) }
    }

    func track(_ download: WKDownload, account: Account) {
        let item = DownloadItem(account: account, download: download)
        item.sourceView = download.webView
        active[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        isOpen = true
        download.delegate = self
    }

    func hasActiveDownloads(_ id: UUID) -> Bool { items.contains { $0.account.id == id && ($0.isActive || $0.canResume) } || active.values.contains { $0.account.id == id } }

    func clearFinished() {
        items.removeAll { !$0.isActive && !$0.canResume }
    }

    private func discardResume(_ item: DownloadItem) {
        item.resumeData = nil
        item.sourceView = nil
        item.destination?.cleanup()
    }

    func resume(_ item: DownloadItem) {
        if item.canResume, let session = item.chromiumSession, let id = item.chromiumID {
            item.status = .resuming; item.failure = nil; item.chromiumResumable = false
            session.command("download", ["id": id, "action": "resume"]); return
        }
        guard item.canResume, let data = item.resumeData, let view = item.sourceView else { return }
        item.status = .resuming
        item.resumeData = nil
        item.failure = nil
        view.resumeDownload(fromResumeData: data) { [weak self, item] download in
            guard let self else { download.cancel { _ in }; return }
            guard item.status == .resuming else {
                download.cancel { _ in item.destination?.cleanup() }
                return
            }
            item.download = download
            self.active[ObjectIdentifier(download)] = item
            item.status = .downloading
            download.delegate = self
            self.observeProgress(download, item: item)
        }
    }

    private func observeProgress(_ download: WKDownload, item: DownloadItem) {
        let update: () -> Void = { [weak item, weak download] in
            guard let item, let download, item.download === download, item.isActive else { return }
            item.received = download.progress.completedUnitCount
            item.total = download.progress.totalUnitCount
        }
        item.observations = [
            download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { _, _ in Task { @MainActor in update() } },
            download.progress.observe(\.totalUnitCount, options: [.initial, .new]) { _, _ in Task { @MainActor in update() } }
        ]
    }

    func cancel(_ item: DownloadItem) {
        if let session = item.chromiumSession, let id = item.chromiumID, item.isActive || item.canResume {
            item.status = .cancelled
            item.panel?.cancel(nil)
            session.command("download", ["id": id, "action": "cancel"])
            item.destination?.cleanup(); releaseChromium(item); return
        }
        if item.canResume || item.status == .resuming {
            item.status = .cancelled
            discardResume(item)
            return
        }
        guard item.isActive else { return }
        item.panel?.cancel(nil)
        guard let download = item.download else { return }
        item.status = .cancelled
        download.cancel { [weak self, weak item] _ in
            guard let self, let item else { return }
            item.destination?.cleanup()
            self.release(download, item: item)
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let item = active[ObjectIdentifier(download)] else { completionHandler(nil); return }
        if item.status == .downloading, let destination = item.destination {
            completionHandler(destination.stagingFile)
            return
        }
        item.name = DownloadDestination.suggestedName(suggestedFilename)
        let choose: (URL?) -> Void = { [weak self, item, download] url in
            item.panel = nil
            guard let self else { completionHandler(nil); return }
            guard let url, item.status == .choosing else {
                item.status = .cancelled
                completionHandler(nil)
                self.release(download, item: item)
                return
            }
            do {
                let destination = try DownloadDestination(file: url)
                item.destination = destination
                item.name = url.lastPathComponent
                item.status = .downloading
                self.observeProgress(download, item: item)
                completionHandler(destination.stagingFile)
            } catch {
                item.status = .failed
                item.failure = error.localizedDescription
                completionHandler(nil)
                self.release(download, item: item)
            }
        }
        if let destinationForTesting { choose(destinationForTesting(item.name)); return }
        let panel = NSSavePanel()
        panel.title = "Save download · \(item.account.name)"
        panel.nameFieldStringValue = item.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        item.panel = panel
        if let window = download.webView?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { result in choose(result == .OK ? panel.url : nil) }
        } else {
            panel.begin { result in choose(result == .OK ? panel.url : nil) }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = active[ObjectIdentifier(download)] else { return }
        // WebKit may deliver completion after cancel was requested. Never commit those bytes.
        guard item.status != .cancelled else {
            item.destination?.cleanup()
            release(download, item: item)
            return
        }
        do {
            guard let destination = item.destination else { throw CocoaError(.fileNoSuchFile) }
            try destination.finish()
            item.received = (try? destination.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.received
            item.status = .complete
        } catch {
            item.status = .failed
            item.failure = "Couldn't move the completed file: \(error.localizedDescription). Use Show in Finder to recover it."
        }
        release(download, item: item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = active[ObjectIdentifier(download)] else { return }
        if item.status != .cancelled {
            item.failure = error.localizedDescription
            if let resumeData, !resumeData.isEmpty, item.destination != nil, item.sourceView != nil {
                item.resumeData = resumeData
                item.status = .interrupted
            } else { item.status = .failed }
        }
        if item.resumeData == nil { item.destination?.cleanup() }
        release(download, item: item)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(request.url?.scheme == "https" ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func release(_ download: WKDownload, item: DownloadItem) {
        item.observations.removeAll()
        item.download = nil
        item.panel = nil
        download.delegate = nil
        if item.resumeData == nil { item.sourceView = nil }
        active.removeValue(forKey: ObjectIdentifier(download))
        // Keep a bounded history without discarding active transfers.
        let finished = items.filter { !$0.isActive && !$0.canResume }
        let remove = Set(finished.dropFirst(50).map(\.id))
        for entry in items where remove.contains(entry.id) && entry.resumeData != nil { discardResume(entry) }
        items.removeAll { remove.contains($0.id) }
    }
}
