import Foundation

struct MediaReading: Equatable {
    let playing: Bool
    let available: Bool
    let previous: Bool
    let next: Bool
    let title: String
    let artist: String

    init?(value: Any) {
        guard let data = value as? [String: Any],
              let playing = data["playing"] as? Bool, let available = data["available"] as? Bool,
              let previous = data["previous"] as? Bool, let next = data["next"] as? Bool,
              let title = data["title"] as? String, let artist = data["artist"] as? String else { return nil }
        self.playing = playing; self.available = available; self.previous = previous; self.next = next
        self.title = String(title.prefix(160)); self.artist = String(artist.prefix(100))
    }
}

enum MediaAction: String { case play, pause, previous = "previoustrack", next = "nexttrack" }

enum MediaBridge {
    static func supports(_ serviceID: String) -> Bool { ["spotify", "youtubemusic", "bandcamp"].contains(serviceID) }
    static func script(for serviceID: String) -> String {
        guard supports(serviceID) else { return "" }
        return template.replacingOccurrences(of: "__RELAY_PROVIDER__", with: serviceID)
    }
    static let template = #"""
(() => {
  if (window.__relayMedia) return;
  const provider = "__RELAY_PROVIDER__";
  const handlers = new Map();
  const session = navigator.mediaSession;
  if (session) {
    const set = session.setActionHandler.bind(session);
    session.setActionHandler = (action, handler) => {
      set(action, handler);
      if (handler) handlers.set(action, handler); else handlers.delete(action);
    };
  }
  const media = () => {
    const items = [...document.querySelectorAll('audio,video')];
    for (const frame of document.querySelectorAll('iframe')) {
      try { items.push(...frame.contentDocument.querySelectorAll('audio,video')); } catch {}
    }
    return items.find(x => !x.paused && !x.ended) || items.find(x => x.currentSrc && !x.ended);
  };
  const controls = () => {
    if (provider === 'spotify') return {
      play: document.querySelector('[data-testid="control-button-playpause"]'),
      previous: document.querySelector('[data-testid="control-button-skip-back"]'),
      next: document.querySelector('[data-testid="control-button-skip-forward"]'),
      title: document.querySelector('[data-testid="context-item-info-title"],[data-testid="nowplaying-track-link"]')?.textContent?.trim()
    };
    if (provider === 'youtubemusic') {
      const bar = document.querySelector('ytmusic-player-bar');
      return { play: bar?.querySelector('#play-pause-button'), previous: bar?.querySelector('.previous-button'),
        next: bar?.querySelector('.next-button'), title: bar?.querySelector('.title')?.textContent?.trim() };
    }
    if (provider === 'bandcamp') return {
      play: document.querySelector('.inline_player .playbutton,.playbutton'),
      previous: document.querySelector('.inline_player .prevbutton'), next: document.querySelector('.inline_player .nextbutton'),
      title: document.querySelector('.track_info .title')?.textContent?.trim()
    };
    return {};
  };
  const usable = button => !!button && !button.disabled && button.getAttribute('aria-disabled') !== 'true';
  window.__relayMedia = {
    read() {
      const item = media(), meta = session?.metadata, ui = controls();
      const domPlaying = /pause/i.test(ui.play?.getAttribute('aria-label') || ui.play?.title || '')
        || (provider === 'bandcamp' && !!ui.play?.classList.contains('playing'));
      const playing = item ? !item.paused && !item.ended : session?.playbackState === 'playing' || domPlaying;
      return { playing, available: !!item || (session?.playbackState !== 'none' && !!meta) || (!!ui.play && !!ui.title),
        previous: handlers.has('previoustrack') || usable(ui.previous), next: handlers.has('nexttrack') || usable(ui.next),
        title: (meta?.title || ui.title || document.title || '').slice(0, 160),
        artist: (meta?.artist || '').slice(0, 100) };
    },
    async act(action) {
      const handler = handlers.get(action);
      if (handler) { await handler({ action }); return true; }
      const item = media();
      if (item && action === 'play') { await item.play(); return true; }
      if (item && action === 'pause') { item.pause(); return true; }
      const ui = controls();
      const button = action === 'nexttrack' ? ui.next : action === 'previoustrack' ? ui.previous : ui.play;
      if (usable(button)) { button.click(); return true; }
      return false;
    }
  };
})();
"""#
}
