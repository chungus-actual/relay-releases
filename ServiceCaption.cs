using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using System.Threading.Tasks;
using System.IO;
using System.Globalization;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private void RefreshServiceCaption()
    {
        bool inService = selected != null;
        PageHeaderRow.Height = new GridLength(inService ? 0 : 64);
        PageHeader.Visibility = inService ? Visibility.Collapsed : Visibility.Visible;
        CaptionContext.Visibility = inService ? Visibility.Collapsed : Visibility.Visible;
        ServiceIdentityButton.Visibility = CaptionActions.Visibility = BrowserTools.Visibility = inService ? Visibility.Visible : Visibility.Collapsed;
        if (!inService) BrowserOverflow.Visibility = Visibility.Collapsed;
        if (selected == null) { RefreshCaptionLayout(); return; }
        var address = CurrentServiceAddress;
        ServiceCaptionName.Text = selected.Definition.Name;
        ServiceCaptionHost.Text = CaptionDomain(address);
        ServiceIdentityButton.ToolTip = "Address";
        System.Windows.Automation.AutomationProperties.SetName(ServiceIdentityButton, selected.Definition.Name + ": view current address");
        RefreshCaptionLayout();
    }

    private void RefreshCaptionLayout()
    {
        double Measure(string text, double size, FontWeight weight) => new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
            new Typeface(FontFamily, FontStyles.Normal, weight, FontStretches.Normal), size, Brush("Ink"), VisualTreeHelper.GetDpi(this).PixelsPerDip).WidthIncludingTrailingWhitespace;
        double available = Math.Max(0, (ActualWidth > 0 ? ActualWidth : Width) - (Math.Max(15, CaptionBrand.ActualWidth) + CaptionBrand.Margin.Left + CaptionBrand.Margin.Right) - Math.Max(132, WindowButtons.ActualWidth) - WindowFrame.Padding.Right - 34);
        double nameWidth = selected == null ? 0 : Measure(ServiceCaptionName.Text, 12, FontWeights.SemiBold);
        if (MediaControls.Visibility == Visibility.Visible)
        {
            double titleWidth = Math.Clamp(available - (selected == null ? 120 : nameWidth + 60) - 102, 0, 220);
            MediaTitle.Visibility = titleWidth >= 48 && MediaTitle.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            MediaTitle.Width = Math.Min(titleWidth, Math.Ceiling(Measure(MediaTitle.Text, 11, FontWeights.Normal)) + 2);
            available -= 92 + (MediaTitle.Visibility == Visibility.Visible ? MediaTitle.Width + 10 : 0);
        }
        if (selected == null) return;
        bool fullTools = nameWidth + 32 <= available - 123;
        BrowserTools.Visibility = fullTools ? Visibility.Visible : Visibility.Collapsed;
        BrowserOverflow.Visibility = fullTools ? Visibility.Collapsed : Visibility.Visible;
        double identityWidth = available - (fullTools ? 123 : 28);
        ServiceCaptionHost.Visibility = nameWidth + 42 + Measure(ServiceCaptionHost.Text, 11, FontWeights.Normal) <= identityWidth ? Visibility.Visible : Visibility.Collapsed;
        ServiceCaptionName.FontSize = Math.Min(12, Math.Max(9, 12 * Math.Max(1, identityWidth - 32) / Math.Max(1, nameWidth)));
    }

    private void BrowserOverflowClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = BrowserOverflow, Placement = PlacementMode.Bottom };
        void Add(string label, RoutedEventHandler action) { var item = new MenuItem { Header = label }; item.Click += action; menu.Items.Add(item); }
        Add("Back", BackClick); Add("Reload", ReloadClick); Add("Home", HomeClick);
        menu.Items.Add(new Separator());
        if (selected != null) menu.Items.Add(CreateZoomMenu(selected));
        menu.Items.Add(new Separator()); Add("Open externally", ExternalClick);
        BrowserOverflow.ContextMenu = menu; menu.IsOpen = true;
    }

    private static readonly string[] CaptionDomains = Settings.Definitions().SelectMany(s => s.Hosts).Distinct().OrderBy(h => h.Length).ToArray();

    private static string CaptionDomain(string address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)) return "";
        var host = uri.IdnHost;
        return CaptionDomains.FirstOrDefault(domain => host.Equals(domain, StringComparison.OrdinalIgnoreCase) || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase))
            ?? (host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? host[4..] : host);
    }

    private string CurrentServiceAddress => selected?.Core?.Source ?? selected?.Definition.Url ?? "";

    private void CloseServiceAddress()
    {
        if (ServiceIdentityButton.ContextMenu is { } menu) menu.IsOpen = false;
        ServiceIdentityButton.ContextMenu = null;
    }

    private void ServiceAddressClick(object sender, RoutedEventArgs e)
    {
        if (selected == null) return;
        CloseServiceAddress();
        var address = CurrentServiceAddress;
        var menu = new ContextMenu { PlacementTarget = ServiceIdentityButton, Placement = PlacementMode.Bottom };
        menu.Items.Add(new MenuItem { Header = "Current address", IsEnabled = false });
        var text = new TextBox { Text = address, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Width = 320, MaxHeight = 140, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0), Padding = new Thickness(2) };
        text.SetResourceReference(Control.BackgroundProperty, "Card");
        text.SetResourceReference(Control.ForegroundProperty, "Ink");
        System.Windows.Automation.AutomationProperties.SetName(text, "Current service address");
        menu.Items.Add(new MenuItem { Header = text, StaysOpenOnClick = true });
        menu.Items.Add(new Separator());
        var copy = new MenuItem { Header = "Copy address" };
        copy.Click += (_, _) =>
        {
            try { Clipboard.SetText(address); }
            catch (System.Runtime.InteropServices.ExternalException) { MessageBox.Show(this, "Clipboard is busy. Try again.", "Couldn’t copy address", MessageBoxButton.OK, MessageBoxImage.Information); }
        };
        menu.Items.Add(copy);
        ServiceIdentityButton.ContextMenu = menu;
        menu.IsOpen = true;
    }

    private static void CaptureElement(FrameworkElement element, string path)
    {
        element.UpdateLayout();
        var image = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth), (int)Math.Ceiling(element.ActualHeight), 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        image.Render(element);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var file = File.Create(path); encoder.Save(file);
    }

    private async Task CheckServiceCaption(string output)
    {
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        UpdateLayout();
        Check(PageHeaderRow.ActualHeight == 0 && PageHeader.Visibility == Visibility.Collapsed, $"Service header returns all 64 pixels to the page (height={PageHeaderRow.ActualHeight}, visibility={PageHeader.Visibility}, selected={selected?.Definition.Id}, top={settings.TopTabs})");
        Check(WebHost.TransformToAncestor(this).Transform(new Point()).Y < 40, "Service starts directly beneath window title bar");
        Check(ServiceCaptionName.Text == selected!.Definition.Name && ServiceCaptionHost.Text == "relay.test", "Caption identifies selected service and actual origin");
        Capture(Path.Combine(output, "service-caption-desktop.png"));
        Width = 720; Height = 540;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        var toolsPosition = BrowserTools.TransformToAncestor(this).Transform(new Point());
        var identityPosition = ServiceIdentityButton.TransformToAncestor(this).Transform(new Point());
        var controlsPosition = WindowButtons.TransformToAncestor(this).Transform(new Point());
        Check(identityPosition.X + ServiceIdentityButton.ActualWidth <= toolsPosition.X && toolsPosition.X + BrowserTools.ActualWidth <= controlsPosition.X, "Service and window controls do not overlap at minimum width");
        foreach (var button in BrowserTools.Children.OfType<Button>().Where(b => b.IsEnabled).Append(ServiceIdentityButton))
        {
            var center = button.TransformToAncestor(this).Transform(new Point(button.ActualWidth / 2, button.ActualHeight / 2));
            Check(NativeHitTest(center) == 1, "Title-bar service control is clickable: " + button.ToolTip);
        }
        Check(NativeHitTest(new Point(40, 18)) == 2, "Brand remains a native window drag target with service open");
        Capture(Path.Combine(output, "service-caption-compact.png"));
        SidebarToggleClick(this, new RoutedEventArgs());
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(SidebarColumn.ActualWidth == 36 && Settings.Load().CompactSidebar, "Compact sidebar width persists");
        Check(WebHost.TransformToAncestor(this).Transform(new Point()).X < 40, "Compact sidebar returns horizontal space to the service");
        Check(ServiceRailScroll.ViewportHeight > 100 && SettingsButton.IsVisible, "Compact shortcuts scroll while utility controls stay accessible");
        Capture(Path.Combine(output, "service-sidebar-compact.png"));
        var serviceMenu = railButtons[selected!.Definition.Id].ContextMenu;
        serviceMenu.PlacementTarget = railButtons[selected.Definition.Id]; serviceMenu.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check((string)((MenuItem)serviceMenu.Items[0]).Header == "Unload", "Loaded shortcut offers unload");
        CaptureElement(serviceMenu, Path.Combine(output, "service-menu-dark.png"));
        serviceMenu.IsOpen = false;
        settings.Appearance = "Light"; ApplyTheme();
        serviceMenu.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CaptureElement(serviceMenu, Path.Combine(output, "service-menu-light.png"));
        serviceMenu.IsOpen = false;
        settings.Appearance = "Dark"; ApplyTheme();
        SidebarToggleClick(this, new RoutedEventArgs());
        Check(!Settings.Load().CompactSidebar, "Expanded sidebar choice persists");
        ServiceAddressClick(this, new RoutedEventArgs());
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(ServiceIdentityButton.ContextMenu!.IsOpen && ServiceIdentityButton.ContextMenu.Items.OfType<MenuItem>().Any(item => item.Header is TextBox box && box.IsReadOnly && box.Text == CurrentServiceAddress), "Current full address is available without reserving a page row");
        CaptureElement(ServiceIdentityButton.ContextMenu, Path.Combine(output, "service-address-menu.png"));
        var connectedService = selected!;
        await connectedService.View!.CoreWebView2.ExecuteScriptAsync("localStorage.setItem('reconnect-check', 'still-here')");
        await ToggleServiceConnection(connectedService);
        Check(!connectedService.Options.Enabled && connectedService.View == null && selected == null, "Disconnect closes selected service and returns to Activity");
        var reconnectMenu = railButtons[connectedService.Definition.Id].ContextMenu;
        reconnectMenu.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check((string)((MenuItem)reconnectMenu.Items[0]).Header == "Load", "Unloaded shortcut offers load");
        reconnectMenu.IsOpen = false;
        await ToggleServiceConnection(connectedService);
        await Until(() => connectedService.Unread == 3);
        Check(await connectedService.View!.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('reconnect-check')") == "\"still-here\"", "Reconnect preserves browser storage");
        ShowActivity();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(PageHeaderRow.ActualHeight == 64 && BrowserTools.Visibility == Visibility.Collapsed && ServiceIdentityButton.ContextMenu == null, "Local page restores heading and dismisses address menu");
        Width = 1280; Height = 820;
        await SelectService(services[0]);
    }
}
