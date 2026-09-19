using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Relay;

public partial class MainWindow
{
    private sealed record RailVisual(Path Icon, Border Badge, TextBlock Count, Border Marker, TextBlock Audio, Path Sleep);
    private readonly Dictionary<string, RailVisual> railVisuals = [];
    private CheckBox? startupToggle;
    private FrameworkElement ServiceIcon(ServiceState state, double size, string brush = "Ink")
    {
        var icon = new Path { Data = (Geometry)FindResource("ServiceIcon." + state.Definition.IconId), Width = size, Height = size, Stretch = Stretch.Uniform };
        icon.SetResourceReference(Path.FillProperty, brush);
        return icon;
    }
    private void BuildRail()
    {
        FinishShortcutDrag(false);
        ApplySidebarSize();
        ServiceRail.Children.Clear();
        railButtons.Clear(); railVisuals.Clear();
        foreach (var state in shortcutServices)
        {
            var grid = new Grid { Width = settings.CompactSidebar ? 28 : 42, Height = settings.CompactSidebar ? 30 : 40 };
            var icon = (Path)ServiceIcon(state, settings.CompactSidebar ? 18 : 21);
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            icon.RenderTransformOrigin = new Point(0.5, 0.5);
            var scale = new ScaleTransform(1, 1); icon.RenderTransform = scale;
            grid.Children.Add(icon);
            if (state.Definition.AccountLabel.Length > 0)
            {
                var accountMark = new TextBlock { Text = state.Definition.AccountLabel[..1].ToUpperInvariant(), FontSize = 8, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
                accountMark.SetResourceReference(TextBlock.ForegroundProperty, "Accent"); grid.Children.Add(accountMark);
            }
            var marker = new Border { Width = 3, Height = 14, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
            marker.SetResourceReference(Border.BackgroundProperty, "Accent"); grid.Children.Add(marker);
            var audio = new TextBlock { Text = "\uE74F", FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 9, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Visibility = Visibility.Collapsed };
            audio.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); grid.Children.Add(audio);
            var sleep = new Path { Data = Geometry.Parse("M6,0 A4,4 0 1 0 8,6 A4,4 0 0 1 6,0"), Width = 8, Height = 8, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Visibility = Visibility.Collapsed, ToolTip = "Sleeping" };
            sleep.SetResourceReference(Path.FillProperty, "Muted"); grid.Children.Add(sleep);
            var count = new TextBlock { FontSize = settings.CompactSidebar ? 8 : 9, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center };
            var badge = new Border { CornerRadius = new CornerRadius(6), MinWidth = 14, Padding = new Thickness(3, 0, 3, 0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Child = count, Visibility = Visibility.Collapsed };
            badge.SetResourceReference(Border.BackgroundProperty, "Accent"); count.SetResourceReference(TextBlock.ForegroundProperty, "AccentInk"); grid.Children.Add(badge);
            var button = new Button { Height = settings.CompactSidebar ? 34 : 44, Width = settings.TopTabs ? (settings.CompactSidebar ? 30 : 46) : double.NaN, Margin = settings.TopTabs ? new Thickness(1, 0, 1, 0) : new Thickness(0, 1, 0, 1), Padding = new Thickness(0), Content = grid };
            System.Windows.Automation.AutomationProperties.SetName(button, state.Definition.Name);
            button.Click += async (_, _) => { if (draggingShortcut == null) await SelectService(state); };
            ConfigureShortcut(button, state);
            void Animate(double value)
            {
                if (!SystemParameters.ClientAreaAnimation) return;
                var animation = new DoubleAnimation(value, TimeSpan.FromMilliseconds(120)) { EasingFunction = new QuadraticEase() };
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, animation); scale.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
            }
            button.MouseEnter += (_, _) => Animate(1.08);
            button.MouseLeave += (_, _) => Animate(1);
            railButtons[state.Definition.Id] = button;
            railVisuals[state.Definition.Id] = new(icon, badge, count, marker, audio, sleep);
            ServiceRail.Children.Add(button);
        }
        Refresh();
    }
    private void RefreshRail()
    {
        foreach (var state in shortcutServices)
        {
            var button = railButtons[state.Definition.Id];
            var visual = railVisuals[state.Definition.Id];
            button.SetResourceReference(Button.BackgroundProperty, state == selected ? "AccentSoft" : "Panel");
            visual.Icon.SetResourceReference(Path.FillProperty, state == selected ? "Accent" : state.Options.Enabled ? "Ink" : "Muted");
            visual.Icon.Opacity = state.Suspended ? 0.5 : state.Options.Enabled ? 1 : 0.7;
            visual.Marker.Visibility = state == selected ? Visibility.Visible : Visibility.Collapsed;
            visual.Audio.Visibility = state.Options.AudioMuted ? Visibility.Visible : Visibility.Collapsed;
            visual.Sleep.Visibility = state.Suspended ? Visibility.Visible : Visibility.Collapsed;
            visual.Sleep.Margin = new Thickness(state.Options.AudioMuted ? 11 : 0, 0, 0, 0);
            visual.Count.Text = state.Badge;
            visual.Badge.Visibility = visual.Count.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            button.ToolTip = state.Definition.Name;
        }
        ActivityButton.SetResourceReference(Button.BackgroundProperty, selected == null && localPage == "activity" ? "AccentSoft" : "Panel");
        ActivityButton.SetResourceReference(Button.ForegroundProperty, selected == null && localPage == "activity" ? "Accent" : "Muted");
        SettingsButton.SetResourceReference(Button.BackgroundProperty, selected == null && localPage == "settings" ? "AccentSoft" : "Panel");
        SettingsButton.SetResourceReference(Button.ForegroundProperty, selected == null && localPage == "settings" ? "Accent" : "Muted");
        RefreshGreeting();
    }
    private Border Card(UIElement content, Thickness? padding = null)
    {
        var card = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = padding ?? new Thickness(20), Child = content };
        card.SetResourceReference(Border.BackgroundProperty, "Card"); card.SetResourceReference(Border.BorderBrushProperty, "Line");
        return card;
    }
    private TextBlock Muted(string text, double size = 12)
    {
        var label = Label(text, size); label.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); return label;
    }
    private void BuildActivity()
    {
        if (refreshing) return;
        refreshing = true;
        try
        {
            LocalContent.Children.Clear();
            var serviceGrid = new UniformGrid { Columns = 3, Margin = new Thickness(-5, 0, -5, 26) };
            foreach (var state in shortcutServices)
            {
                var content = new Grid();
                content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(32) });
                content.ColumnDefinitions.Add(new ColumnDefinition());
                var icon = ServiceIcon(state, 21, state.Options.Enabled ? "Accent" : "Muted"); icon.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center); content.Children.Add(icon);
                var details = new StackPanel { Margin = new Thickness(10, 0, 0, 0) };
                details.Children.Add(Label(state.Definition.Name, 13, true));
                var subtitle = Muted(state.Options.Enabled ? state.Status : "Load  +", 10); subtitle.Margin = new Thickness(0, 4, 0, 0); details.Children.Add(subtitle);
                Grid.SetColumn(details, 1); content.Children.Add(details);
                var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(14, 15, 14, 15), Margin = new Thickness(5), MinHeight = 74 };
                button.SetResourceReference(Button.BackgroundProperty, "Card"); button.SetResourceReference(Button.BorderBrushProperty, "Line");
                button.ToolTip = state.Options.Enabled ? "Open" : "Load";
                button.Click += async (_, _) => await SelectService(state);
                serviceGrid.Children.Add(button);
            }
            LocalContent.Children.Add(serviceGrid);
            if (shortcutServices.Length == 0)
            {
                var restore = new Button { Content = "Manage services", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 20) };
                restore.Click += (_, _) => ShowSettings(); LocalContent.Children.Add(restore);
            }
            var heading = new DockPanel();
            var clear = new Button { Content = "Clear", FontSize = 11, IsEnabled = activity.Count > 0, Padding = new Thickness(10, 4, 10, 4) };
            clear.SetResourceReference(Button.ForegroundProperty, "Muted"); clear.Click += (_, _) => { activity.Clear(); BuildActivity(); };
            DockPanel.SetDock(clear, Dock.Right); heading.Children.Add(clear);
            heading.Children.Add(Label("Recent activity", 15, true)); LocalContent.Children.Add(heading);
            if (activity.Count == 0)
            {
                var empty = new StackPanel { Margin = new Thickness(0, 28, 0, 28), HorizontalAlignment = HorizontalAlignment.Center };
                var emblem = new Grid { Width = 64, Height = 48, Margin = new Thickness(0, 0, 0, 12) };
                var back = new Border { Width = 35, Height = 29, CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 14, 12), RenderTransform = new RotateTransform(-10, 18, 15) }; back.SetResourceReference(Border.BorderBrushProperty, "Line"); emblem.Children.Add(back);
                var front = new Border { Width = 35, Height = 29, CornerRadius = new CornerRadius(9), Margin = new Thickness(15, 12, 0, 0), Child = new TextBlock { Text = "✓", FontSize = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
                front.SetResourceReference(Border.BackgroundProperty, "AccentSoft"); ((TextBlock)front.Child).SetResourceReference(TextBlock.ForegroundProperty, "Accent"); emblem.Children.Add(front); empty.Children.Add(emblem);
                var title = Label("Nobody is yapping. Suspicious.", 14, true); title.HorizontalAlignment = HorizontalAlignment.Center; empty.Children.Add(title);
                var card = Card(empty); card.Margin = new Thickness(0, 14, 0, 0); LocalContent.Children.Add(card);
            }
            foreach (var item in activity)
            {
                var content = new Grid(); content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) }); content.ColumnDefinitions.Add(new ColumnDefinition());
                var icon = ServiceIcon(item.Service, 18, "Accent"); icon.SetValue(VerticalAlignmentProperty, VerticalAlignment.Top); icon.SetValue(MarginProperty, new Thickness(0, 3, 0, 0)); content.Children.Add(icon);
                var text = new StackPanel(); Grid.SetColumn(text, 1); content.Children.Add(text);
                text.Children.Add(Muted(item.Service.Definition.Name + "  ·  " + item.Time.ToLocalTime().ToString("t"), 10));
                var title = Label(item.Title, 13, true); title.Margin = new Thickness(0, 7, 0, 3); text.Children.Add(title);
                if (!string.IsNullOrEmpty(item.Body)) text.Children.Add(Muted(item.Body));
                var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(16), Margin = new Thickness(0, 10, 0, 0) };
                button.SetResourceReference(Button.BackgroundProperty, "Card"); button.SetResourceReference(Button.BorderBrushProperty, "Line");
                button.Click += async (_, _) => { await SelectService(item.Service); item.Open?.Invoke(); }; LocalContent.Children.Add(button);
            }
        }
        finally { refreshing = false; }
    }
}
