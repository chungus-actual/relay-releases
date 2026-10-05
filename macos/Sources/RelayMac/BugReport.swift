import Foundation

// Only caller-selected event codes enter reports. Raw errors, URLs, account
// labels, page console output, and browser profiles are deliberately excluded.
@MainActor enum ReportEvents {
    private static var events: [String] = []
    static func record(_ provider: String, _ action: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(provider) \(action)")
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
    static var snapshot: String { events.joined(separator: "\n") }
}

struct BugReport: Codable {
    var schema = 1
    var id = UUID().uuidString.lowercased()
    var created = ISO8601DateFormatter().string(from: Date())
    var description = ""
    var diagnostics: [String: String] = [:]
    var events = ""
    var screenshot: String?

    func encoded() throws -> Data {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf16.count <= 8000 else {
            throw EncodingError.invalidValue(description, .init(codingPath: [], debugDescription: "Enter a description (up to 8,000 characters)."))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    static func endpoint(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    static var configuration: (endpoint: URL?, destination: String) {
        guard let url = Bundle.main.url(forResource: "reporting", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode([String: String].self, from: data) else {
            return (nil, "Private Relay intake")
        }
        return (endpoint(config["endpoint"] ?? ""), config["destination"] ?? "Private Relay intake")
    }
}

final class ReportTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    static func submit(_ data: Data, id: String, endpoint: URL, code: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: ReportTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(code, forHTTPHeaderField: "X-Relay-Intake-Key")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let receipt = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              receipt["id"] as? String == id, receipt["stored"] as? Bool == true else {
            throw URLError(.badServerResponse)
        }
    }
}
