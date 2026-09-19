import Foundation

struct DownloadDestination {
    let file: URL
    let stagingDirectory: URL
    let stagingFile: URL
    let replacesExisting: Bool

    static func suggestedName(_ value: String) -> String {
        let name = (value.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    init(file: URL) throws {
        self.file = file
        replacesExisting = FileManager.default.fileExists(atPath: file.path)
        stagingDirectory = file.deletingLastPathComponent().appendingPathComponent(".relay-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        stagingFile = stagingDirectory.appendingPathComponent("payload")
    }

    func finish() throws {
        if replacesExisting && FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: stagingFile)
        } else {
            // If a new file appeared while downloading, fail instead of silently replacing it.
            try FileManager.default.moveItem(at: stagingFile, to: file)
        }
        cleanup()
    }

    func cleanup() { try? FileManager.default.removeItem(at: stagingDirectory) }
}
