using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace Relay;

public partial class MainWindow
{
    private sealed class UpdateFixture(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); return Task.FromResult(response(request));
        }
    }

    private async Task CheckUpdatesAndMusic(string output)
    {
        async Task RefreshFixtureMedia()
        {
            // A timer poll can still be awaiting WebView2 when a fixture changes.
            // Wait for it before requesting the reading asserted by this test.
            mediaTimer.Stop();
            await Until(() => !mediaPolling);
            await RefreshMedia();
        }
        var package = Encoding.UTF8.GetBytes("verified fixture");
        string hash = Convert.ToHexString(SHA256.HashData(package));
        string name = "Relay-9.0.0-win-x64.zip";
        var source = "https://github.com/" + ReleaseUpdates.Repository + "/releases/download/v9.0.0/";
        string manifest = hash + "  " + name;
        int declaredSize = package.Length;
        string assetSource = source, tag = "v9.0.0";
        bool prerelease = false;
        using var http = new HttpClient(new UpdateFixture(request =>
        {
            string body = JsonSerializer.Serialize(new { tag_name = tag, draft = false, prerelease,
                assets = new[] { new { name, size = declaredSize, browser_download_url = assetSource + name },
                    new { name = "SHA256SUMS.txt", size = 100, browser_download_url = source + "SHA256SUMS.txt" },
                    new { name = "Relay-16.zip", size = 100, browser_download_url = source + "Relay-16.zip" },
                    new { name = "appcast.xml", size = 100, browser_download_url = source + "appcast.xml" } } });
            return new HttpResponseMessage(HttpStatusCode.OK) { Content =
                request.RequestUri == ReleaseUpdates.LatestUrl ? new StringContent(body) :
                request.RequestUri!.AbsolutePath.EndsWith("SHA256SUMS.txt") ? new StringContent(manifest) : new ByteArrayContent(package) };
        }));
        var updates = new ReleaseUpdates(http);
        var release = await updates.CheckAsync(new Version(1, 0, 0), false, CancellationToken.None);
        Check(release?.Version == new Version(9, 0, 0), "Shared release selects the Windows portable package despite macOS assets");
        Check(await updates.CheckAsync(new Version(9, 0, 0), false, CancellationToken.None) == null, "Updater never reinstalls the current version");
        Check(await updates.CheckAsync(new Version(10, 0, 0), false, CancellationToken.None) == null, "Updater never downgrades");
        prerelease = true;
        Check(await updates.CheckAsync(new Version(1, 0, 0), false, CancellationToken.None) == null, "Automatic updates skip prereleases");
        prerelease = false;
        async Task Reject(Func<Task> run, string check)
        {
            bool failed = false; try { await run(); } catch (InvalidDataException) { failed = true; }
            Check(failed, check);
        }
        assetSource = "https://attacker.test/";
        await Reject(async () => { await updates.CheckAsync(new Version(1, 0, 0), false, CancellationToken.None); }, "Updater rejects a different download origin");
        assetSource = source;
        var directory = Path.Combine(App.DataPath, "update-fixture");
        Check(await updates.DownloadAsync(release!, directory, null, CancellationToken.None) == hash, "Updater verifies the downloaded SHA256");
        Check(File.ReadAllBytes(Path.Combine(directory, name)).SequenceEqual(package), "Verified update contents survive download");
        manifest = new string('0', 64) + "  " + name;
        await Reject(async () => { await updates.DownloadAsync(release!, directory + "-bad", null, CancellationToken.None); }, "Bad checksums cannot stage an update");
        Check(!Directory.EnumerateFiles(directory + "-bad").Any(), "Failed update removes its partial download");
        manifest = hash + "  " + name;
        await Reject(async () => { await updates.DownloadAsync(release! with { Size = package.Length + 1 }, directory + "-short", null, CancellationToken.None); }, "Truncated update cannot stage");
        await Reject(() => { ReleaseUpdates.ExpectedHash(manifest + "\n" + manifest, name); return Task.CompletedTask; }, "Ambiguous checksum manifests are rejected");
        Check((LocalBuild || App.SmokeTest) && updateHash == null, "Local and smoke builds do not self-update");

        foreach (var id in new[] { "youtubemusic", "spotify", "bandcamp" })
        {
            var state = services.Single(s => s.Definition.Id == id);
            Check(!state.Options.Enabled && MusicService(state), id + " starts disconnected");
            Check(!state.Definition.Owns(state.Definition.Url.Replace(".com", ".com.attacker.test")), id + " origin boundary");
            await SelectService(state); await Until(() => state.Unread == 3);
            Check(state.Core!.Profile.ProfileName == id, id + " has its own profile");
        }
        var spotify = services.Single(s => s.Definition.Id == "spotify");
        await spotify.Core!.ExecuteScriptAsync("""
            navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none';
            document.body.innerHTML='<a data-testid="context-item-info-title">DOM fixture track</a><button data-testid="control-button-playpause" aria-label="Pause"></button><button data-testid="control-button-skip-forward"></button>';
            document.querySelector('[data-testid="control-button-playpause"]').onclick = function() {
              this.setAttribute('aria-label', this.getAttribute('aria-label') === 'Pause' ? 'Play' : 'Pause');
            };
            """);
        ClearMedia(); await RefreshFixtureMedia();
        Check(!spotify.Core.IsDocumentPlayingAudio && mediaService == spotify && mediaPlaying && MediaTitle.Text == "DOM fixture track",
            "Spotify page controls surface playback and title without audio or MediaSession signals");
        await MediaAction("pause");
        await RefreshFixtureMedia();
        Check(!mediaPlaying && await spotify.Core.ExecuteScriptAsync("document.querySelector('[data-testid=\"control-button-playpause\"]').getAttribute('aria-label')") == "\"Play\"",
            "Spotify DOM fallback controls the background player");
        await spotify.Core.ExecuteScriptAsync("document.body.replaceChildren()");
        var music = services.Single(s => s.Definition.Id == "youtubemusic");
        await SelectService(music);
        var core = music.Core!;
        await core.ExecuteScriptAsync("""
            window.mediaCalls = [];
            navigator.mediaSession.metadata = new MediaMetadata({title:'Fixture track', artist:'Relay'});
            navigator.mediaSession.playbackState = 'playing';
            for (const action of ['play','pause','nexttrack','previoustrack']) {
              navigator.mediaSession.setActionHandler(action, () => {
                window.mediaCalls.push(action);
                if (action === 'play' || action === 'pause') navigator.mediaSession.playbackState = action === 'play' ? 'playing' : 'paused';
              });
            }
            """);
        ClearMedia(); await RefreshFixtureMedia();
        Check(!core.IsDocumentPlayingAudio && MediaControls.Visibility == Visibility.Visible && mediaPlaying, "MediaSession playback exposes controls even without an audible WebView signal");
        core.IsMuted = true;
        await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression = """
                (async () => {
                  const buffer = new ArrayBuffer(44 + 16000), d = new DataView(buffer);
                  const text = (p,s) => [...s].forEach((c,i)=>d.setUint8(p+i,c.charCodeAt(0)));
                  text(0,'RIFF'); d.setUint32(4,16036,true); text(8,'WAVE'); text(12,'fmt ');
                  d.setUint32(16,16,true); d.setUint16(20,1,true); d.setUint16(22,1,true);
                  d.setUint32(24,8000,true); d.setUint32(28,16000,true); d.setUint16(32,2,true); d.setUint16(34,16,true);
                  text(36,'data'); d.setUint32(40,16000,true);
                  for(let i=0;i<8000;i++) d.setInt16(44+i*2,Math.sin(i*Math.PI*440/4000)*2000,true);
                  window.fixtureAudio = document.createElement('audio'); document.body.append(fixtureAudio);
                  fixtureAudio.src = URL.createObjectURL(new Blob([buffer],{type:'audio/wav'})); fixtureAudio.loop = true;
                  navigator.mediaSession.setActionHandler('play', async()=>{mediaCalls.push('play'); await fixtureAudio.play();});
                  navigator.mediaSession.setActionHandler('pause', ()=>{mediaCalls.push('pause'); fixtureAudio.pause();});
                  await fixtureAudio.play();
                })()
                """,
            userGesture = true, awaitPromise = true
        }));
        await Until(() => core.IsDocumentPlayingAudio);
        await RefreshFixtureMedia();

        Check(MediaControls.Visibility == Visibility.Visible && mediaPlaying && MediaNextButton.IsEnabled, "Playing media exposes title-bar transport controls");
        Check(MediaTitle.Text == "Fixture track" && MediaTitle.Visibility == Visibility.Visible, "Playing media exposes its current title");
        await core.ExecuteScriptAsync("navigator.mediaSession.metadata = new MediaMetadata({title:'Next fixture track',artist:'Relay'})");
        await RefreshFixtureMedia();
        Check(MediaTitle.Text == "Next fixture track", "Media title follows track changes");
        await SelectService(services[0]);
        await MediaAction("pause");
        await RefreshFixtureMedia();
        Check(!mediaPlaying && MediaControls.Visibility == Visibility.Visible, "Background music pauses and keeps a resume button");
        await MediaAction("play"); await MediaAction("nexttrack"); await MediaAction("previoustrack");
        Check(await core.ExecuteScriptAsync("JSON.stringify(window.mediaCalls)") == "\"[\\\"pause\\\",\\\"play\\\",\\\"nexttrack\\\",\\\"previoustrack\\\"]\"", "Transport controls target the playing account while viewing a different service");
        await core.ExecuteScriptAsync("navigator.mediaSession.setActionHandler('nexttrack', null)");
        await RefreshFixtureMedia();
        Check(!MediaNextButton.IsEnabled, "Unavailable track skipping is disabled");
        var slider = CreateZoomSlider(music); slider.Value = 125;
        Check(music.View!.ZoomFactor == 1.25 && services[0].Options.Zoom != 1.25, "Zoom slider changes only its own account");
        Capture(Path.Combine(output, "music-titlebar.png"));
        Width = 720;
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        Check(MediaTitle.Text == "Next fixture track" && MediaControls.TranslatePoint(new Point(MediaControls.ActualWidth, 0), this).X <= WindowButtons.TranslatePoint(new Point(), this).X, "Media title and controls fit at minimum window width");
        Capture(Path.Combine(output, "music-titlebar-compact.png"));
        Width = 1280;
        var zoomHost = new System.Windows.Controls.ContextMenu();
        var zoomItem = CreateZoomMenu(music); zoomHost.Items.Add(zoomItem);
        zoomHost.PlacementTarget = railButtons[music.Definition.Id]; zoomHost.IsOpen = true; zoomItem.IsSubmenuOpen = true;
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        Check(zoomItem.Items[0] is System.Windows.Controls.MenuItem { Header: System.Windows.Controls.StackPanel }, "Service context menu exposes the zoom slider");
        CaptureElement((System.Windows.Controls.StackPanel)((System.Windows.Controls.MenuItem)zoomItem.Items[0]).Header, Path.Combine(output, "zoom-slider.png"));
        zoomHost.IsOpen = false;
        double previousZoom = selected!.Options.Zoom;
        Check(HandleZoomKey(System.Windows.Input.Key.OemPlus, System.Windows.Input.ModifierKeys.Control), "Ctrl plus zooms in");
        Check(selected.Options.Zoom == Math.Round(previousZoom + 0.1, 2), "Keyboard zoom changes selected account");
        HandleZoomKey(System.Windows.Input.Key.Subtract, System.Windows.Input.ModifierKeys.Control);
        Check(selected.Options.Zoom == previousZoom && Settings.Load().Services[selected.Definition.Id].Zoom == previousZoom, "Ctrl minus zooms out and persists");
        var drm = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression = "navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4; codecs=\"mp4a.40.2\"'}]}]).then(()=> 'supported', e=>e.name)",
            awaitPromise = true, returnByValue = true }));
        File.WriteAllText(Path.Combine(output, "widevine-probe.json"), drm);
        foreach (var state in services.Where(MusicService)) DisconnectService(state);
        await RefreshFixtureMedia();
        Check(MediaControls.Visibility == Visibility.Collapsed && !mediaTimer.IsEnabled, "Disconnect removes playback controls and stops media polling");
        File.WriteAllText(Path.Combine(output, "update-music-checks.txt"), "PASS: release selection, downgrade/prerelease exclusion, download origin, checksum/size checks, failed staging cleanup, local-build exclusion, music profiles and controls, background play/pause/skip, account zoom, disconnect cleanup.\n");
    }
}
