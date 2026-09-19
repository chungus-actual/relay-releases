using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Shell;
using Microsoft.Web.WebView2.Wpf;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Relay;

public partial class MainWindow
{
    private Window CreatePopup(ServiceState state, WebView2 view)
    {
        var popup = new Window
        {
            Title = "Relay · " + state.Definition.Name, Width = 900, Height = 720, MinWidth = 480, MinHeight = 360,
            Owner = this, Tag = state, Icon = Icon, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.CanResize, UseLayoutRounding = true
        };
        popup.SetResourceReference(Window.BackgroundProperty, "Base");
        popup.SetResourceReference(Window.ForegroundProperty, "Ink");
        WindowChrome.SetWindowChrome(popup, new WindowChrome { CaptionHeight = 36, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0), UseAeroCaptionButtons = false });
        var layout = new Grid(); layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) }); layout.RowDefinitions.Add(new RowDefinition());
        var titleBar = new Grid(); titleBar.SetResourceReference(Grid.BackgroundProperty, "Panel");
        titleBar.ColumnDefinitions.Add(new ColumnDefinition()); titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock { Margin = new Thickness(16, 0, 16, 0), VerticalAlignment = VerticalAlignment.Center, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
        label.SetBinding(TextBlock.TextProperty, new Binding(nameof(Window.Title)) { Source = popup }); titleBar.Children.Add(label);
        var controls = new StackPanel { Orientation = Orientation.Horizontal }; WindowChrome.SetIsHitTestVisibleInChrome(controls, true);
        Grid.SetColumn(controls, 1); titleBar.Children.Add(controls);
        var minimize = new Button { Style = (Style)FindResource("CaptionButton"), Content = "\uE921", ToolTip = "Minimize" }; minimize.Click += (_, _) => SystemCommands.MinimizeWindow(popup);
        var maximize = new Button { Style = (Style)FindResource("CaptionButton"), Content = "\uE922", ToolTip = "Maximize" }; maximize.Click += (_, _) => { if (popup.WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(popup); else SystemCommands.MaximizeWindow(popup); };
        var close = new Button { Style = (Style)FindResource("CloseCaptionButton"), Content = "\uE8BB", ToolTip = "Close" }; close.Click += (_, _) => popup.Close();
        controls.Children.Add(minimize); controls.Children.Add(maximize); controls.Children.Add(close);
        layout.Children.Add(titleBar); Grid.SetRow(view, 1); layout.Children.Add(view);
        var frame = new Border { BorderThickness = new Thickness(1), Child = layout }; frame.SetResourceReference(Border.BorderBrushProperty, "Line"); popup.Content = frame;
        ProtectResizeEdges(popup, frame, layout, browserAtLeft: true);
        popup.StateChanged += (_, _) => { maximize.ToolTip = popup.WindowState == WindowState.Maximized ? "Restore" : "Maximize"; maximize.Content = popup.WindowState == WindowState.Maximized ? "\uE923" : "\uE922"; frame.Margin = popup.WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0); };
        return popup;
    }

    private static void ProtectResizeEdges(Window window, Border frame, Grid content, bool browserAtLeft = false)
    {
        // Keep native child windows out of the existing six-DIP resize border.
        var topEdge = new Border { Height = 5, Background = System.Windows.Media.Brushes.Transparent, VerticalAlignment = VerticalAlignment.Top };
        Grid.SetRowSpan(topEdge, Math.Max(1, content.RowDefinitions.Count));
        WindowChrome.SetIsHitTestVisibleInChrome(topEdge, false);
        content.Children.Add(topEdge);
        void Update()
        {
            bool resize = window.WindowState == WindowState.Normal && window.ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip;
            WindowChrome.GetWindowChrome(window).ResizeBorderThickness = new Thickness(resize ? 6 : 0);
            frame.Padding = resize ? new Thickness(browserAtLeft ? 5 : 0, 0, 5, 5) : new Thickness(0);
            topEdge.Visibility = resize ? Visibility.Visible : Visibility.Collapsed;
        }
        window.StateChanged += (_, _) => Update();
        Update();
    }

    private void ApplyTrayTheme()
    {
        if (tray.ContextMenuStrip is not { } menu) return;
        Drawing.Color Color(string key) { var c = ((System.Windows.Media.SolidColorBrush)FindResource(key)).Color; return Drawing.Color.FromArgb(c.R, c.G, c.B); }
        menu.BackColor = Color("Card"); menu.ForeColor = Color("Ink");
        menu.Renderer = new Forms.ToolStripProfessionalRenderer(new TrayColors(Color("Card"), Color("Hover"), Color("Line"))) { RoundedEdges = false };
        foreach (Forms.ToolStripItem item in menu.Items) item.ForeColor = menu.ForeColor;
        menu.ShowImageMargin = false;
    }
    private sealed class TrayColors(Drawing.Color background, Drawing.Color hover, Drawing.Color line) : Forms.ProfessionalColorTable
    {
        public override Drawing.Color ToolStripDropDownBackground => background;
        public override Drawing.Color ImageMarginGradientBegin => background;
        public override Drawing.Color ImageMarginGradientMiddle => background;
        public override Drawing.Color ImageMarginGradientEnd => background;
        public override Drawing.Color MenuItemSelected => hover;
        public override Drawing.Color MenuItemBorder => hover;
        public override Drawing.Color MenuBorder => line;
        public override Drawing.Color SeparatorDark => line;
        public override Drawing.Color SeparatorLight => background;
    }
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private int NativeHitTest(Point point)
    {
        var screen = PointToScreen(point);
        int packed = ((int)screen.Y << 16) | ((int)screen.X & 0xffff);
        return (int)SendMessage(new WindowInteropHelper(this).Handle, 0x0084, IntPtr.Zero, new IntPtr(packed));
    }
}
