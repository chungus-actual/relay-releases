using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task MediaTerminalSmokeTest()
    {
        string output = Path.Combine(Environment.CurrentDirectory, "artifacts"); Directory.CreateDirectory(output);
        string report = Path.Combine(output, "media-terminal-checks.txt"); File.WriteAllText(report, "RUNNING");
        try { await CheckMediaTerminal(output); Check(!File.Exists(Path.Combine(App.DataPath, "errors.log")), "No runtime errors during media/terminal checks"); File.WriteAllText(report, "PASS: shared native media regressions, retained service pop-outs and floating playback/dock/unload, audio indicators, embedded ConPTY input/output/resize, account-owned tabs, inline session renaming, nested splits, native focus/input, scoped close, isolation, navigation rejection, teardown, and all six titlebar/dropdown/menu/terminal themes."); }
        catch (Exception ex) { File.WriteAllText(report, "FAIL: " + ex); Environment.ExitCode = 1; }
        finally { quitting = true; Close(); }
    }
    private async Task CheckMediaTerminal(string output)
    {
        var service = services.First(s => s.Definition.IconId == "messenger");
        await SelectService(service); await Until(() => service.Status == "Live");
        var core = service.Core!;
        await core.ExecuteScriptAsync("document.body.replaceChildren(); navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none';");
        var fixture = File.ReadAllText(Path.Combine(Environment.CurrentDirectory, "Assets", "Fixtures", "media-playback-checks.js"));
        var result = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new { expression = fixture, userGesture = true, awaitPromise = true, returnByValue = true }));
        File.WriteAllText(Path.Combine(output, "media-playback-browser.json"), result);
        using (var json = JsonDocument.Parse(result)) {
            Check(!json.RootElement.TryGetProperty("exceptionDetails", out _), "Media browser fixture threw: " + result);
            Check(json.RootElement.GetProperty("result").GetProperty("value").GetProperty("failures").GetArrayLength() == 0, "Media browser regressions: " + result);
        }
        File.WriteAllText(Path.Combine(output, "media-terminal-progress.txt"), "Shared media passed; starting video\n");
        await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression = """
                (async()=>{
                  window.retainedMediaDocument='same-document';
                  const canvas=document.createElement('canvas');canvas.width=640;canvas.height=360;
                  const ctx=canvas.getContext('2d');ctx.fillStyle='#245d63';ctx.fillRect(0,0,640,360);
                  ctx.fillStyle='white';ctx.font='28px sans-serif';ctx.fillText('Relay floating video',170,175);
                  window.testVideo=document.createElement('video');testVideo.muted=true;testVideo.srcObject=canvas.captureStream(10);window.fixtureDraw=setInterval(()=>ctx.fillRect(0,350,640,10),40);
                  document.body.append(testVideo);await testVideo.play();
                })()
                """, userGesture = true, awaitPromise = true }));
        File.AppendAllText(Path.Combine(output, "media-terminal-progress.txt"), "Video started\n");
        await Until(() => !mediaPolling); await RefreshMedia();
        Check(mediaService == service && MediaFloatButton.IsEnabled, "Messaging video enables floating playback");
        var view = service.View!;
        File.AppendAllText(Path.Combine(output, "media-terminal-progress.txt"), "Floating\n");
        await FloatMedia(service);
        Check(floatingWindow != null && floatingWindow.Topmost && view.Parent == floatingHost, "Floating player owns the original native browser");
        var window = floatingWindow;
        var fullScreen = PlaceElements<System.Windows.Controls.Button>(window!).Single(b => Equals(b.Content, "Full screen"));
        fullScreen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        Check(window!.WindowState == WindowState.Maximized && window.WindowStyle == WindowStyle.None && view.Parent == floatingHost, "Fullscreen retains the floating browser");
        fullScreen.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        Check(window.WindowState == WindowState.Normal && window.WindowStyle == WindowStyle.SingleBorderWindow, "Fullscreen restores a movable window");
        MediaFloatClick(this, new RoutedEventArgs());
        Check(floatingWindow == window, "Repeated float click reuses the player");
        await SelectService(services.First(s => s.Definition.IconId == "gmail"));
        ShowActivity();
        Check(view.IsVisible && view.Parent == floatingHost, "Floating video stays visible across service and local-page switches");
        await FloatingAction();
        Check(await core.ExecuteScriptAsync("testVideo.paused") == "true", "Floating transport targets its own service");
        await FloatingAction();
        Check(await core.ExecuteScriptAsync("testVideo.paused") == "false", "Paused live video remains resumable in the floating player");
        await using (var image = File.Create(Path.Combine(output, "floating-video.png"))) await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image);
        DockMedia(); DockMedia();
        Check(view.Parent == WebHost && !view.IsVisible && await core.ExecuteScriptAsync("retainedMediaDocument") == "\"same-document\"", "Repeated dock restores the same document and respects the current page");
        await SelectService(service);
        Check(ServiceWindowActions(service).Select(i => (string)i.Header).SequenceEqual(new[] { "Pop out in Relay", "Open in default browser" }), "Web services offer a Relay window or the default browser");
        await PopOutService(service); var serviceChild = serviceWindows[service];
        Check(view.Parent == serviceChild.Host && !serviceChild.Window.Topmost && !settings.Workspace.Panes.Contains(service.Definition.Id), "Pop-out moves the existing web service out of the main layout");
        await PopOutService(service); await SelectService(service);
        Check(serviceWindows[service] == serviceChild && selected != service, "Repeated pop-out and service shortcut activate the same child");
        ShowActivity(); ArrangePanes(); RefreshPaneStatus();
        Check(view.IsVisible && view.Parent == serviceChild.Host && await core.ExecuteScriptAsync("retainedMediaDocument") == "\"same-document\"", "Local pages and layout updates retain the popped-out document");
        bool priorKeepLive = service.Options.KeepLive;
        service.Options.KeepLive = false; service.HiddenAt = DateTime.UtcNow.AddMinutes(-5);
        bool attemptedSuspend = false;
        await SuspendIdle(c => { if (c == core) attemptedSuspend = true; return Task.FromResult(false); });
        Check(!attemptedSuspend, "Visible pop-outs are excluded from idle suspension");
        service.Options.KeepLive = priorKeepLive;
        await FloatMedia(service);
        Check(!serviceWindows.ContainsKey(service) && view.Parent == floatingHost, "PiP takes ownership from a service pop-out without duplicating its view");
        await PopOutService(service);
        Check(floatingWindow == null && view.Parent == serviceWindows[service].Host, "Service pop-out takes ownership back from PiP");
        var dockButton = PlaceElements<System.Windows.Controls.Button>(serviceWindows[service].Window).Single(b => System.Windows.Automation.AutomationProperties.GetName(b) == "Dock in Relay");
        dockButton.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        await Until(() => selected == service && view.Parent == WebHost);
        Check(!serviceWindows.ContainsKey(service) && await core.ExecuteScriptAsync("retainedMediaDocument") == "\"same-document\"", "Closing a service child docks the original document");
        await PopOutService(service);
        DisconnectService(service);
        Check(!serviceWindows.ContainsKey(service), "Unloading a popped-out service closes its child before disposal");
        await SelectService(service); await FloatMedia(service);
        DisconnectService(service);
        Check(floatingWindow == null && service.View == null, "Unload tears down floating ownership before disposing the browser");

        File.AppendAllText(Path.Combine(output, "media-terminal-progress.txt"), "Floating passed; starting terminal\n");
        var terminal = services.Single(s => s.Definition.Id == "terminal");
        await SelectService(terminal);
        await SoloPane(terminal);
        await Until(() => terminalWorkspaces.GetValueOrDefault(terminal.Definition.Id)?.Current?.Panes.FirstOrDefault()?.Process != null);
        var workspace = terminalWorkspaces[terminal.Definition.Id];
        var firstTab = workspace.Current!; var firstPane = firstTab.Panes[0]; var first = firstPane.Process!; int firstPID = first.ProcessId;
        var terminalCore = terminal.Core!;
        int accountsBefore = settings.Accounts.Count, servicesBefore = services.Count;
        Check(firstPID != 0 && !first.Exited && terminalCore.Source == TerminalAddress, "Terminal service starts an embedded ConPTY shell");
        await terminalCore.ExecuteScriptAsync("window.fixtureOutput={}; chrome.webview.addEventListener('message',e=>{if(e.data.type==='output') fixtureOutput[e.data.pane]=(fixtureOutput[e.data.pane]||'')+e.data.data;});");
        string Output(TerminalPane pane, string text) => "(window.fixtureOutput[" + JsonSerializer.Serialize(pane.Id) + "]||'').includes(" + JsonSerializer.Serialize(text) + ")";
        Task<string> Message(object data) => terminalCore.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(data) + ")");
        Task<string> Click(string selector) => terminalCore.ExecuteScriptAsync("document.querySelector(" + JsonSerializer.Serialize(selector) + ").click()");
        async Task Key(string key, string code, int virtualKey, int modifiers = 0, string text = "") {
            await terminalCore.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new { type = "keyDown", key, code, windowsVirtualKeyCode = virtualKey, modifiers, text }));
            await terminalCore.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new { type = "keyUp", key, code, windowsVirtualKeyCode = virtualKey, modifiers }));
        }
        async Task EditName(string selector, string value, string action = "Enter") {
            await terminalCore.ExecuteScriptAsync("document.querySelector(" + JsonSerializer.Serialize(selector) + ").dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))");
            await WaitScript(terminalCore, "document.activeElement.matches('.session-name-input')");
            await terminalCore.ExecuteScriptAsync("document.activeElement.value=" + JsonSerializer.Serialize(value));
            await Key(action, action, action == "Enter" ? 13 : 27);
            await WaitScript(terminalCore, "!document.querySelector('.session-name-input')");
        }
        await Message(new { type = "input", pane = firstPane.Id, data = "$relayFixture=913; Write-Output ('RELAY_' + $relayFixture)\r" });
        await WaitScript(terminalCore, Output(firstPane, "RELAY_913"));
        await Message(new { type = "ready" }); await Message(new { type = "pane-ready", pane = firstPane.Id, cols = 93, rows = 27 });
        await Until(() => firstPane.Columns == 93);
        first.Resize(93, 27); first.Write("Write-Output ('SIZE_' + [Console]::WindowWidth)\r");
        await WaitScript(terminalCore, Output(firstPane, "SIZE_93"));
        Check(workspace.Tabs.Count == 1 && firstPane.Process == first, "Repeated page/pane ready events do not create duplicate shells");

        // Rename live sessions without restarting shells or confusing their stable IDs.
        string firstTabLabel = "[data-tab-id='" + firstTab.Id + "'] .tab-select";
        await EditName(firstTabLabel, "  Build & test  "); await Until(() => firstTab.Name == "Build & test");
        await EditName(firstTabLabel, "Discard this", "Escape");
        Check(firstTab.Name == "Build & test", "Escape cancels an inline tab rename");
        await EditName(firstTabLabel, "   ");
        foreach (var invalid in new[] { "", new string('x', 81), "line\nbreak" }) await Message(new { type = "rename-tab", tab = firstTab.Id, name = invalid });
        await Task.Delay(100);
        Check(firstTab.Name == "Build & test", "Blank, overlong, and multiline tab names are rejected");
        await ClickTerminalPane(terminalCore, firstPane.Id);
        await Key("b", "KeyB", 66, 2, "\u0002"); await Key(",", "Comma", 188, 0, ",");
        await WaitScript(terminalCore, "document.activeElement.matches('.session-name-input')");
        await terminalCore.ExecuteScriptAsync("document.activeElement.value='Build & test draft'");
        await Message(new { type = "select-tab", tab = firstTab.Id }); await Task.Delay(100);
        await WaitScript(terminalCore, "document.activeElement.matches('.session-name-input') && document.activeElement.value==='Build & test draft'");
        await Key("Escape", "Escape", 27);
        Check(firstTab.Name == "Build & test" && firstPane.Process == first && !first.Exited, "Tmux rename shortcut and concurrent workspace updates preserve editing and the shell");

        Check(ExternalAddress(terminal) == null && ServiceWindowActions(terminal).Length == 1, "Terminal exposes pop-out without a dead external-browser action");
        ExternalClick(ServiceWindowButton, new RoutedEventArgs());
        await Until(() => serviceWindows.ContainsKey(terminal));
        var terminalChild = serviceWindows[terminal];
        Check(terminal.View!.Parent == terminalChild.Host && firstPane.Process == first && !first.Exited, "Terminal titlebar action pops out its existing live workspace");
        var otherService = services.First(s => s.Definition.IconId == "gmail");
        await PopOutService(otherService);
        Check(serviceWindows.Count == 2 && terminal.View.IsVisible, "Separate services can own simultaneous child windows");
        terminalChild.Window.WindowState = WindowState.Minimized; await SelectService(terminal);
        Check(terminalChild.Window.WindowState == WindowState.Normal, "Selecting a popped-out account restores its minimized child");
        await ClickTerminalPane(terminalCore, firstPane.Id);
        await Key("b", "KeyB", 66, 2, "\u0002"); await Key(",", "Comma", 188, 0, ",");
        await WaitScript(terminalCore, "document.activeElement.matches('.session-name-input')"); await Key("Escape", "Escape", 27);
        await Message(new { type = "input", pane = firstPane.Id, data = "Write-Output ('POPOUT_' + $relayFixture)\r" });
        await WaitScript(terminalCore, Output(firstPane, "POPOUT_913"));
        foreach (var mode in new[] { "Light", "Dark" }) {
            settings.Appearance = mode; ApplyTheme();
            await WaitScript(terminalCore, "document.documentElement.style.colorScheme === '" + mode.ToLowerInvariant() + "'");
            await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            var toolbar = PlaceElements<System.Windows.Controls.StackPanel>(terminalChild.Window).Single();
            var dockControl = toolbar.Children.OfType<System.Windows.Controls.Button>().Single();
            Check(terminalChild.Window.Background == Brush("Base") && dockControl.Foreground == Brush("Ink") && dockControl.IsVisible && dockControl.ActualWidth >= 28,
                "Pop-out dock glyph stays visible and follows the theme");
            CaptureElement((FrameworkElement)terminalChild.Window.Content, Path.Combine(output, "terminal-popout-chrome-" + mode + ".png"));
            await Task.Delay(150);
            CaptureThemedWindow(terminalChild.Window, Path.Combine(output, "terminal-popout-" + mode + ".png"));
        }
        terminalChild.Window.Close();
        await Until(() => selected == terminal && terminal.View.Parent == WebHost);
        DockServiceWindow(terminal, select: true);
        Check(firstPane.Process == first && firstTab.Name == "Build & test" && serviceWindows.Count == 1, "Close and duplicate dock retain terminal sessions and leave the other service child alone");
        DockServiceWindow(otherService);
        await SelectService(terminal);

        await Click("#new");
        await Until(() => workspace.Tabs.Count == 2 && workspace.Current?.Panes[0].Process != null);
        var secondTab = workspace.Current!; var tabPane = secondTab.Panes[0]; int tabPID = tabPane.Process!.ProcessId;
        Check(settings.Accounts.Count == accountsBefore && services.Count == servicesBefore && settings.Workspace.Panes.SequenceEqual(new[] { terminal.Definition.Id }), "New tab stays inside the active terminal account");
        await Message(new { type = "input", pane = tabPane.Id, data = "Write-Output ('ISOLATED_' + ($null -eq $relayFixture))\r" });
        await WaitScript(terminalCore, Output(tabPane, "ISOLATED_True"));
        await Click("[data-tab-id='" + firstTab.Id + "'] .tab-select");
        await Until(() => workspace.Current == firstTab);
        await Message(new { type = "input", pane = firstPane.Id, data = "Write-Output ('RETAINED_' + $relayFixture)\r" });
        await WaitScript(terminalCore, Output(firstPane, "RETAINED_913"));
        Check(!first.Exited && !tabPane.Process.Exited, "Switching tabs retains both shells");

        await Click("#split-rows"); await Until(() => firstTab.Panes.Count == 2 && firstTab.Panes[1].Process != null);
        var secondPane = firstTab.Panes[1]; int secondPID = secondPane.Process!.ProcessId;
        await Click("#split"); await Until(() => firstTab.Panes.Count == 3 && firstTab.Panes[2].Process != null);
        var thirdPane = firstTab.Panes[2]; int thirdPID = thirdPane.Process!.ProcessId;
        Check(firstTab.Layout?.Direction == "rows" && firstTab.Layout.Second?.Direction == "columns" && settings.Accounts.Count == accountsBefore, "Mixed-direction splits are nested sessions within one tab");
        string paneLabel = "[data-pane-id='" + firstPane.Id + "'] .pane-name";
        await EditName(paneLabel, "PowerShell · build"); await Until(() => firstPane.Name == "PowerShell · build");
        await Message(new { type = "rename-pane", pane = firstPane.Id, name = "PowerShell · build" });
        await Message(new { type = "rename-pane", pane = firstPane.Id, name = "bad\u0007name" });
        await terminalCore.ExecuteScriptAsync("document.querySelector(" + JsonSerializer.Serialize(paneLabel) + ").focus()");
        await Key("F2", "F2", 113);
        await WaitScript(terminalCore, "document.activeElement.matches('.session-name-input') && document.activeElement.value==='PowerShell · build'");
        await Key("Escape", "Escape", 27);
        await WaitScript(terminalCore, "document.querySelector(" + JsonSerializer.Serialize(paneLabel) + ").textContent==='PowerShell · build' && document.querySelector('[data-pane-id=\"" + firstPane.Id + "\"] .pane-close').getAttribute('aria-label')==='Close PowerShell · build'");
        Check(firstPane.Process == first && firstTab.Name == "Build & test" && firstPane.Name == "PowerShell · build", "Renames survive tab switches, update labels, and preserve the live shell");
        await ClickTerminalPane(terminalCore, firstPane.Id);
        await Until(() => firstTab.ActivePane == firstPane.Id);
        await WaitScript(terminalCore, "document.querySelector('.terminal-pane.active').dataset.paneId === " + JsonSerializer.Serialize(firstPane.Id));
        await terminalCore.CallDevToolsProtocolMethodAsync("Input.insertText", JsonSerializer.Serialize(new { text = "Write-Output ('FOCUSED_' + $relayFixture)" }));
        await terminalCore.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"text\":\"\\r\"}");
        await terminalCore.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13}");
        await WaitScript(terminalCore, Output(firstPane, "FOCUSED_913"));
        await Click("#zoom"); await Until(() => firstTab.Zoomed);
        await WaitScript(terminalCore, "document.querySelector('[data-pane-id=\"" + secondPane.Id + "\"]').getBoundingClientRect().width === 0");
        await Click("#zoom"); await Until(() => !firstTab.Zoomed);
        await terminalCore.ExecuteScriptAsync("document.querySelector('.separator').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}))");
        await Until(() => Math.Abs(firstTab.Layout!.Ratio - 0.55) < 0.001);
        await using (var image = File.Create(Path.Combine(output, "terminal-tabs-split.png"))) await terminalCore.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image).WaitAsync(TimeSpan.FromSeconds(8));
        await Click("[data-pane-id='" + thirdPane.Id + "'] .pane-close"); await Until(() => ProcessEnded(thirdPID));
        await Message(new { type = "close-pane", pane = thirdPane.Id }); await Message(new { type = "focus", pane = thirdPane.Id });
        await Message(new { type = "rename-pane", pane = thirdPane.Id, name = "Closed pane" });
        Check(firstTab.Panes.Count == 2 && firstTab.ActivePane == firstPane.Id && !first.Exited && !secondPane.Process.Exited, "Closing a pane kills only its process and ignores duplicate close/stale focus");
        await Click("[data-pane-id='" + secondPane.Id + "'] .pane-close"); await Until(() => ProcessEnded(secondPID));
        await Click("[data-tab-id='" + secondTab.Id + "'] .tab-close"); await Until(() => ProcessEnded(tabPID));
        await Message(new { type = "rename-tab", tab = secondTab.Id, name = "Closed tab" });
        Check(workspace.Tabs.Count == 1 && !first.Exited && firstTab.Name == "Build & test" && firstPane.Name == "PowerShell · build", "Closing another tab leaves active names and shells intact; stale renames cannot recreate sessions");
        await Click("#close-view"); await Until(() => !settings.Workspace.Panes.Contains(terminal.Definition.Id));
        Check(!first.Exited, "Closing the terminal view preserves its sessions");
        await SelectService(terminal);
        Check(terminalWorkspaces[terminal.Definition.Id] == workspace && firstPane.Process == first && firstTab.Name == "Build & test" && firstPane.Name == "PowerShell · build", "Reopening the account restores the same terminal workspace");

        // Separate accounts remain isolated, and native shell-pane focus follows real clicks.
        var extra = AddAccount(terminal.Definition, "Focus fixture"); await AddPane(extra);
        await Until(() => terminalWorkspaces.GetValueOrDefault(extra.Definition.Id)?.Current?.Panes[0].Process != null);
        var extraPane = terminalWorkspaces[extra.Definition.Id].Current!.Panes[0]; int extraPID = extraPane.Process!.ProcessId;
        foreach (var target in new[] { terminal, extra, terminal }) {
            await ClickNativePane(target); await Until(() => selected == target);
            Check(paneOutlines[target].BorderBrush == Brush("Accent"), "Native focus outline follows the clicked terminal account");
        }
        await extra.Core!.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(new { type = "close-pane", pane = firstPane.Id }) + ")");
        await extra.Core.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(new { type = "rename-tab", tab = firstTab.Id, name = "Wrong account" }) + ")");
        await extra.Core.ExecuteScriptAsync("chrome.webview.postMessage(" + JsonSerializer.Serialize(new { type = "rename-pane", pane = firstPane.Id, name = "Wrong account" }) + ")");
        await Task.Delay(100);
        Check(!first.Exited && !extraPane.Process.Exited && firstTab.Name == "Build & test" && firstPane.Name == "PowerShell · build", "A terminal account cannot address or rename another account's session");
        await CheckTerminalWorkerIsolation(terminalCore);
        DisconnectService(extra); RemoveAccount(extra); await Until(() => ProcessEnded(extraPID));
        await SoloPane(terminal);
        Check(CreateSetup().Accounts.All(a => a.Provider != "terminal"), "Windows-only terminal sessions do not break portable setups");
        await CheckThemeSurfaces(output, terminalCore);
        await using (var image = File.Create(Path.Combine(output, "terminal-session.png"))) await terminalCore.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image).WaitAsync(TimeSpan.FromSeconds(8));
        terminalCore.Navigate("https://example.com/"); await Task.Delay(200);
        Check(terminalCore.Source == TerminalAddress && firstPane.Process == first, "Terminal rejects remote navigation without granting shell access");
        await Click("[data-tab-id='" + firstTab.Id + "'] .tab-close"); await Until(() => ProcessEnded(firstPID));
        await WaitScript(terminalCore, "!document.getElementById('empty').hidden && document.querySelectorAll('.terminal-pane').length === 0");
        await Message(new { type = "input", pane = firstPane.Id, data = "Write-Output STALE\r" });
        Check(workspace.Tabs.Count == 0, "Closing the last tab clears state without recreating its shell");
        await Click("#new"); await Until(() => workspace.Current?.Panes[0].Process != null);
        int finalPID = workspace.Current!.Panes[0].Process!.ProcessId;
        await PopOutService(terminal);
        DisconnectService(terminal); await Until(() => ProcessEnded(finalPID));
        Check(serviceWindows.Count == 0, "Terminal unload clears its pop-out window");
        Check(!terminalWorkspaces.Any(), "Unload removes all account workspaces and shell processes");
        await SelectService(service); await Until(() => service.Status == "Live");
    }
    private static async Task ClickTerminalPane(CoreWebView2 core, string id)
    {
        var selector = "[data-pane-id='" + id + "'] .terminal-host";
        var result = await core.ExecuteScriptAsync("(()=>{const r=document.querySelector(" + JsonSerializer.Serialize(selector) + ").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()");
        using var point = JsonDocument.Parse(result);
        double x = point.RootElement.GetProperty("x").GetDouble(), y = point.RootElement.GetProperty("y").GetDouble();
        await core.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent", JsonSerializer.Serialize(new { type = "mousePressed", x, y, button = "left", clickCount = 1 }));
        await core.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent", JsonSerializer.Serialize(new { type = "mouseReleased", x, y, button = "left", clickCount = 1 }));
    }
    private static bool ProcessEnded(int pid) {
        try { using var process = Process.GetProcessById(pid); return process.HasExited; } catch (ArgumentException) { return true; }
    }
    private static async Task WaitScript(CoreWebView2 core, string expression) {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (await core.ExecuteScriptAsync(expression) != "true") {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("Terminal fixture timed out: " + expression + " focus=" + await core.ExecuteScriptAsync("document.activeElement.outerHTML") + " output=" + await core.ExecuteScriptAsync("window.fixtureOutput"));
            await Task.Delay(100);
        }
    }
}
