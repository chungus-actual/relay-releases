using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private readonly DispatcherTimer mediaTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private CoreWebView2? mediaCore;
    private ServiceState? mediaService;
    private bool mediaPolling, mediaPlaying;
    private int mediaGeneration;
    private sealed record MediaReading(bool Playing, bool Available, bool Video, bool Previous, bool Next, string Title, string Artist);
    private static readonly JsonSerializerOptions MediaJsonOptions = new() { PropertyNameCaseInsensitive = true };
    private static bool MusicService(ServiceState state) => state.Definition.IconId is "youtube" or "youtubemusic" or "spotify" or "bandcamp";

    private const string MediaBridgeScript = """
        (() => {
          if (window.__relayMedia) return;
          const provider = "__RELAY_PROVIDER__";
          const musicProvider = ['spotify', 'youtube', 'youtubemusic', 'bandcamp'].includes(provider);
          // Keep eligibility tied to the media source, so replacing a clip clears prior intent.
          const accepted = new WeakMap(), interacted = new WeakMap();
          const source = item => item.srcObject || item.getAttribute('src') || item.currentSrc;
          const userPlay = item => {
            if (navigator.userActivation?.isActive && !item.autoplay && !item.loop) interacted.set(item, source(item));
          };
          for (const eventName of ['pointerdown', 'keydown']) document.addEventListener(eventName, event => {
            if (!event.isTrusted || (eventName === 'keydown' && ![' ', 'Enter'].includes(event.key))) return;
            const item = event.target?.closest?.('audio,video');
            if (item) interacted.set(item, source(item));
          }, true);
          if (!musicProvider) {
            const saved = new WeakMap(), observed = new WeakSet();
            const proto = HTMLMediaElement.prototype, play = proto.play, load = proto.load;
            const observe = item => {
              if (observed.has(item)) return;
              observed.add(item);
              item.addEventListener('ended', () => {
                if (item.tagName !== 'AUDIO' || item.controls || item.loop || item.srcObject
                    || !(item.duration > 0 && item.duration < 10) || navigator.mediaSession?.metadata
                    || !item.hasAttribute('src')) return;
                saved.set(item, item.getAttribute('src'));
                item.removeAttribute('src'); load.call(item);
              });
            };
            proto.play = function(...args) {
              observe(this); userPlay(this);
              if (saved.has(this)) {
                if (!this.hasAttribute('src')) this.setAttribute('src', saved.get(this));
                saved.delete(this);
              }
              return play.apply(this, args);
            };
            proto.load = function(...args) { saved.delete(this); return load.apply(this, args); };
            document.addEventListener('play', event => { if (event.target instanceof HTMLMediaElement) { observe(event.target); userPlay(event.target); } }, true);
          }
          const eligible = item => {
            if (item.ended || item.error) return false;
            if (musicProvider) return true;
            if (!(item.tagName === 'VIDEO' || item.controls || item.duration >= 10)) return false;
            const key = source(item);
            if (!key) return false;
            // WebKit may still have no played range when a newly accepted player is
            // paused immediately. Retain that source's eligibility for resume.
            if (accepted.get(item) !== key && !(!item.paused && item.readyState >= 2) && !item.played.length) return false;
            // Marketing loops and silent previews are not user playback. Once accepted,
            // a real player remains resumable when it is subsequently paused or muted.
            if ((item.muted || item.volume === 0) && !item.controls && !item.srcObject
                && interacted.get(item) !== key && accepted.get(item) !== key) return false;
            accepted.set(item, key);
            return true;
          };
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
            const candidates = items.filter(eligible);
            return candidates.find(x => !x.paused) || candidates.find(x => x.currentSrc || x.srcObject);
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
            if (provider === 'youtube') return {
              play: document.querySelector('.ytp-play-button'), previous: document.querySelector('.ytp-prev-button'),
              next: document.querySelector('.ytp-next-button'), title: document.querySelector('h1.ytd-watch-metadata,.ytp-title-link')?.textContent?.trim()
            };
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
              const playing = item ? !item.paused && !item.ended : musicProvider && (session?.playbackState === 'playing' || domPlaying);
              return { playing, video: item?.tagName === 'VIDEO', available: !!item || (musicProvider && ((session?.playbackState !== 'none' && !!meta) || (!!ui.play && !!ui.title))),
                previous: handlers.has('previoustrack') || usable(ui.previous), next: handlers.has('nexttrack') || usable(ui.next),
                title: (meta?.title || ui.title || document.title || '').slice(0, 160),
                artist: (meta?.artist || '').slice(0, 100) };
            },
            async act(action) {
              if (action === 'dock') {
                document.getElementById('__relayFloatingStyle')?.remove();
                document.querySelectorAll('[data-relay-floating]').forEach(x => x.removeAttribute('data-relay-floating'));
                document.querySelectorAll('[data-relay-floating-parent]').forEach(x => x.removeAttribute('data-relay-floating-parent'));
                return true;
              }
              if (action === 'float') {
                const item = media();
                if (item?.tagName === 'VIDEO' && item.ownerDocument === document) {
                  item.setAttribute('data-relay-floating', '');
                  for (let parent = item.parentElement; parent && parent !== document.body; parent = parent.parentElement) parent.setAttribute('data-relay-floating-parent', '');
                  if (!document.getElementById('__relayFloatingStyle')) {
                    const style = document.createElement('style'); style.id = '__relayFloatingStyle';
                    style.textContent = 'html,body { margin:0!important; background:black!important; overflow:hidden!important } body * { visibility:hidden!important } [data-relay-floating-parent] { display:contents!important; transform:none!important; contain:none!important; overflow:visible!important } [data-relay-floating] { visibility:visible!important; position:fixed!important; inset:0!important; width:100vw!important; height:100vh!important; max-width:none!important; max-height:none!important; object-fit:contain!important; background:black!important; z-index:2147483647!important }';
                    document.documentElement.append(style);
                  }
                }
                return true;
              }
              if (!['play', 'pause', 'previoustrack', 'nexttrack'].includes(action) || !this.read().available) return false;
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
        """;

    private void InitializeMedia()
    {
        InitializeTaskbarMedia();
        mediaTimer.Tick += async (_, _) => await RefreshMedia();
    }

    private async Task ConfigureMedia(CoreWebView2 core, ServiceState state)
    {
        await core.AddScriptToExecuteOnDocumentCreatedAsync(MediaBridgeScript.Replace("__RELAY_PROVIDER__", state.Definition.IconId));
        core.IsDocumentPlayingAudioChanged += (_, _) =>
        {
            RefreshRail();
            if (quitting || !state.Options.Enabled || !AccountViews(state).Any(v => ServiceState.TryCore(v) == core)) return;
            if (core.IsDocumentPlayingAudio) { mediaGeneration++; mediaCore = core; mediaService = state; }
            mediaTimer.Start(); _ = RefreshMedia();
        };
        core.NavigationStarting += (_, _) => { mediaGeneration++; if (floatingCore == core) DockMedia(); if (mediaCore == core) ClearMedia(); };
        core.NavigationCompleted += (_, _) => { if (!quitting && state.Options.Enabled && AccountViews(state).Any(v => ServiceState.TryCore(v) == core)) mediaTimer.Start(); };
    }

    private void ClearMedia()
    {
        mediaGeneration++; mediaCore = null; mediaService = null; mediaPlaying = false;
        if (!services.Any(s => s.Options.Enabled && !s.Definition.IsTerminal && s.Core != null)) mediaTimer.Stop();
        MediaTitle.Text = ""; MediaControls.ToolTip = null;
        MediaControls.Visibility = Visibility.Collapsed; RefreshCaptionLayout(); RefreshTaskbarMedia();
    }

    private async Task RefreshMedia()
    {
        if (mediaPolling || quitting) return;
        mediaPolling = true;
        int generation = mediaGeneration;
        try
        {
            var candidates = services.Where(s => s.Options.Enabled && !s.Definition.IsTerminal)
                .SelectMany(s => AccountViews(s).Select(view => (State: s, Core: ServiceState.TryCore(view))))
                .Where(item => item.Core != null && !(item.State.Suspended && item.Core == item.State.Core))
                .OrderByDescending(item => item.Core!.IsDocumentPlayingAudio)
                .ThenByDescending(item => item.Core == mediaCore).ToArray();
            if (candidates.Length == 0) { ClearMedia(); mediaTimer.Stop(); return; }
            (ServiceState State, CoreWebView2 Core, MediaReading Data)? chosen = null;
            foreach (var candidate in candidates)
            {
                string result;
                try { result = await candidate.Core!.ExecuteScriptAsync("window.__relayMedia?.read() ?? null"); }
                catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { continue; }
                if (generation != mediaGeneration || quitting) return;
                if (!candidate.State.Options.Enabled || !AccountViews(candidate.State).Any(v => ServiceState.TryCore(v) == candidate.Core)) continue;
                var reading = JsonSerializer.Deserialize<MediaReading>(result, MediaJsonOptions);
                if (reading == null || (!reading.Playing && !reading.Available)) continue;
                if (reading.Playing) { chosen = (candidate.State, candidate.Core!, reading); break; }
                if (chosen == null || candidate.Core == mediaCore) chosen = (candidate.State, candidate.Core!, reading);
            }
            if (chosen is not { } active) { ClearMedia(); return; }
            var data = active.Data;
            bool playing = data.Playing;
            mediaCore = active.Core; mediaService = active.State; mediaPlaying = playing;
            MediaControls.Visibility = Visibility.Visible;
            MediaPlayButton.Content = playing ? "\uE769" : "\uE768";
            MediaPlayButton.ToolTip = playing ? "Pause" : "Play";
            System.Windows.Automation.AutomationProperties.SetName(MediaPlayButton, playing ? "Pause" : "Play");
            MediaFloatButton.IsEnabled = active.Core == active.State.Core;
            MediaPreviousButton.IsEnabled = data.Previous;
            MediaNextButton.IsEnabled = data.Next;
            MediaTitle.Text = data.Title;
            MediaControls.ToolTip = string.IsNullOrEmpty(data.Artist) ? data.Title : data.Title + " · " + data.Artist;
            RefreshTaskbarMedia();
            RefreshFloatingMedia();
            RefreshCaptionLayout();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException or JsonException)
        { if (generation == mediaGeneration) ClearMedia(); }
        finally { mediaPolling = false; }
    }

    private async Task MediaAction(string action)
    {
        var core = mediaCore;
        if (core == null || mediaService == null || !mediaService.Options.Enabled ||
            !AccountViews(mediaService).Any(v => ServiceState.TryCore(v) == core)) { ClearMedia(); return; }
        try
        {
            var expression = "window.__relayMedia?.act(" + JsonSerializer.Serialize(action) + ")";
            await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new { expression, userGesture = true, awaitPromise = true }));
            await RefreshMedia();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { ClearMedia(); }
    }

    private async void MediaPlayClick(object sender, RoutedEventArgs e) => await MediaAction(mediaPlaying ? "pause" : "play");
    private async void MediaPreviousClick(object sender, RoutedEventArgs e) => await MediaAction("previoustrack");
    private async void MediaNextClick(object sender, RoutedEventArgs e) => await MediaAction("nexttrack");
}
