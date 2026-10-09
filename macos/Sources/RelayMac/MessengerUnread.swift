import Foundation
import CoreFoundation

// Ported from UnreadDetection.cs. Browser checks verify parity with the Windows script.
enum MessengerUnread {
    static let script = #"""
(() => {
  const numeric = value => {
    const number = Number(value.replaceAll(',', ''));
    return Number.isSafeInteger(number) && number >= 0 && number <= 999999 ? number : null;
  };
  let count = null;
  const messengerHost = location.hostname === 'messenger.com' || location.hostname === 'www.messenger.com';
  const threadSelector = 'a[href*="/messages/t/"],a[href*="/messages/e2ee/t/"],a[href^="/t/"]';
  // Only explicit messaging totals qualify; notification text can mention Messenger too.
  const labels = document.querySelectorAll('nav [aria-label],[role="navigation"] [aria-label],[role="banner"] [aria-label]');
  for (const element of Array.from(labels).slice(0, 400)) {
    if (element.closest('[role="row"],' + threadSelector)) continue;
    const label = (element.getAttribute('aria-label') || '').trim();
    const match = label.match(/^(?:messenger|chats?|messages?)\s*[,:(·-]?\s*(\d[\d,]*)\+?\s+unread(?:\s+(?:messages?|chats?|conversations?))?\s*\)?$/i)
      || label.match(/^(\d[\d,]*)\+?\s+unread\s+(?:messages?|chats?|conversations?)$/i);
    if (match) {
      count = numeric(match[1]);
      if (count !== null) break;
    }
  }
  // Facebook titles include non-message notifications even when named "Messenger".
  if (count === null && messengerHost && /messenger|messages/i.test(document.title)) {
    const title = document.title.match(/^\s*[\[(](\d[\d,]*)\+?[\])]/);
    if (title) count = numeric(title[1]);
  }
  // Virtualized chat rows are evidence of unread activity, not a trustworthy total.
  const keys = new Set();
  const seen = new Set();
  const candidates = document.querySelectorAll(threadSelector + ',[role="row"]');
  for (const candidate of Array.from(candidates).slice(0, 500)) {
    const row = candidate.closest('[role="row"]') || candidate;
    if (seen.has(row)) continue;
    seen.add(row);
    const link = row.matches('a[href]') ? row : row.querySelector(threadSelector);
    if (!link) continue;
    let url;
    try { url = new URL(link.getAttribute('href'), location.href); } catch { continue; }
    if (url.origin !== location.origin || !(/^\/messages\/(?:e2ee\/)?t\/[^/]+\/?$/.test(url.pathname)
      || (messengerHost && /^\/t\/[^/]+\/?$/.test(url.pathname)))) continue;
    const marks = [row, ...Array.from(row.querySelectorAll('[aria-label],[data-testid]')).slice(0, 50)];
    const unread = marks.some(mark => {
      const label = mark.getAttribute('aria-label') || '';
      const testId = mark.getAttribute('data-testid') || '';
      return /^(?:unread(?:\s+(?:messages?|chats?|conversation))?|\d+\s+unread(?:\s+messages?)?)$/i.test(label.trim())
        || /(?:^|[,·])\s*unread messages?(?:$|[,·])/i.test(label)
        || /^(?:mwthreadlist_unread_indicator|unread-indicator)$/.test(testId);
    });
    if (unread) keys.add(url.pathname);
  }
  let hash = 2166136261;
  for (const char of Array.from(keys).sort().join('|')) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  return { Count: count, Unread: count === 0 ? false : keys.size > 0,
    Key: String(count) + ':' + (hash >>> 0).toString(16) };
})()
"""#

    static func reading(_ value: Any, prefix: String = "messenger:") -> UnreadReading? {
        guard let object = value as? [String: Any], let attention = object["Unread"] as? Bool,
              let key = object["Key"] as? String else { return nil }
        let count: Int?
        if object["Count"] is NSNull { count = nil }
        else {
            guard let number = object["Count"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue) else { return nil }
            count = number.intValue
        }
        let result = UnreadReading(count: count, attention: attention, key: prefix + key)
        return result.valid ? result : nil
    }
}
