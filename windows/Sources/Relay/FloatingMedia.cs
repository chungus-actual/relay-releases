using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private Window? floatingWindow;
    private ServiceState? floatingService;
    private CoreWebView2? floatingCore;
    private Grid? floatingHost;
    private Button? floatingPlay;
    private bool floatingBusy;

    private async void MediaFloatClick(object sender, RoutedEventArgs e)
    {
        if (floatingWindow != null) { floatingWindow.Activate(); return; }
        if (mediaService is { } state && mediaCore == state.Core) await FloatMedia(state);
    }

    private async Task FloatMedia(ServiceState state)
    {
        if (floatingBusy || quitting || state.View is not { } view || state.Core is not { } core) return;
        floatingBusy = true;
        try
        {
            DockMedia();
            DockServiceWindow(state);
            if (state.Suspended) { core.Resume(); state.Suspended = false; }
            floatingService = state; floatingCore = core;
            var window = new Window {
                Title = state.Definition.Name + " · Floating player", Width = 520, Height = 340,
                MinWidth = 360, MinHeight = 200, Topmost = true, ShowInTaskbar = false,
                Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner, Icon = Icon
            };
            window.SetResourceReference(Window.BackgroundProperty, "Base");
            window.SetResourceReference(Window.ForegroundProperty, "Ink");
            var layout = new DockPanel();
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6) };
            DockPanel.SetDock(controls, Dock.Top); layout.Children.Add(controls);
            Button Control(string label, Action action) {
                var button = new Button { Content = label, Margin = new Thickness(2), Padding = new Thickness(9, 4, 9, 4) };
                System.Windows.Automation.AutomationProperties.SetName(button, label);
                button.Click += (_, _) => action(); controls.Children.Add(button); return button;
            }
            floatingPlay = Control("Play / pause", () => _ = FloatingAction());
            Control("Full screen", () => {
                bool full = window.WindowStyle == WindowStyle.None;
                window.WindowState = WindowState.Normal;
                window.WindowStyle = full ? WindowStyle.SingleBorderWindow : WindowStyle.None;
                if (!full) window.WindowState = WindowState.Maximized;
                else ApplyWindowTheme(window);
            });
            Control("Dock", () => { DockMedia(); _ = SelectService(state); });
            window.PreviewKeyDown += (_, e) => {
                if (e.Key == Key.Escape && window.WindowStyle == WindowStyle.None) {
                    window.WindowState = WindowState.Normal; window.WindowStyle = WindowStyle.SingleBorderWindow; ApplyWindowTheme(window); e.Handled = true;
                }
            };
            floatingHost = new Grid(); layout.Children.Add(floatingHost);
            WebHost.Children.Remove(view);
            view.Width = view.Height = double.NaN; view.Margin = new Thickness(0);
            view.HorizontalAlignment = HorizontalAlignment.Stretch; view.VerticalAlignment = VerticalAlignment.Stretch;
            view.Visibility = Visibility.Visible; Grid.SetRow(view, 0); floatingHost.Children.Add(view);
            floatingWindow = window; window.Content = layout;
            window.Closed += (_, _) => { if (floatingWindow == window) DockMedia(); };
            window.Show();
            await core.ExecuteScriptAsync("window.__relayMedia?.act('float')");
            RefreshFloatingMedia();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { DockMedia(); Log(ex); }
        finally { floatingBusy = false; }
    }

    private void RefreshFloatingMedia()
    {
        if (floatingWindow == null || floatingService == null) return;
        floatingWindow.Title = floatingService.Definition.Name + " · Floating player";
        if (floatingPlay != null) floatingPlay.Content = floatingCore == mediaCore ? (mediaPlaying ? "Pause" : "Play") : "Play / pause";
    }

    private async Task FloatingAction()
    {
        var core = floatingCore;
        if (core == null || floatingService?.Core != core) return;
        try {
            await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
                expression = "window.__relayMedia?.act(window.__relayMedia.read().playing ? 'pause' : 'play')", userGesture = true, awaitPromise = true
            }));
            await RefreshMedia();
        } catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { DockMedia(); }
    }

    private void DockMedia()
    {
        var window = floatingWindow; var state = floatingService; var core = floatingCore; var host = floatingHost;
        floatingWindow = null; floatingService = null; floatingCore = null; floatingHost = null; floatingPlay = null;
        if (state?.View is { } view && host?.Children.Contains(view) == true) {
            host.Children.Remove(view); WebHost.Children.Add(view);
            view.Visibility = IsPaneVisible(state) ? Visibility.Visible : Visibility.Hidden;
        }
        if (core != null) _ = ResetFloatingPage(core);
        window?.Close();
        ArrangePanes();
    }

    private static async Task ResetFloatingPage(CoreWebView2 core)
    {
        try { await core.ExecuteScriptAsync("window.__relayMedia?.act('dock')"); }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
    }
}
