using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Automation;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckThemeSurfaces(string output, CoreWebView2 terminal)
    {
        var oldMode = settings.Appearance; var oldPalette = settings.Palette;
        var oldSelected = selected;
        var oldWidth = Width;
        var chrome = new Window { Title = "Theme", Width = 360, Height = 180, ShowInTaskbar = false, ShowActivated = false };
        chrome.Show();
        try {
            foreach (var mode in new[] { "Light", "Dark" }) foreach (var palette in new[] { "Graphite", "Ocean", "Dune" }) {
                settings.Appearance = mode; settings.Palette = palette; ApplyTheme();
                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) {
                    var handle = new WindowInteropHelper(chrome).Handle;
                    Check(DwmGetWindowAttribute(handle, 20, out int dark, sizeof(int)) == 0 && dark == (mode == "Dark" ? 1 : 0), "Native titlebar follows Relay appearance");

                }
                await WaitScript(terminal, "document.documentElement.style.colorScheme === '" + mode.ToLowerInvariant() + "'");
                var expected = ((SolidColorBrush)Brush("Base")).Color;
                string rgb = $"rgb({expected.R}, {expected.G}, {expected.B})";
                await WaitScript(terminal, "getComputedStyle(document.body).backgroundColor === " + System.Text.Json.JsonSerializer.Serialize(rgb));
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                CaptureThemedWindow(chrome, Path.Combine(output, "titlebar-" + mode + "-" + palette + ".png"));
                ShowAccountEditor(services[0]);
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                var combo = PlaceElements<ComboBox>(LocalContent).Single();
                combo.IsDropDownOpen = true;
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                var popup = (Popup)combo.Template.FindName("PART_Popup", combo);
                Check(popup.Child is Border surface && surface.Background == Brush("Card"), "Account dropdown uses the current palette: " + mode + palette);
                Check(combo.Foreground == Brush("Ink") && combo.FontFamily.Source == "Segoe UI", "Account dropdown text follows the theme without inheriting icon glyphs");
                combo.SelectedIndex = 2;
                Check(combo.SelectedItem as string == "Sky", "Themed dropdown selection works");
                CaptureElement((FrameworkElement)popup.Child, Path.Combine(output, "dropdown-" + mode + "-" + palette + ".png"));
                combo.IsDropDownOpen = false;
                var menu = new ContextMenu { PlacementTarget = WorkspaceLayoutButton };
                var item = new MenuItem { Header = "Selected appearance", IsChecked = true }; menu.Items.Add(item); menu.IsOpen = true;
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                Check(menu.FontFamily.Source == "Segoe UI" && menu.Background == Brush("Card"), "Menu inherits Relay typography and palette");
                Check(((TextBlock)item.Template.FindName("CheckMark", item)).Visibility == Visibility.Visible, "Checked dropdown items expose their current selection");
                CaptureElement(menu, Path.Combine(output, "menu-" + mode + "-" + palette + ".png")); menu.IsOpen = false;
                if (oldSelected != null) await SelectService(oldSelected);
                await using var image = File.Create(Path.Combine(output, "terminal-" + mode + "-" + palette + ".png"));
                await terminal.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image).WaitAsync(TimeSpan.FromSeconds(8));
            }
            foreach (double width in new[] { 720.0, 900.0 }) foreach (bool editing in new[] { false, true }) {
                Width = width; ShowAccountEditor(editing ? services[0] : null);
                var name = PlaceElements<TextBox>(LocalContent).Single(t => AutomationProperties.GetName(t) == "Account name");
                name.Text = new string('W', 80);
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                var form = (FrameworkElement)name.Parent;
                var right = name.TranslatePoint(new Point(name.ActualWidth, 0), LocalPage).X;
                Check(name.ActualWidth > 100 && name.ActualWidth <= form.ActualWidth + 1 && right <= LocalPage.ViewportWidth + 1, "Account name field fits its form and viewport at " + width);
                Capture(Path.Combine(output, (editing ? "rename-account-" : "add-account-") + width + ".png"));
            }
        } finally { Width = oldWidth; chrome.Close(); settings.Appearance = oldMode; settings.Palette = oldPalette; ApplyTheme(); if (oldSelected != null) await SelectService(oldSelected); }
    }
    private static void CaptureThemedWindow(Window window, string path)
    {
        var handle = new WindowInteropHelper(window).Handle;
        Check(GetWindowRect(handle, out var rect), "Theme fixture has a native window rectangle");
        using var bitmap = new System.Drawing.Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) {
            var context = graphics.GetHdc();
            try { Check(PrintWindow(handle, context, 2), "Native titlebar capture succeeds"); }
            finally { graphics.ReleaseHdc(context); }
        }
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    [StructLayout(LayoutKind.Sequential)] private struct ThemeWindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out ThemeWindowRect rectangle);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
}
