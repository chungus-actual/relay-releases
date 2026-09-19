using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Forms = System.Windows.Forms;

namespace Relay;

public partial class MainWindow : Window
{
    private readonly Settings settings = Settings.Load();
    private readonly List<ServiceState> services = [];
    private readonly Dictionary<string, Button> railButtons = [];
    private readonly Dictionary<string, Task> starts = [];
    private readonly List<ActivityItem> activity = [];
    private readonly List<Window> popups = [];
    private readonly DispatcherTimer idleTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly Forms.NotifyIcon tray = new();
    private Task<CoreWebView2Environment>? environment;
    private ServiceState? selected;
    private string localPage = "activity";
    private bool quitting;
    private bool refreshing;
    private bool suspending;
    private int suppressedNotifications;

    public MainWindow()
    {
        InitializeComponent();
        ProtectResizeEdges(this, WindowFrame, (Grid)WindowFrame.Child);
        InitializeShortcutDragging();
        InitializeUnreadDetection();
        InitializeResourceMonitoring();
        InitializeGreetings();
        InitializeDownloads();
        InitializeMedia();
        SizeChanged += (_, _) => RefreshCaptionLayout();
        foreach (var definition in AccountDefinitions())
        {
            if (!settings.Services.TryGetValue(definition.Id, out var options))
                settings.Services[definition.Id] = options = new() { KeepLive = definition.IconId is not ("calendar" or "googlekeep") };
            options.Zoom = double.IsFinite(options.Zoom) ? Math.Clamp(options.Zoom, 0.5, 2) : 1;
            services.Add(new() { Definition = definition, Options = options });
        }
        InitializeShortcutOrder();
        ApplyTheme();
        BuildRail();
        BuildTray();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemThemeChanged;
        StateChanged += (_, _) =>
        {
            MaximizeButton.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
            MaximizeButton.ToolTip = WindowState == WindowState.Maximized ? "Restore" : "Maximize";
            WindowFrame.Margin = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
            UpdateResourceMonitoring();
        };
        idleTimer.Tick += async (_, _) => await SuspendIdle();
        idleTimer.Start();
        Closing += (_, e) =>
        {
            if (!quitting && !App.SmokeTest && settings.CloseToTray) { e.Cancel = true; Hide(); return; }
            quitting = true;
            FinishShortcutDrag(false);
            idleTimer.Stop();
            unreadTimer.Stop();
            resourceTimer.Stop();
            greetingTimer.Stop();
            updateLifetime.Cancel();
            updateHttp.Dispose();
            downloadTimer.Stop();
            mediaTimer.Stop();
            foreach (var state in services) state.RecoveryGeneration++;
            foreach (var download in downloads.ToArray()) download.Release();
            Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemThemeChanged;
            foreach (var popup in popups.ToArray()) popup.Close();
            foreach (var service in services) service.View?.Dispose();
            tray.Dispose();
            Application.Current.Shutdown();
        };
        PreviewKeyDown += OnKey;
        Loaded += async (_, _) =>
        {
            UpdateResourceMonitoring();
            if (App.SoakTest) { await MemorySoak(); return; }
            if (App.SmokeTest) { await SmokeTest(); return; }
            _ = CheckForUpdates();
            var previous = settings.Selected;
            ShowActivity();
            foreach (var state in services.Where(s => s.Options.Enabled && s.Options.KeepLive)) { if (quitting) return; await EnsureService(state); }
            var last = services.Find(s => s.Definition.Id == previous && s.Options.Enabled);
            if (last != null) await SelectService(last);
        };
    }

    private void BuildTray()
    {
        using var iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Relay-tray.ico")).Stream;
        tray.Icon = new System.Drawing.Icon(iconStream);
        Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Relay.ico"));
        tray.Text = "Relay";
        tray.Visible = !App.SmokeTest;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowWindow);
        BuildTrayMenu();
    }

    private void BuildTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Relay", null, (_, _) => Dispatcher.Invoke(ShowWindow));
        foreach (var service in shortcutServices)
            menu.Items.Add(service.Definition.Name, null, (_, _) => Dispatcher.Invoke(async () => { ShowWindow(); await SelectService(service); }));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Dispatcher.Invoke(() => { quitting = true; Close(); }));
        var previousMenu = tray.ContextMenuStrip;
        tray.ContextMenuStrip = menu;
        previousMenu?.Dispose();
        ApplyTrayTheme();
    }

    private void ShowWindow() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }

    private void Refresh()
    {
        if (quitting) return;
        UpdateUnreadTimer();
        RefreshRail();
        RefreshServiceCaption();
        QuietButton.IsChecked = settings.Quiet;
        QuietButton.ToolTip = settings.Quiet ? "Unmute notifications" : "Mute notifications";
        System.Windows.Automation.AutomationProperties.SetHelpText(QuietButton, (string)QuietButton.ToolTip);
        var unread = services.Sum(s => s.Unread ?? 0);
        var attention = services.Any(s => s.Attention);
        Title = unread > 0 ? $"({unread}) Relay" : attention ? "Relay - new activity" : "Relay";
        tray.Text = unread > 0 ? $"Relay - {unread} reported unread" : "Relay";
        if (selected != null)
        {
            BackButton.IsEnabled = selected.Core?.CanGoBack == true;
        }
        if (localPage == "activity" && selected == null && !refreshing) BuildActivity();
    }

    private async Task EnsureService(ServiceState state)
    {
        while (starts.TryGetValue(state.Definition.Id, out var pending)) await pending;
        if (quitting || !state.Options.Enabled) return;
        if (state.Core != null) return;
        if (state.View != null) ReleaseServiceViews(state);
        var task = StartService(state);
        starts[state.Definition.Id] = task;
        try { await task; }
        finally { starts.Remove(state.Definition.Id); }
    }

    private async Task StartService(ServiceState state)
    {
        state.Loading = true;
        state.Status = "Loading";
        Refresh();
        WebView2? view = null;
        try
        {
            environment ??= CoreWebView2Environment.CreateAsync(null, Path.Combine(App.DataPath, "Browser"), new CoreWebView2EnvironmentOptions { ScrollBarStyle = CoreWebView2ScrollbarStyle.FluentOverlay });
            var env = await environment;
            if (quitting || !state.Options.Enabled) return;
            var controllerOptions = env.CreateCoreWebView2ControllerOptions();
            controllerOptions.ProfileName = state.Definition.Id;
            view = new WebView2 { DefaultBackgroundColor = System.Drawing.Color.FromArgb(22, 23, 25) };
            state.View = view;
            view.Visibility = state == selected ? Visibility.Visible : Visibility.Hidden;
            WebHost.Children.Add(view);
            await view.EnsureCoreWebView2Async(env, controllerOptions);
            if (quitting || !state.Options.Enabled || state.View != view) return;
            view.ZoomFactor = state.Options.Zoom;
            view.ZoomFactorChanged += (_, _) =>
            {
                if (quitting || state.View != view) return;
                double zoom = Math.Clamp(view.ZoomFactor, 0.5, 2);
                if (view.ZoomFactor != zoom) view.ZoomFactor = zoom;
                if (Math.Abs(state.Options.Zoom - zoom) < 0.001) return;
                state.Options.Zoom = zoom; settings.Save();
            };
            var core = view.CoreWebView2;
            await ConfigureCore(core, state, view);
            if (quitting || state.View != view || !state.Options.Enabled) return;
            core.DocumentTitleChanged += (_, _) =>
            {
                if (state.View != view) return;
                state.PageTitle = core.DocumentTitle;
                TitleUnreadChanged(state);
                Refresh();
            };
            var canceledNavigations = new HashSet<ulong>();
            core.NavigationStarting += (_, e) => { if (state.View != view) return; if (e.Cancel) { canceledNavigations.Add(e.NavigationId); return; } state.Status = "Loading"; state.Unread = null; Refresh(); };
            core.NavigationCompleted += (_, e) =>
            {
                if (state.View != view) return;
                if (canceledNavigations.Remove(e.NavigationId)) return;
                state.Status = e.IsSuccess ? "Live" : "Load failed: " + e.WebErrorStatus;
                if (state == selected)
                {
                    ErrorPanel.Visibility = e.IsSuccess ? Visibility.Collapsed : Visibility.Visible;
                    ErrorText.Text = state.Status;
                }
                Refresh();
            };
            core.SourceChanged += (_, _) => { if (state.View != view) return; state.LastAddress = core.Source; Refresh(); };
            core.HistoryChanged += (_, _) => Refresh();
            view.GotKeyboardFocus += async (_, _) => { if (state != selected && !state.Loading) { ShowWindow(); await SelectService(state); } };
            core.Navigate(App.SmokeTest ? "https://relay.test/" : ServiceStartAddress(state));
            view.Visibility = state == selected ? Visibility.Visible : Visibility.Hidden;
        }
        catch (Exception ex)
        {
            if (quitting || !state.Options.Enabled || (view != null && state.View != view)) return;
            environment = null;
            state.Status = "Load failed";
            if (state.View != null) { WebHost.Children.Remove(state.View); state.View.Dispose(); state.View = null; }
            if (state == selected) { ErrorPanel.Visibility = Visibility.Visible; ErrorText.Text = ex.Message; }
            Log(ex);
        }
        finally { state.Loading = false; Refresh(); }
    }

    private async Task ConfigureCore(CoreWebView2 core, ServiceState state, WebView2 owner)
    {
        if (state.Definition.IconId == "messenger")
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(MessengerChromeScript);
            core.DOMContentLoaded += async (_, _) =>
            {
                if (!AccountViews(state).Contains(owner)) return;
                try { await core.ExecuteScriptAsync(MessengerChromeScript); }
                catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
            };
        }
        await ConfigureMedia(core, state);
        var runtime = environment;
        core.ProcessFailed += (_, e) =>
        {
            if (AccountViews(state).Contains(owner)) HandleProcessFailure(state, runtime, e.ProcessFailedKind);
        };
        core.IsMuted = state.Options.AudioMuted;
        ConfigureDownloads(core, state);
        ConfigureFixFixtures(core, state);
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Profile.PreferredColorScheme = WebsiteScheme;
        core.NavigationStarting += (_, e) =>
        {
            if (RouteExternalLink(state, e.Uri))
            {
                e.Cancel = true;
                if (owner != state.View && core.Source == "about:blank")
                    Dispatcher.BeginInvoke(new Action(() => { var popup = Window.GetWindow(owner); if (popup != null && popups.Contains(popup)) popup.Close(); }));
                return;
            }
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || (uri.Scheme is not ("https" or "http") && e.Uri != "about:blank")) e.Cancel = true;
        };
        core.PermissionRequested += (_, e) =>
        {
            if (e.PermissionKind == CoreWebView2PermissionKind.Notifications)
            {
                e.State = state.Definition.Owns(e.Uri) || (App.SmokeTest && Uri.TryCreate(e.Uri, UriKind.Absolute, out var testOrigin) && testOrigin.Scheme == "https" && testOrigin.Host == "relay.test")
                    ? CoreWebView2PermissionState.Allow : CoreWebView2PermissionState.Deny;
                return;
            }
            if (e.PermissionKind is CoreWebView2PermissionKind.Microphone or CoreWebView2PermissionKind.Camera or CoreWebView2PermissionKind.ClipboardRead)
            {
                e.SavesInProfile = false;
                e.State = !App.SmokeTest && MessageBox.Show(this, $"Allow {e.PermissionKind} for {new Uri(e.Uri).Host}?", "Relay", MessageBoxButton.YesNo) == MessageBoxResult.Yes
                    ? CoreWebView2PermissionState.Allow : CoreWebView2PermissionState.Deny;
                if (e.State == CoreWebView2PermissionState.Allow && e.PermissionKind is CoreWebView2PermissionKind.Microphone or CoreWebView2PermissionKind.Camera) state.MediaUsed = true;
            }
        };
        core.ScreenCaptureStarting += (_, _) => state.MediaUsed = true;
        core.NotificationReceived += (_, e) =>
        {
            var notification = e.Notification;
            state.UnreadRevision++; state.DismissedUnreadKey = null;
            state.NativeAttention = state != selected || !IsActive || !IsVisible;
            state.Attention = state.NativeAttention;
            bool suppress = settings.Quiet || !state.Options.Notifications;
            if (suppress || App.SmokeTest)
            {
                e.Handled = true;
                // Suppressed notifications were never shown. ReportClosed requires ReportShown.
                if (suppress) suppressedNotifications++;
            }
            activity.Insert(0, new(state, Trim(notification.Title, 160), Trim(notification.Body, 600), DateTimeOffset.Now, null));
            if (activity.Count > 60) activity.RemoveRange(60, activity.Count - 60);
            Refresh();
        };
        core.NewWindowRequested += async (_, e) => await OpenServicePopup(core, state, e);
        if (App.SmokeTest)
        {
            core.AddWebResourceRequestedFilter("https://relay.test/*", CoreWebView2WebResourceContext.All);
            if (state.Definition.IconId == "messenger") core.AddWebResourceRequestedFilter("https://www.facebook.com/*", CoreWebView2WebResourceContext.All);
            if (state.Definition.IconId == "gmail") core.AddWebResourceRequestedFilter("https://mail.google.com/*", CoreWebView2WebResourceContext.All);
            if (state.Definition.IconId == "discord") core.AddWebResourceRequestedFilter("https://discord.com/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, e) =>
            {
                if (new Uri(e.Request.Uri).Host is not ("relay.test" or "www.facebook.com" or "mail.google.com" or "discord.com")) return;
                string html = "<!doctype html><meta charset='utf-8'><title>(3) Test messages</title><style>body{font:16px Segoe UI;background:#161719;color:#f2f3f4;margin:48px}button{padding:12px}</style><h1>Service test</h1><p>Isolated local test page</p><button onclick=\"new Notification('Test message',{body:'Notification delivery verified'})\">Notify</button>";
                if (new Uri(e.Request.Uri).Host == "www.facebook.com") html = "<!doctype html><title>(3) Messenger fixture</title><style>body{margin:0} [role=banner]{position:fixed;top:0;width:100%;height:56px;background:red} [role=main]{position:fixed;top:56px;bottom:0;width:100%;height:calc(100vh - 56px);background:#161719;color:white}</style><div role='banner'>Facebook nav</div><main role='main'>Messages</main>";
                if (new Uri(e.Request.Uri).Host == "www.facebook.com" && new Uri(e.Request.Uri).AbsolutePath.Contains("fragmented")) html = FragmentedMessengerFixture;
                if (new Uri(e.Request.Uri).Host == "www.facebook.com" && new Uri(e.Request.Uri).AbsolutePath.Contains("nested")) html = NestedMessengerFixture;
                e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(System.Text.Encoding.UTF8.GetBytes(html)), 200, "OK", "Content-Type: text/html");
            };
        }
    }

    private async Task SelectService(ServiceState state)
    {
        if (quitting) return;
        foreach (var other in services.Where(s => s != state && s.View != null))
        {
            if (other == selected) other.HiddenAt = DateTime.UtcNow;
            other.View!.Visibility = Visibility.Hidden;
        }
        CloseServiceAddress();
        selected = state;
        localPage = "";
        state.Attention = state.NativeAttention = false;
        state.Options.Enabled = true;
        settings.Selected = state.Definition.Id;
        settings.Save();
        LocalPage.Visibility = Visibility.Collapsed;
        WebHost.Visibility = Visibility.Visible;
        ErrorPanel.Visibility = Visibility.Collapsed;
        Refresh();
        await EnsureService(state);
        if (quitting || selected != state || !state.Options.Enabled) return;
        if (state.Core is { } liveCore)
        {
            if (state.Suspended) { liveCore.Resume(); state.Suspended = false; state.Status = "Live"; }
            state.View!.Visibility = Visibility.Visible;
            state.View.Focus();
            if (state.Definition.IconId == "messenger")
            {
                try { await liveCore.ExecuteScriptAsync("window.__relayMessengerChrome?.activate()"); }
                catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { Log(ex); }
            }
        }
        Refresh();
    }

    private void ShowLocal(string page, string title, string subtitle)
    {
        if (selected != null) selected.HiddenAt = DateTime.UtcNow;
        foreach (var state in services) if (state.View != null) state.View.Visibility = Visibility.Hidden;
        CloseServiceAddress();
        selected = null;
        localPage = page;
        settings.Selected = page;
        WebHost.Visibility = Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Collapsed;
        LocalPage.Visibility = Visibility.Visible;
        PageHeading.Text = title;
        PageSubtitle.Text = subtitle;
        // WPF logical focus otherwise retains the last hidden/disposed browser control.
        FocusManager.SetFocusedElement(this, page == "settings" ? SettingsButton : ActivityButton);
        Refresh();
    }

    private void ShowActivity() { ShowLocal("activity", "Activity", DateTime.Now.ToString("dddd, MMMM d")); BuildActivity(); }

    private void DisconnectService(ServiceState state)
    {
        state.Options.Enabled = false;
        if (mediaService == state) ClearMedia();
        if (!services.Any(s => s.Options.Enabled && MusicService(s))) mediaTimer.Stop();
        state.RecoveryGeneration++; state.Recovering = false;
        ReleaseServiceViews(state);
        state.Suspended = false; state.Unread = null; state.Attention = state.NativeAttention = false;
        state.UnreadRevision++; state.UnreadKey = ""; state.DismissedUnreadKey = null;
        state.MediaUsed = false; state.NeedsRestart = false; state.Status = "Not loaded";
    }

    private async Task SuspendIdle()
    {
        if (quitting || suspending) return;
        suspending = true;
        try
        {
        foreach (var state in services.Where(s => s.Core != null && !s.Options.KeepLive && s != selected && !s.Suspended && !s.Loading && !s.MediaUsed))
        {
            if (DateTime.UtcNow - state.HiddenAt < TimeSpan.FromMinutes(2) || popups.Count > 0 || HasActiveDownloads(state)) continue;
            var view = state.View!;
            var core = state.Core;
            if (core == null) continue;
            try
            {
                if (core.IsDocumentPlayingAudio) continue;
                bool suspended = await core.TrySuspendAsync();
                if (quitting || state.View != view) continue;
                if (state == selected || state.Options.KeepLive || state.MediaUsed) { core.Resume(); continue; }
                state.Suspended = suspended;
                if (suspended) state.Status = "Sleeping";
            }
            catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException) { }
            catch (Exception ex) { Log(ex); }
        }
        Refresh();
        }
        finally { suspending = false; }
    }

    private static SolidColorBrush ColorBrush(string color) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); brush.Freeze(); return brush; }
    private Brush Brush(string name) => (Brush)FindResource(name);
    private static TextBlock Label(string text, double size, bool bold = false) => new() { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap };
    private static string Trim(string text, int max) => text.Length > max ? text[..max] : text;
    private static void Log(Exception ex) => App.Log(ex);
    private void ActivityClick(object sender, RoutedEventArgs e) => ShowActivity();
    private void SettingsClick(object sender, RoutedEventArgs e) => ShowSettings();
    private void QuietChanged(object sender, RoutedEventArgs e)
    {
        bool value = QuietButton.IsChecked == true;
        if (settings.Quiet == value) return;
        bool previous = settings.Quiet;
        settings.Quiet = value;
        try { settings.Save(); }
        catch (Exception ex)
        {
            settings.Quiet = previous;
            if (App.SmokeTest) throw;
            MessageBox.Show(this, ex.Message, "Couldn't save mute setting", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        Refresh();
        if (localPage == "settings") RebuildSettings();
    }
    private void BackClick(object sender, RoutedEventArgs e) { if (selected?.Core is { CanGoBack: true } core) core.GoBack(); }
    private async void ReloadClick(object sender, RoutedEventArgs e)
    {
        if (selected == null) return;
        ErrorPanel.Visibility = Visibility.Collapsed;
        var state = selected;
        state.RecoveryGeneration++; state.Recovering = false; state.RecoveryAttempts.Clear();
        if (state.NeedsRestart) { DisconnectService(state); state.Options.Enabled = true; }
        if (state.Core is { } core)
        {
            if (GoogleAppHome(state.Definition.IconId) is { } home && IsGoogleLanding(state.Definition.IconId, core.Source)) core.Navigate(home);
            else core.Reload();
        }
        else await SelectService(state);
    }
    private void HomeClick(object sender, RoutedEventArgs e) { if (selected?.Core is { } core) core.Navigate(selected.Definition.Url); }
    private void ExternalClick(object sender, RoutedEventArgs e)
    {
        var address = selected?.Core?.Source;
        if (Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == "https") Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
    private void ChangeZoom(double delta, bool reset = false)
    {
        if (selected == null) return;
        selected.Options.Zoom = reset ? 1 : Math.Clamp(Math.Round(selected.Options.Zoom + delta, 2), 0.5, 2);
        if (selected.View != null) selected.View.ZoomFactor = selected.Options.Zoom;
        settings.Save(); Refresh();
    }
    private void ZoomOutClick(object sender, RoutedEventArgs e) => ChangeZoom(-0.1);
    private void ZoomInClick(object sender, RoutedEventArgs e) => ChangeZoom(0.1);
    private void ZoomResetClick(object sender, RoutedEventArgs e) => ChangeZoom(0, true);
    private async void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (Keyboard.Modifiers == ModifierKeys.Alt && key >= Key.D1 && key <= Key.D9 && key - Key.D1 < shortcutServices.Length) { e.Handled = true; await SelectService(shortcutServices[key - Key.D1]); }
        else if (Keyboard.Modifiers == ModifierKeys.Control && key == Key.R) { e.Handled = true; ReloadClick(this, e); }
        else if (HandleZoomKey(key, Keyboard.Modifiers)) e.Handled = true;
    }

    private async Task SmokeTest()
    {
        var output = Path.Combine(Environment.CurrentDirectory, "artifacts");
        Directory.CreateDirectory(output);
        File.WriteAllText(Path.Combine(output, "smoke-test.txt"), "RUNNING");
        try
        {
            CheckRollingLog();
            Check(services.All(s => !s.Options.Enabled && s.View == null), "Fresh profiles start with every service unloaded");
            Check(ServiceState.CountFromTitle("(12) WhatsApp") == 12, "Unread title parsing");
            Check(ServiceState.CountFromTitle("Inbox (4) - Gmail") == 4, "Gmail title parsing");
            Check(ServiceState.CountFromTitle("Meeting (2026)") == null, "No arbitrary-number badges");
            Check(!services[0].Definition.Owns("https://facebook.com.attacker.test/"), "Origin boundary");
            ShowActivity();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "activity-desktop.png"));
            Width = 720; Height = 540;
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "activity-compact.png"));
            var quietPosition = QuietButton.TransformToAncestor(this).Transform(new Point());
            Check(quietPosition.Y + QuietButton.ActualHeight < ((FrameworkElement)Content).ActualHeight, "Quiet button fits at minimum size");
            Width = 1280; Height = 820;
            ShowSettings();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "settings.png"));
            Check(NativeHitTest(new Point(350, 18)) == 2, "Title bar supports native dragging and double-click");
            Check(NativeHitTest(new Point(ActualWidth - 2, ActualHeight - 2)) == 17, "Native bottom-right resize border");
            Check(startupToggle != null && !StartupRegistration.IsEnabled, "Startup defaults off in isolated profile");
            startupToggle!.IsChecked = true;
            startupToggle.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Check(StartupRegistration.IsEnabled && StartupRegistration.ReadCommand()!.EndsWith(" --startup"), "Launch-at-login toggle registers the executable");
            startupToggle.IsChecked = false;
            startupToggle.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Check(StartupRegistration.ReadCommand() == null, "Launch-at-login toggle removes registration");
            Check(StartupRegistration.BuildCommand(@"C:\Program Files\Relay\Relay.exe", @"C:\Program Files\Relay\Relay.dll") == "\"C:\\Program Files\\Relay\\Relay.exe\" --startup", "Startup path quoting");
            foreach (var choice in new[] { ("Light", "Graphite", "Sky"), ("Dark", "Ocean", "Iris"), ("Light", "Dune", "Amber") })
            {
                settings.Appearance = choice.Item1; settings.Palette = choice.Item2; settings.AccentName = choice.Item3;
                ApplyTheme(); ShowSettings();
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                Capture(Path.Combine(output, "theme-" + choice.Item2.ToLowerInvariant() + ".png"));
                Check(darkTheme == (choice.Item1 == "Dark"), "Theme mode resolves " + choice.Item1);
            }
            LocalPage.ScrollToBottom();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "settings-scrolled.png"));
            Check(LocalPage.VerticalOffset > 0, "Themed settings scrollbar scrolls");
            settings.Appearance = "System"; ApplyTheme();
            Check(WebsiteScheme == CoreWebView2PreferredColorScheme.Auto, "System theme follows desktop");
            settings.Appearance = "Dark"; settings.Palette = "Graphite"; settings.AccentName = "Mint";
            ApplyTheme(); ShowActivity(); LocalPage.ScrollToTop();
            MaximizeClick(this, new RoutedEventArgs());
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(WindowState == WindowState.Maximized, "Custom maximize control");
            Capture(Path.Combine(output, "activity-maximized.png"));
            MaximizeClick(this, new RoutedEventArgs());
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(WindowState == WindowState.Normal, "Custom restore control");
            MinimizeClick(this, new RoutedEventArgs());
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(WindowState == WindowState.Minimized, "Custom minimize control");
            Check(!resourceTimer.IsEnabled && resourceBaselineNeeded, "Usage sampler pauses when minimized");
            ShowWindow();

            var popupFixture = new WebView2();
            var chromePopup = CreatePopup(services[0], popupFixture);
            chromePopup.Show();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(chromePopup.WindowStyle == WindowStyle.None && System.Windows.Shell.WindowChrome.GetWindowChrome(chromePopup).CaptionHeight == 36, "Popup uses themed chrome");
            chromePopup.Close(); popupFixture.Dispose();
            await SelectService(services[0]);
            await Until(() => services[0].Unread == 3);
            Check(services[0].View!.CoreWebView2.Profile.ProfileName == "messenger", "Isolated Messenger profile");
            await CheckServiceCaption(output);
            await services[0].View!.CoreWebView2.ExecuteScriptAsync("localStorage.setItem('isolation-check', 'messenger')");
            await SelectService(services[1]);
            await Until(() => services[1].Unread == 3);
            Check(await services[1].View!.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('isolation-check')") == "null", "Storage isolated across profiles");
            await CheckResourceSidebar(output);
            await services[1].View!.CoreWebView2.Profile.SetPermissionStateAsync(CoreWebView2PermissionKind.Notifications, "https://relay.test", CoreWebView2PermissionState.Allow);
            var notificationResult = await services[1].View!.CoreWebView2.ExecuteScriptAsync("(() => { try { window.testNotification = new Notification('Test message', {body:'Notification delivery verified'}); window.testNotification.onerror = () => window.notificationError = 'Notification error event'; return {permission:Notification.permission, secure:isSecureContext, created:true}; } catch(e) { return {permission:Notification.permission, secure:isSecureContext, error:String(e)}; } })()");
            File.WriteAllText(Path.Combine(output, "notification-diagnostics.txt"), "Runtime: " + services[1].View!.CoreWebView2.Environment.BrowserVersionString + "\n" + notificationResult + "\n");
            try { await Until(() => activity.Count == 1); }
            finally
            {
                File.AppendAllText(Path.Combine(output, "notification-diagnostics.txt"), await services[1].View!.CoreWebView2.ExecuteScriptAsync("JSON.stringify({permission:Notification.permission,error:window.notificationError,title:document.title})") + "\n");
            }
            Check(activity[0].Title == "Test message", "Native notification captured");
            Check(suppressedNotifications == 0, "Unmuted notification policy");
            settings.Quiet = true;
            await services[1].View!.CoreWebView2.ExecuteScriptAsync("new Notification('Muted message', {body:'Quiet mode test'})");
            await Until(() => activity.Count == 2);
            Check(suppressedNotifications == 1, "Quiet mode suppresses desktop display and preserves feed");
            settings.Quiet = false;
            services[1].Options.Notifications = false;
            await services[1].View!.CoreWebView2.ExecuteScriptAsync("new Notification('Service muted message')");
            await Until(() => activity.Count == 3);
            Check(suppressedNotifications == 2, "Per-service suppression");
            services[1].Options.Notifications = true;
            ChangeZoom(0.1);
            Check(Math.Abs(services[1].View!.ZoomFactor - 1.1) < 0.01, "Service zoom");
            services[0].Options.KeepLive = false;
            services[0].HiddenAt = DateTime.UtcNow.AddMinutes(-3);
            services[0].MediaUsed = true;
            await SuspendIdle();
            Check(!services[0].Suspended, "Media session remains live");
            services[0].MediaUsed = false;
            await SuspendIdle();
            Check(services[0].Suspended, "Inactive service suspended");
            RefreshRail();
            Check(railVisuals[services[0].Definition.Id].Sleep.Visibility == Visibility.Visible && railVisuals[services[0].Definition.Id].Count.Text == services[0].Badge, "Sleeping indicator stays separate from notification count");
            CaptureElement(railButtons[services[0].Definition.Id], Path.Combine(output, "sleep-indicator.png"));
            await SelectService(services[0]);
            Check(!services[0].Suspended, "Selected service resumed");
            var firstSwitch = SelectService(services[2]);
            var lastSwitch = SelectService(services[3]);
            await Task.WhenAll(firstSwitch, lastSwitch);
            Check(selected == services[3] && services[3].View!.Visibility == Visibility.Visible && services[2].View!.Visibility == Visibility.Hidden, "Rapid switching keeps the last selection");
            var connecting = SelectService(services[4]);
            DisconnectService(services[4]);
            await connecting;
            Check(services[4].View == null && !services[4].Options.Enabled, "Disconnect during initialization");
            await SelectService(services[4]);
            await Until(() => services[4].Unread == 3);
            Check(services[4].View!.CoreWebView2.Profile.ProfileName == "slack", "Reconnect after canceled initialization");
            var messages = services.Single(s => s.Definition.Id == "googlemessages");
            Check(messages.Options.KeepLive && !messages.Options.Enabled, "Google Messages defaults disconnected and live when connected");
            Check(messages.Definition.Owns("https://messages.google.com/web/") && !messages.Definition.Owns("https://messages.google.com.attacker.test/"), "Google Messages notification origin");
            await SelectService(messages);
            await Until(() => messages.Unread == 3);
            Check(messages.View!.CoreWebView2.Profile.ProfileName == "googlemessages", "Isolated Google Messages profile");
            Check(await messages.View.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('isolation-check')") == "null", "Google Messages storage isolation");
            ShowActivity();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "activity-notification.png"));
            settings.Save();
            Check(Settings.Load().Services["whatsapp"].Zoom == 1.1, "Settings survive reload");
            Check(Settings.Load().Appearance == "Dark" && Settings.Load().Palette == "Graphite" && Settings.Load().AccentName == "Mint", "Theme choices survive reload");
            Check(services[0].View!.CoreWebView2.Profile.PreferredColorScheme == CoreWebView2PreferredColorScheme.Dark, "Website theme preference");
            var orderBefore = settings.ServiceOrder.ToList();
            var originalView = messages.View;
            MoveShortcut(messages, services[0], false);
            Check(shortcutServices[0] == messages && Settings.Load().ServiceOrder[0] == "googlemessages", "Shortcut reorder persists");
            Check(ReferenceEquals(originalView, messages.View), "Reordering preserves browser sessions");
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "shortcuts-reordered.png"));
            SetShortcutVisible(messages, false);
            Check(!railButtons.ContainsKey("googlemessages") && !Settings.Load().Services["googlemessages"].ShowShortcut, "Hidden shortcut stays hidden after reload");
            Check(messages.Options.Enabled && ReferenceEquals(originalView, messages.View), "Hiding preserves the connected service");
            SetShortcutVisible(messages, true);
            Check(shortcutServices[0] == messages, "Restored shortcut retains its position");
            MoveShortcutBy(messages, 1);
            Check(shortcutServices[1] == messages, "Keyboard/context-menu reorder follows visible order");
            Check(NormalizeServiceOrder(new[] { "removed", "gmail", "gmail" }, new[] { "messenger", "gmail", "new" }).SequenceEqual(new[] { "gmail", "messenger", "new" }), "Order migration drops stale duplicates and appends new services");
            foreach (var state in services) SetShortcutVisible(state, false);
            Check(ServiceRail.Children.Count == 0 && shortcutServices.Length == 0, "All shortcuts can be hidden without losing Settings");
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "shortcuts-hidden.png"));
            foreach (var state in services) state.Options.ShowShortcut = true;
            settings.ServiceOrder = orderBefore; settings.Save(); RebuildShortcuts();
            await CheckRailAndUnread(output);
            await CheckNativeResize();
            await CheckUpdatesAndMusic(output);
            await CheckNewFeatures(output);
            await services[0].View!.CoreWebView2.ExecuteScriptAsync("document.cookie = 'relay-crypto-probe=synthetic-cookie-value; Max-Age=3600; Secure; SameSite=Lax'");
            Check(!File.Exists(Path.Combine(App.DataPath, "errors.log")), "No runtime errors during smoke test");
            _ = SelectService(services[5]);
            Check(starts.Count > 0, "Shutdown overlaps pending initialization");
            File.WriteAllText(Path.Combine(output, "smoke-test.txt"), "PASS: all four native resize corners and edges over browser content, popup/maximize/restore resize behavior, full-height nested Messenger panes and resize, Calendar auth return and persistent cookies, default-account rename/profile retention, private RAM and sustained CPU thresholds, Gmail popup cookie sharing/inbox return and compose isolation, fragmented Messenger header/CSP/style-update handling, service-row controls, multiple-account profile isolation and rename/remove, per-account/popup audio mute, cross-account downloads and handle cleanup, renderer/shared-browser crash recovery and retry cancellation, Messenger chrome scoping, untruncated account captions, bounded log rotation, sidebar CPU/RAM scope/calculation/lifecycle/layout and visible mute toggle, unread parsing, origin boundary, shell layouts, isolated profiles/storage including Google Messages, shortcut reorder/hide/persistence, merged service caption/address/compact hit targets, compact-sidebar persistence, themed context menus, disconnect/reconnect storage retention, custom title controls, theme palettes/persistence, isolated startup-toggle/quoting, styled scrolling, native notification capture and suppression, zoom, media suspension guard, suspend/resume, rapid switching, disconnect/reconnect during initialization, settings persistence.\n");
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "smoke-test.txt"), "FAIL: " + ex); Environment.ExitCode = 1; }
        finally { quitting = true; Close(); }
    }

    private static void Check(bool value, string name) { if (!value) throw new InvalidOperationException(name); }
    private static async Task Until(Func<bool> ready)
    {
        var deadline = DateTime.UtcNow.AddSeconds(25);
        while (!ready()) { if (DateTime.UtcNow > deadline) throw new TimeoutException("Service test timed out"); await Task.Delay(100); }
    }
    private void Capture(string path)
    {
        UpdateLayout();
        var surface = (FrameworkElement)Content;
        var image = new RenderTargetBitmap((int)surface.ActualWidth, (int)surface.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        image.Render(this);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(path); encoder.Save(file);
    }
}
