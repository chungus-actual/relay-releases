namespace Relay;

public partial class MainWindow
{
    private const string WhatsAppChromeScript = """
    (() => {
      if (window !== window.top || location.hostname !== 'web.whatsapp.com') return;
      if (window.__relayWhatsAppChrome) { window.__relayWhatsAppChrome.refresh(); return; }
      const preference = matchMedia('(prefers-color-scheme: dark)');
      const forced = matchMedia('(forced-colors: active)');
      let queued = false, original = null, applied = null, owner = null;
      function update() {
        queued = false;
        const root = document.documentElement, body = document.body;
        if (!root || !body) return;
        const actual = [root.style.getPropertyValue('color-scheme'), root.style.getPropertyPriority('color-scheme')];
        if (owner !== root || !applied || actual[0] !== applied[0] || actual[1] !== applied[1]) original = actual;
        owner = root;
        if (forced.matches) {
          if (applied && actual[0] === applied[0] && actual[1] === applied[1]) {
            if (original[0]) root.style.setProperty('color-scheme', ...original);
            else root.style.removeProperty('color-scheme');
          }
          applied = null;
          return;
        }
        // WhatsApp can choose a different theme from Relay or macOS. Opt its native
        // scrollbars/controls into that theme, including on WebKit versions without
        // scrollbar-color support. Inline properties also work with a strict style CSP.
        let scheme = null;
        for (const el of [body, root]) {
          const theme = el.getAttribute('data-theme');
          if (theme === 'dark' || theme === 'light') { scheme = theme; break; }
          if (el.classList.contains('dark')) { scheme = 'dark'; break; }
          if (el.classList.contains('light')) { scheme = 'light'; break; }
        }
        if (!scheme) {
          for (const el of [body, root]) {
            const rgb = getComputedStyle(el).backgroundColor.match(/^rgba?\(([^)]+)\)$/)?.[1].split(/[,\s/]+/).map(Number);
            if (!rgb || rgb.length < 3 || (rgb.length > 3 && rgb[3] < 1)) continue;
            scheme = (.2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2]) < 128 ? 'dark' : 'light';
            break;
          }
        }
        scheme ??= preference.matches ? 'dark' : 'light';
        if (actual[0] !== scheme || actual[1] !== 'important') root.style.setProperty('color-scheme', scheme, 'important');
        applied = [scheme, 'important'];
      }
      function schedule() { if (!queued) { queued = true; setTimeout(update, 80); } }
      new MutationObserver(changes => {
        if (changes.some(change => change.target === document.documentElement || change.target === document.body || !owner?.isConnected)) schedule();
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'data-theme'] });
      for (const event of ['DOMContentLoaded', 'load', 'pageshow']) addEventListener(event, schedule);
      preference.addEventListener('change', schedule);
      forced.addEventListener('change', schedule);
      window.__relayWhatsAppChrome = { refresh: schedule };
      schedule();
    })();
    """;
}
