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
    private sealed record MediaReading(bool Playing, bool Available, bool Previous, bool Next, string Title, string Artist);
    private static readonly JsonSerializerOptions MediaJsonOptions = new() { PropertyNameCaseInsensitive = true };
    private static bool MusicService(ServiceState state) => state.Definition.IconId is "youtubemusic" or "spotify" or "bandcamp";

    private const string MediaBridgeScript = """
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
        """;

    private void InitializeMedia()
    {
        mediaTimer.Tick += async (_, _) => await RefreshMedia();
    }

    private async Task ConfigureMedia(CoreWebView2 core, ServiceState state)
    {
        if (!MusicService(state)) return;
        await core.AddScriptToExecuteOnDocumentCreatedAsync(MediaBridgeScript.Replace("__RELAY_PROVIDER__", state.Definition.IconId));
        core.IsDocumentPlayingAudioChanged += (_, _) =>
        {
            if (quitting || !state.Options.Enabled || !AccountViews(state).Any(v => ServiceState.TryCore(v) == core)) return;
            if (core.IsDocumentPlayingAudio) { mediaGeneration++; mediaCore = core; mediaService = state; }
            mediaTimer.Start(); _ = RefreshMedia();
        };
        core.NavigationStarting += (_, _) => { if (mediaCore == core) ClearMedia(); };
        core.NavigationCompleted += (_, _) => { if (!quitting && state.Options.Enabled && AccountViews(state).Any(v => ServiceState.TryCore(v) == core)) mediaTimer.Start(); };
    }

    private void ClearMedia()
    {
        mediaGeneration++; mediaCore = null; mediaService = null;
        if (!services.Any(s => s.Options.Enabled && MusicService(s))) mediaTimer.Stop();
        MediaTitle.Text = ""; MediaControls.ToolTip = null;
        MediaControls.Visibility = Visibility.Collapsed; RefreshCaptionLayout();
    }

    private async Task RefreshMedia()
    {
        if (mediaPolling || quitting) return;
        mediaPolling = true;
        int generation = mediaGeneration;
        try
        {
            var candidates = services.Where(s => s.Options.Enabled && MusicService(s))
                .SelectMany(s => AccountViews(s).Select(view => (State: s, Core: ServiceState.TryCore(view))))
                .Where(item => item.Core != null)
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
            MediaPreviousButton.IsEnabled = data.Previous;
            MediaNextButton.IsEnabled = data.Next;
            MediaTitle.Text = data.Title;
            MediaControls.ToolTip = string.IsNullOrEmpty(data.Artist) ? data.Title : data.Title + " · " + data.Artist;
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
