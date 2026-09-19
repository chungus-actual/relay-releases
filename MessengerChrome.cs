namespace Relay;

public partial class MainWindow
{
    // Facebook sometimes gives the banner a zero-height wrapper around fixed, separate nav sections.
    private const string MessengerChromeScript = """
    (() => {
      if (window !== window.top) return;
      if (window.__relayMessengerChrome) { window.__relayMessengerChrome.refresh(); return; }
      const adjusted = new Map(), applied = new Map(), hidden = new Map();
      let queued = false, headerHeight = 0;
      const enabled = () => (location.hostname === 'facebook.com' || location.hostname.endsWith('.facebook.com')) && /^\/messages(?:\/|$)/.test(location.pathname);
      const remember = (el, key, value) => {
        if (!adjusted.has(el)) adjusted.set(el, new Map());
        const props = adjusted.get(el);
        if (!props.has(key)) props.set(key, [el.style.getPropertyValue(key), el.style.getPropertyPriority(key)]);
        if (el.style.getPropertyValue(key) !== value || el.style.getPropertyPriority(key) !== 'important') el.style.setProperty(key, value, 'important');
        if (!applied.has(el)) applied.set(el, new Map());
        applied.get(el).set(key, [el.style.getPropertyValue(key), el.style.getPropertyPriority(key)]);
      };
      const restore = () => {
        for (const [el, props] of adjusted) for (const [key, [value, priority]] of props) {
          if (value) el.style.setProperty(key, value, priority); else el.style.removeProperty(key);
        }
        adjusted.clear(); applied.clear(); hidden.clear(); headerHeight = 0;
        document.documentElement?.removeAttribute('data-relay-messenger');
      };
      const observe = () => observer.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['role', 'aria-label', 'class', 'style', 'hidden'] });
      function update() {
        queued = false; observer.disconnect();
        try {
          if (!document.documentElement) return;
          // React reuses panes between chats. Re-measure their natural layout every time,
          // keeping any inline changes the site made since our previous adjustment.
          for (const [el, props] of adjusted) for (const [key] of props) {
            const actual = [el.style.getPropertyValue(key), el.style.getPropertyPriority(key)];
            const ours = applied.get(el)?.get(key);
            if (ours && (actual[0] !== ours[0] || actual[1] !== ours[1])) props.set(key, actual);
          }
          restore();
          if (!enabled()) return;
          const banners = [...document.querySelectorAll('[role="banner"], header, [role="navigation"][aria-label="Facebook"]')].filter(el => !el.closest('[role="main"],[role="dialog"]'));
          for (const banner of banners) {
            // Measure the visible children too: position:fixed children do not size their parent.
            const pieces = [banner, ...banner.querySelectorAll('*')].slice(0, 250);
            const tops = pieces.map(el => el.getBoundingClientRect()).filter(r => r.top >= -1 && r.top <= 8 && r.bottom >= 24 && r.bottom <= 120 && r.width >= 24);
            if (!tops.length) continue;
            hidden.set(banner, true);
            headerHeight = Math.max(headerHeight, ...tops.map(r => r.bottom));
          }
          if (!hidden.size) return;
          const candidates = new Set([document.body]);
          for (const main of document.querySelectorAll('[role="main"],[role="navigation"],[role="complementary"]')) {
            if ([...hidden.keys()].some(banner => banner === main || banner.contains(main))) continue;
            let el = main;
            for (let depth = 0; el && el !== document.documentElement && depth < 10; depth++, el = el.parentElement) candidates.add(el);
          }
          // Read geometry before hiding the banner or changing header variables.
          for (const el of candidates) {
            if (!el || hidden.has(el)) continue;
            const rect = el.getBoundingClientRect(), style = getComputedStyle(el);
            const atHeader = value => Math.abs(parseFloat(value) - headerHeight) <= 2;
            if (['fixed', 'absolute'].includes(style.position) && (atHeader(style.top) || Math.abs(rect.top - headerHeight) <= 2) && Math.abs(rect.bottom - innerHeight) <= 5) {
              remember(el, 'top', '0px'); remember(el, 'height', '100vh');
            }
            if (atHeader(style.paddingTop)) remember(el, 'padding-top', '0px');
            if (atHeader(style.marginTop)) remember(el, 'margin-top', '0px');
          }
          for (const banner of hidden.keys()) remember(banner, 'display', 'none');
          for (const key of ['--header-height', '--header-height-fb', '--header-height-fb-desktop']) remember(document.documentElement, key, '0px');
          // Some inner panes keep calc(100vh - 56px) even after their parent's header offset is gone.
          // Only grow near-full-height panes whose remaining bottom gap matches that removed header.
          const panes = new Set(candidates);
          for (const x of [.02, .15, .5, .85, .98]) for (const y of [4, 20, innerHeight - headerHeight - 20]) {
            let el = document.elementFromPoint(innerWidth * x, Math.max(0, y));
            for (let depth = 0; el && el !== document.documentElement && depth < 14; depth++, el = el.parentElement) panes.add(el);
          }
          const grows = [];
          for (const el of panes) {
            if (!el || el === document.body || hidden.has(el) || [...hidden.keys()].some(banner => banner.contains(el))) continue;
            const rect = el.getBoundingClientRect(), bottomInset = innerHeight - rect.bottom - headerHeight;
            if (rect.top >= -1 && rect.top <= 40 && rect.height >= innerHeight * .45 && bottomInset >= -2 && bottomInset <= 32) {
              const inset = Math.max(0, rect.top) + Math.max(0, bottomInset);
              grows.push([el, inset]);
            }
          }
          for (const [el, inset] of grows) {
            const height = 'calc(100dvh - ' + inset + 'px)';
            remember(el, 'height', height);
            remember(el, 'max-height', height);
          }
          document.documentElement.setAttribute('data-relay-messenger', '');
        } finally { observe(); }
      }
      function schedule() { if (!queued) { queued = true; setTimeout(update, 80); } }
      const observer = new MutationObserver(schedule);
      observe();
      for (const method of ['pushState', 'replaceState']) {
        const original = history[method];
        history[method] = function(...args) { const value = original.apply(this, args); schedule(); return value; };
      }
      for (const event of ['popstate', 'resize', 'pageshow', 'DOMContentLoaded', 'load']) addEventListener(event, schedule);
      // Native scrolling invalidates WebKit's retained chat tiles; synthetic scroll
      // events alone do not. Coalesce activations and undo only our own movement.
      let activationQueued = false;
      const nudged = new Map();
      function restoreScroll() {
        for (const [pane, [original, moved]] of nudged) {
          if (pane.isConnected && pane.scrollTop === moved) pane.scrollTo({ top: original, behavior: 'instant' });
        }
        nudged.clear();
      }
      function activate() {
        if (document.visibilityState === 'hidden') { restoreScroll(); return; }
        if (activationQueued) return;
        activationQueued = true;
        requestAnimationFrame(() => requestAnimationFrame(() => {
          activationQueued = false;
          if (document.visibilityState === 'hidden' || !enabled()) return;
          restoreScroll();
          schedule();
          dispatchEvent(new Event('resize'));
          for (const pane of Array.from(document.querySelectorAll('[role="main"], [role="main"] *, [role="log"]')).slice(0, 1200)) {
            if (pane.clientHeight > 0 && pane.scrollHeight > pane.clientHeight &&
                /auto|scroll/.test(getComputedStyle(pane).overflowY)) {
              const original = pane.scrollTop;
              pane.scrollTo({ top: original + 1, behavior: 'instant' });
              if (pane.scrollTop === original) pane.scrollTo({ top: original - 1, behavior: 'instant' });
              if (pane.scrollTop !== original) nudged.set(pane, [original, pane.scrollTop]);
            }
          }
          requestAnimationFrame(restoreScroll);
        }));
      }
      document.addEventListener('visibilitychange', activate);
      window.__relayMessengerChrome = { refresh: schedule, activate };
      schedule();
    })();
    """;
}
