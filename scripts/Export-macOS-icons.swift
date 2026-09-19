import Foundation

// Reuse the Windows geometry source, including Relay's custom music-service icons.
final class Icons: NSObject, XMLParserDelegate {
    let destination: URL
    var key: String?
    var geometry = ""
    var failure: Error?
    var count = 0
    init(destination: URL) { self.destination = destination }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "Geometry" {
            key = attributes["x:Key"]?.replacingOccurrences(of: "ServiceIcon.", with: "")
            geometry = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if key != nil { geometry += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "Geometry", let key else { return }
        let rule = geometry.hasPrefix("F1") ? "nonzero" : "evenodd"
        if geometry.hasPrefix("F0") || geometry.hasPrefix("F1") { geometry = String(geometry.dropFirst(2)) }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path fill-rule=\"\(rule)\" d=\"\(geometry)\"/></svg>"
        do { try svg.write(to: destination.appendingPathComponent(key + ".svg"), atomically: true, encoding: .utf8); count += 1 }
        catch { failure = error; parser.abortParsing() }
        self.key = nil
    }
}

let destination = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let delegate = Icons(destination: destination)
let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
parser.delegate = delegate
guard parser.parse(), delegate.failure == nil, delegate.count > 0 else {
    throw delegate.failure ?? parser.parserError ?? CocoaError(.fileReadCorruptFile)
}
print("Exported \(delegate.count) shared service icons")
