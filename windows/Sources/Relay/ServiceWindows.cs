using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private sealed record ServiceWindow(Window Window, Grid Host);
    private readonly Dictionary<ServiceState, ServiceWindow> serviceWindows = [];
    private bool IsDetached(ServiceState state) => state == floatingService || serviceWindows.ContainsKey(state);

    private static Uri? ExternalAddress(ServiceState state) => !state.Definition.IsTerminal &&
        Uri.TryCreate(state.Core?.Source ?? state.Definition.Url, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" ? uri : null;

    private void OpenServiceBrowser(ServiceState state)
    {
        if (ExternalAddress(state) is { } uri) Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }

    private MenuItem[] ServiceWindowActions(ServiceState state)
    {
        var popout = new MenuItem { Header = serviceWindows.ContainsKey(state) ? "Show Relay window" : "Pop out in Relay", IsEnabled = state.Options.Enabled };
        popout.Click += async (_, _) => await PopOutService(state);
        if (state.Definition.IsTerminal) return [popout];
        var browser = new MenuItem { Header = "Open in default browser", IsEnabled = ExternalAddress(state) != null };
        browser.Click += (_, _) => OpenServiceBrowser(state);
        return [popout, browser];
    }

    private async void ExternalClick(object sender, RoutedEventArgs e)
    {
        if (selected is not { } state) return;
        if (state.Definition.IsTerminal) { await PopOutService(state); return; }
        var anchor = sender as FrameworkElement ?? ServiceWindowButton;
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        foreach (var item in ServiceWindowActions(state)) menu.Items.Add(item);
        anchor.ContextMenu = menu; menu.IsOpen = true;
    }

    private static void ActivateServiceWindow(ServiceWindow child)
    {
        if (child.Window.WindowState == WindowState.Minimized) child.Window.WindowState = WindowState.Normal;
        child.Window.Activate();
        child.Host.Children.OfType<Microsoft.Web.WebView2.Wpf.WebView2>().FirstOrDefault()?.Focus();
    }

    private async Task PopOutService(ServiceState state)
    {
        if (quitting || !services.Contains(state) || !state.Options.Enabled) return;
        if (serviceWindows.TryGetValue(state, out var existing)) { ActivateServiceWindow(existing); return; }
        await EnsureService(state);
        if (quitting || !state.Options.Enabled || state.View is not { } view || state.Core is not { } core) return;
        if (serviceWindows.TryGetValue(state, out existing)) { ActivateServiceWindow(existing); return; }
        if (floatingService == state) DockMedia();
        if (state.Suspended) { core.Resume(); state.Suspended = false; state.Status = "Live"; }
        var window = new Window { Title = state.Definition.Name + " · Relay", Width = 1000, Height = 700,
            MinWidth = 400, MinHeight = 260, Owner = this, Icon = Icon, ShowInTaskbar = true,
            WindowStartupLocation = WindowStartupLocation.CenterOwner };
        window.SetResourceReference(Window.BackgroundProperty, "Base"); window.SetResourceReference(Window.ForegroundProperty, "Ink");
        var layout = new DockPanel(); layout.SetResourceReference(Panel.BackgroundProperty, "Panel");
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        DockPanel.SetDock(toolbar, Dock.Top); layout.Children.Add(toolbar);
        void Tool(string glyph, string name, Action action) {
            var button = new Button { Content = glyph, FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 12, Width = 30, Height = 28, Padding = new Thickness(0), ToolTip = name };
            System.Windows.Automation.AutomationProperties.SetName(button, name);
            button.Click += (_, _) => action(); toolbar.Children.Add(button);
        }
        if (!state.Definition.IsTerminal) {
            Tool("\uE72B", "Back", () => { if (state.Core?.CanGoBack == true) state.Core.GoBack(); });
            Tool("\uE72C", "Reload", () => state.Core?.Reload());
            Tool("\uE8A7", "Open in default browser", () => OpenServiceBrowser(state));
        }
        Tool("\uE8A9", "Dock in Relay", () => DockServiceWindow(state, select: true));
        var host = new Grid(); layout.Children.Add(host); window.Content = layout;
        WebHost.Children.Remove(view);
        view.Width = view.Height = double.NaN; view.Margin = new Thickness(0);
        view.HorizontalAlignment = HorizontalAlignment.Stretch; view.VerticalAlignment = VerticalAlignment.Stretch;
        view.Visibility = Visibility.Visible; Grid.SetRow(view, 0); host.Children.Add(view);
        serviceWindows[state] = new(window, host);
        window.Closed += (_, _) => { if (serviceWindows.GetValueOrDefault(state)?.Window == window) DockServiceWindow(state, select: true); };
        window.Activated += (_, _) => { state.Attention = state.NativeAttention = false; Refresh(); };
        ClosePane(state);
        window.Show(); ActivateServiceWindow(serviceWindows[state]);
    }

    private void DockServiceWindow(ServiceState state, bool select = false)
    {
        if (!serviceWindows.Remove(state, out var child)) return;
        if (state.View is { } view && child.Host.Children.Contains(view)) {
            child.Host.Children.Remove(view); WebHost.Children.Add(view);
            view.Visibility = IsPaneVisible(state) ? Visibility.Visible : Visibility.Hidden;
        }
        child.Window.Close(); ArrangePanes();
        if (select && !quitting && state.Options.Enabled && services.Contains(state)) { ShowWindow(); _ = SelectService(state); }
    }
}
