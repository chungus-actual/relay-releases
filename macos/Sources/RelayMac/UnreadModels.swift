import Foundation

struct UnreadReading: Equatable {
    var count: Int?
    var attention: Bool
    var key: String
    static let unknown = UnreadReading(count: nil, attention: false, key: "unknown")
    var valid: Bool { (count == nil || (0...999_999).contains(count!)) && key.count <= 100 }
    var hasUnread: Bool { count == 0 ? false : (count ?? 0) > 0 || attention }
    var summary: String { count.map { "\($0) unread" } ?? "Unread activity" }
}

struct UnreadState: Equatable {
    private(set) var current = UnreadReading.unknown
    private var lastUnread: UnreadReading?
    private var dismissedKey: String?
    var badge: String {
        guard current.hasUnread, current.key != dismissedKey else { return "" }
        return current.count.map { $0 > 99 ? "99+" : String($0) } ?? "•"
    }
    var count: Int { badge.isEmpty ? 0 : current.count ?? 0 }

    // Return true only for a new/increased unread signal, not every title mutation or reload.
    mutating func receive(_ reading: UnreadReading) -> Bool {
        guard reading.valid else { return false }
        current = reading
        if reading.count == 0 { lastUnread = nil; dismissedKey = nil; return false }
        guard reading.hasUnread else { return false }
        let previous = lastUnread
        lastUnread = reading
        if dismissedKey == reading.key { return false }
        dismissedKey = nil
        guard previous?.key != reading.key else { return false }
        if let count = reading.count, let oldCount = previous?.count, count <= oldCount { return false }
        return true
    }

    mutating func dismiss() { dismissedKey = current.hasUnread ? current.key : lastUnread?.key }
}

struct UnreadActivity: Identifiable {
    let id = UUID()
    let accountID: UUID
    let summary: String
    let time: Date
    var notificationID: String? = nil
}

enum UnreadRules {
    static func countFromTitle(_ title: String) -> Int? {
        // Match the Windows parser: only conventional leading unread formats, never arbitrary digits.
        for pattern in [#"^\s*[\(\[]([0-9]{1,6})\+?[\)\]](?:\s|$)"#, #"(?i)^Inbox\s*\(([0-9]{1,6})\)(?:\s|$)"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(title.startIndex..., in: title)
            if let match = regex.firstMatch(in: title, range: range), let digits = Range(match.range(at: 1), in: title) {
                return Int(title[digits])
            }
        }
        return nil
    }

    static func messengerPage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if ["messenger.com", "www.messenger.com"].contains(host) { return true }
        return ["facebook.com", "www.facebook.com"].contains(host) && (url.path == "/messages" || url.path.hasPrefix("/messages/"))
    }

    static func titleReading(_ title: String, service: Service, url: URL?) -> UnreadReading {
        guard let url, service.contains(url), service.id != "messenger",
              !["youtubemusic", "spotify", "bandcamp"].contains(service.id) else { return .unknown }
        let count = countFromTitle(title)
        return UnreadReading(count: count, attention: false, key: "title:" + (count.map(String.init) ?? "none"))
    }
}

// Gmail keeps its inbox count in navigation even while another folder or message is open.
enum GmailUnread {
    static func page(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "mail.google.com" && url.path.hasPrefix("/mail/")
    }
    static let script = #"""
(() => {
  const numeric = value => {
    const text = value.trim().replace(/[,\s\u00a0\u202f]/g, '');
    if (!/^\d{1,6}$/.test(text)) return null;
    const count = Number(text);
    return count <= 999999 ? count : null;
  };
  const reading = count => ({ Count: count, Unread: false, Key: String(count) });
  const links = document.querySelectorAll('[role="navigation"] a[href], nav a[href], .aeN a[href]');
  for (const link of Array.from(links).slice(0, 400)) {
    let url;
    try { url = new URL(link.href, location.href); } catch { continue; }
    if (url.origin !== location.origin || url.hash !== '#inbox') continue;
    const row = link.closest('.aim') || link.parentElement;
    const badge = row?.querySelector('.bsU');
    if (badge) {
      const count = numeric(badge.textContent || '');
      if (count !== null) return reading(count);
    }
    const label = link.getAttribute('aria-label') || '';
    const match = label.match(/(\d[\d,\s\u00a0\u202f]*)\s+unread/i);
    if (match) {
      const count = numeric(match[1]);
      if (count !== null) return reading(count);
    }
    // A rendered inbox label with no badge means the inbox has no unread mail.
    if (link.getClientRects().length && !badge) return reading(0);
  }
  const title = document.title.match(/^\s*Inbox\s*\(([\d,\s]+)\)/i);
  if (title) {
    const count = numeric(title[1]);
    if (count !== null) return reading(count);
  }
  return { Count: null, Unread: false, Key: 'unknown' };
})()
"""#
}

struct GmailUnreadCounter {
    private(set) var baseline: Int?
    mutating func reading(_ raw: UnreadReading, allUnread: Bool) -> UnreadReading {
        guard raw.valid, let count = raw.count else { return .unknown }
        baseline = min(baseline ?? count, count)
        let shown = allUnread ? count : max(0, count - baseline!)
        return UnreadReading(count: shown, attention: false,
                             key: (allUnread ? "gmail-all:" : "gmail-new:") + String(shown))
    }
}
