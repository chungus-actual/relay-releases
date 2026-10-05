using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private const string TerminalAddress = "https://relay-terminal.invalid/index.html";
    private readonly Dictionary<string, TerminalWorkspace> terminalWorkspaces = [];
    private static readonly JsonSerializerOptions TerminalJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private void RefreshTerminalThemes()
    {
        foreach (var state in services.Where(s => s.Definition.IsTerminal && s.Options.Enabled))
            if (state.Core is { } core && core.Source == TerminalAddress) ApplyTerminalTheme(core);
    }
    private void ApplyTerminalTheme(CoreWebView2 core)
    {
        string Hex(string key) { var c = ((System.Windows.Media.SolidColorBrush)Brush(key)).Color; return $"#{c.R:X2}{c.G:X2}{c.B:X2}"; }
        core.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "theme", dark = darkTheme,
            colors = new { background = Hex("Base"), foreground = Hex("Ink"), panel = Hex("Panel"), card = Hex("Card"),
                hover = Hex("Hover"), muted = Hex("Muted"), line = Hex("Line"), accent = Hex("Accent") } }));
    }
    private void StopTerminal(ServiceState state)
    {
        if (terminalWorkspaces.Remove(state.Definition.Id, out var workspace)) workspace.Dispose();
    }
    private void ConfigureTerminal(CoreWebView2 core, ServiceState state, WebView2 view)
    {
        bool ready = false;
        var attached = new HashSet<string>();
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = true;
        core.Settings.AreDevToolsEnabled = App.SmokeTest;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.SetVirtualHostNameToFolderMapping("relay-terminal.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "Terminal"), CoreWebView2HostResourceAccessKind.Deny);
        core.NavigationStarting += (_, e) => { e.Cancel = e.Uri != TerminalAddress; if (!e.Cancel) { ready = false; attached.Clear(); } };
        core.FrameNavigationStarting += (_, e) => e.Cancel = true;
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.DownloadStarting += (_, e) => e.Cancel = true;
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        var files = new HashSet<string>(StringComparer.Ordinal) { "/index.html", "/xterm.js", "/xterm.css", "/addon-fit.js", "/terminal.js", "/terminal.css" };
        core.WebResourceRequested += (_, e) => {
            if (!Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "relay-terminal.invalid" || !files.Contains(uri.AbsolutePath))
                e.Response = core.Environment.CreateWebResourceResponse(Stream.Null, 403, "Blocked", "Content-Type: text/plain");
        };
        bool Current() => !quitting && state.Options.Enabled && state.View == view && state.Core == core;
        void Post(object message) { if (Current() && ready) core.PostWebMessageAsJson(JsonSerializer.Serialize(message, TerminalJson)); }
        void Status(string text, string? pane = null) => Post(new { type = "status", pane, data = text });
        void Publish(TerminalWorkspace workspace, bool focus = false) => Post(new {
            type = "workspace", activeTab = workspace.ActiveTab, focus,
            tabs = workspace.Tabs.Select(tab => new { tab.Id, tab.Name, tab.ActivePane, tab.Zoomed, tab.Layout,
                panes = tab.Panes.Select(p => new { p.Id, p.Name, p.Status }) })
        });
        void Start(TerminalWorkspace workspace, TerminalTab tab, TerminalPane pane) {
            if (pane.Process != null) { pane.Process.Resize(pane.Columns, pane.Rows); return; }
            PseudoTerminal? process = null;
            bool Live() => Current() && terminalWorkspaces.GetValueOrDefault(state.Definition.Id) == workspace && tab.Panes.Contains(pane) && pane.Process == process;
            process = new PseudoTerminal(pane.Columns, pane.Rows, async data => {
                if (Dispatcher.HasShutdownStarted) return;
                await Dispatcher.InvokeAsync(() => {
                    if (!Live()) return;
                    pane.Remember(data);
                    if (attached.Contains(pane.Id)) Post(new { type = "output", pane = pane.Id, data });
                }, System.Windows.Threading.DispatcherPriority.Background);
            }, () => {
                if (Dispatcher.HasShutdownStarted) return;
                Dispatcher.BeginInvoke(new Action(() => {
                    if (Live()) { pane.Status = "Shell exited"; Status("Shell exited · Restart to continue", pane.Id); Publish(workspace); }
                }));
            });
            pane.Process = process; pane.Status = "Running"; state.Status = "Live"; Publish(workspace); Refresh();
        }
        core.WebMessageReceived += (_, e) => {
            if (!Current() || e.Source != TerminalAddress || core.Source != TerminalAddress || e.WebMessageAsJson.Length > 100000) return;
            try {
                using var message = JsonDocument.Parse(e.WebMessageAsJson);
                var data = message.RootElement;
                string? Text(string name) => data.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                string? SessionName() {
                    string? name = Text("name")?.Trim();
                    if (string.IsNullOrEmpty(name) || name.Length > 80 || name.Any(c => char.IsControl(c) || c is '\u2028' or '\u2029')) {
                        Status("Use a name of 1–80 characters on one line."); return null;
                    }
                    return name;
                }
                short Dimension(string name, short fallback) => data.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int size) ? (short)Math.Clamp(size, 2, 500) : fallback;
                string? type = Text("type");
                if (type == "ready") {
                    if (ready) return;
                    ready = true; ApplyTerminalTheme(core);
                    if (!terminalWorkspaces.TryGetValue(state.Definition.Id, out var initial)) {
                        initial = new TerminalWorkspace(); initial.AddTab().AddPane(); terminalWorkspaces[state.Definition.Id] = initial;
                    }
                    state.Status = "Live"; Publish(initial, true); Refresh(); return;
                }
                if (!ready || !terminalWorkspaces.TryGetValue(state.Definition.Id, out var workspace)) return;
                var tab = workspace.Tabs.Find(t => t.Panes.Any(p => p.Id == Text("pane")));
                var pane = tab?.Panes.Find(p => p.Id == Text("pane"));
                if (type == "pane-ready" && pane != null && tab != null) {
                    pane.Columns = Dimension("cols", pane.Columns); pane.Rows = Dimension("rows", pane.Rows);
                    if (attached.Add(pane.Id) && pane.History.Length > 0) Post(new { type = "output", pane = pane.Id, data = pane.History.ToString() });
                    Start(workspace, tab, pane); return;
                }
                if (type == "resize" && pane != null) {
                    pane.Columns = Dimension("cols", pane.Columns); pane.Rows = Dimension("rows", pane.Rows);
                    pane.Process?.Resize(pane.Columns, pane.Rows); return;
                }
                switch (type) {
                    case "new":
                        if (workspace.Tabs.Count >= 16) { Status("Sixteen tabs open · Close a tab to create another"); return; }
                        workspace.AddTab().AddPane(); Publish(workspace, true); break;
                    case "select-tab":
                        var target = workspace.Tabs.Find(t => t.Id == Text("tab"));
                        if (target != null) { workspace.ActiveTab = target.Id; Publish(workspace, true); }
                        break;
                    case "rename-tab":
                        var renaming = workspace.Tabs.Find(t => t.Id == Text("tab"));
                        if (renaming != null && SessionName() is { } tabName) { renaming.Name = tabName; Publish(workspace); }
                        break;
                    case "close-tab":
                        var closing = workspace.Tabs.Find(t => t.Id == Text("tab"));
                        if (closing != null) { foreach (var p in closing.Panes) attached.Remove(p.Id); workspace.CloseTab(closing); Publish(workspace, true); }
                        break;
                    case "next": case "previous":
                        if (workspace.Tabs.Count == 0) return;
                        int index = workspace.Tabs.FindIndex(t => t.Id == workspace.ActiveTab), offset = type == "next" ? 1 : -1;
                        workspace.ActiveTab = workspace.Tabs[(index + offset + workspace.Tabs.Count) % workspace.Tabs.Count].Id; Publish(workspace, true); break;
                    case "close-view":
                        if (serviceWindows.TryGetValue(state, out var child)) child.Window.Close(); else ClosePane(state);
                        break;
                    default:
                        // Ignore delayed input/focus from a closed pane or a tab that is no longer visible.
                        if (tab == null || pane == null || tab.Id != workspace.ActiveTab) return;
                        switch (type) {
                            case "focus":
                                FocusPane(state, view);
                                if (tab.ActivePane != pane.Id) { tab.ActivePane = pane.Id; Publish(workspace); }
                                break;
                            case "input":
                                if (tab.ActivePane == pane.Id && Text("data") is { } input && pane.Process?.Write(input) != true) Status("Input buffer full or shell closed; try again", pane.Id);
                                break;
                            case "split":
                                if (tab.Panes.Count >= 4) { Status("Four panes open · Close a pane to split again"); return; }
                                tab.AddPane(pane.Id, Text("direction") == "rows" ? "rows" : "columns"); Publish(workspace, true); break;
                            case "rename-pane":
                                if (SessionName() is { } paneName) { pane.Name = paneName; Publish(workspace); }
                                break;
                            case "close-pane":
                                attached.Remove(pane.Id); tab.ClosePane(pane);
                                if (tab.Panes.Count == 0) workspace.CloseTab(tab);
                                Publish(workspace, true); break;
                            case "restart":
                                if (!App.SmokeTest && MessageBox.Show(this, "End this shell and its running commands?", "Restart terminal", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
                                pane.Dispose(); Post(new { type = "reset", pane = pane.Id }); Start(workspace, tab, pane); Publish(workspace, true); break;
                            case "zoom": tab.ActivePane = pane.Id; tab.Zoomed = tab.Panes.Count > 1 && !tab.Zoomed; Publish(workspace, true); break;
                            case "resize-layout":
                                if (tab.Layout?.Find(Text("split")) is { Pane: null } node && data.TryGetProperty("ratio", out var ratio) && ratio.TryGetDouble(out double value) && double.IsFinite(value)) {
                                    node.Ratio = Math.Clamp(value, 0.15, 0.85); Publish(workspace);
                                }
                                break;
                        }
                        break;
                }
            } catch (Exception ex) { Log(ex); Status("Terminal error: " + ex.Message); }
        };
        core.NavigationCompleted += (_, e) => { if (Current() && !e.IsSuccess) { state.Status = "Load failed: " + e.WebErrorStatus; Refresh(); } };
        core.ProcessFailed += (_, _) => { if (Current()) { StopTerminal(state); state.NeedsRestart = true; state.Status = "Load failed: terminal renderer stopped"; Refresh(); } };
        core.Navigate(TerminalAddress);
    }
}
