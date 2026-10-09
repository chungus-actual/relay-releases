using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private readonly DispatcherTimer unreadTimer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(3) };
    private sealed record ProviderUnreadReading(int? Count, bool Unread, string Key);

    private void InitializeUnreadDetection()
    {
        unreadTimer.Tick += async (_, _) =>
        {
            foreach (var state in services.Where(s => (s.Definition.IconId is "messenger" or "gmail") && s.Core != null && !s.Suspended).ToArray())
                await ReadProviderUnread(state);
        };
    }

    private void UpdateUnreadTimer()
    {
        if (!quitting && services.Any(s => (s.Definition.IconId is "messenger" or "gmail") && s.Core != null && !s.Suspended)) unreadTimer.Start();
        else unreadTimer.Stop();
    }

    private static bool MessengerPage(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && ((uri.Host is "facebook.com" or "www.facebook.com" && (uri.AbsolutePath == "/messages" || uri.AbsolutePath.StartsWith("/messages/", StringComparison.Ordinal)))
            || uri.Host is "messenger.com" or "www.messenger.com");

    private static bool GmailPage(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host == "mail.google.com" && uri.AbsolutePath.StartsWith("/mail/", StringComparison.Ordinal);

    private static bool UnreadPage(ServiceState state, string address) => state.Definition.IconId == "gmail"
        ? GmailPage(address) : state.Definition.IconId == "messenger" && MessengerPage(address);

    private void TitleUnreadChanged(ServiceState state)
    {
        state.UnreadRevision++;
        if (UnreadPage(state, state.Core?.Source ?? ""))
        {
            _ = ReadProviderUnread(state);
            return;
        }
        var count = state.Definition.IconId is "youtube" or "messenger" ? null : ServiceState.CountFromTitle(state.PageTitle);
        ReportUnread(state, count, false, "title:" + count);
    }

    private void ReportUnread(ServiceState state, int? count, bool unread, string key, bool recordActivity = true)
    {
        if (state.Definition.IconId == "gmail" && count.HasValue)
        {
            state.GmailRawUnread = count;
            state.GmailUnreadBaseline = Math.Min(state.GmailUnreadBaseline ?? count.Value, count.Value);
            count = state.Options.GmailAllUnread ? count : Math.Max(0, count.Value - state.GmailUnreadBaseline.Value);
            key = (state.Options.GmailAllUnread ? "gmail-all:" : "gmail-new:") + count;
            bool increased = count > 0 && (!state.LastGmailUnread.HasValue || count > state.LastGmailUnread);
            state.LastGmailUnread = count;
            if (recordActivity && increased && state.DismissedUnreadKey != key)
            {
                activity.Insert(0, new(state, $"{count} unread", "", DateTimeOffset.Now, null));
                if (activity.Count > 60) activity.RemoveRange(60, activity.Count - 60);
            }
        }
        state.UnreadKey = key;
        if (state.DismissedUnreadKey != null)
        {
            if (state.DismissedUnreadKey == key || (count == null && !unread)) { state.Unread = null; state.Attention = false; return; }
            state.DismissedUnreadKey = null;
        }
        if (count == 0) state.NativeAttention = false;
        state.Unread = count;
        state.Attention = unread || state.NativeAttention;
    }

    private void SetGmailUnreadMode(ServiceState state, bool allUnread, bool force = false)
    {
        if (state.Options.GmailAllUnread == allUnread && !force) return;
        state.Options.GmailAllUnread = allUnread;
        state.GmailUnreadBaseline = state.LastGmailUnread = null;
        state.DismissedUnreadKey = null;
        state.Unread = null;
        state.Attention = state.NativeAttention = false;
        activity.RemoveAll(item => item.Service == state);
        if (state.GmailRawUnread.HasValue)
            ReportUnread(state, state.GmailRawUnread, false, "gmail:mode", recordActivity: false);
    }

    private async Task ReadProviderUnread(ServiceState state)
    {
        var core = state.Core;
        if (quitting || state.UnreadPolling || state.Suspended || core == null) return;
        if (!UnreadPage(state, core.Source))
        {
            if (state.Definition.IconId == "messenger")
            {
                ReportUnread(state, null, false, "unknown");
                Refresh();
            }
            return;
        }
        state.UnreadPolling = true;
        int revision = state.UnreadRevision;
        string address = core.Source;
        try
        {
            string json = await core.ExecuteScriptAsync(state.Definition.IconId == "gmail" ? GmailUnreadScript : MessengerUnreadScript);
            if (quitting || state.Core != core || state.UnreadRevision != revision || core.Source != address) return;
            var reading = JsonSerializer.Deserialize<ProviderUnreadReading>(json);
            if (reading == null || reading.Count is < 0 or > 999999 || reading.Key == null || reading.Key.Length > 80) return;
            ReportUnread(state, reading.Count, reading.Unread, state.Definition.IconId + ":" + reading.Key);
            Refresh();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException or JsonException)
        {
            if (ex is JsonException && !quitting && state.Core == core) Log(ex);
        }
        finally { state.UnreadPolling = false; }
    }

    private void DismissService(ServiceState state)
    {
        state.UnreadRevision++;
        state.DismissedUnreadKey = state.UnreadKey;
        state.Unread = null;
        state.Attention = state.NativeAttention = false;
        activity.RemoveAll(item => item.Service == state);
        Refresh();
    }

    private const string GmailUnreadScript = """
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
        """;

    private const string MessengerUnreadScript = """
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
        """;
}
