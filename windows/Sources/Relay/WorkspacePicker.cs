using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Relay;

public partial class MainWindow
{
    private Popup? workspacePicker;
    private readonly List<Button> workspaceLayoutTiles = [];
    private Button? workspaceAddButton;
    private readonly Dictionary<ServiceState, Button> workspaceAccountButtons = [];
    private readonly Dictionary<string, Button> workspacePaneButtons = [];

    private void RefreshWorkspacePaneControls()
    {
        foreach (var (state, button) in workspaceAccountButtons)
        {
            button.Content = ServiceIcon(state, 16, state == selected ? "Accent" : "Muted");
            button.SetResourceReference(Control.BackgroundProperty, state == selected ? "AccentSoft" : "Panel");
        }
        int index = selected == null ? -1 : settings.Workspace.Panes.IndexOf(selected.Definition.Id);
        foreach (var (action, button) in workspacePaneButtons)
            button.IsEnabled = index >= 0 && (action switch
            {
                "earlier" => index > 0,
                "later" => index < settings.Workspace.Panes.Count - 1,
                "solo" => settings.Workspace.Panes.Count > 1,
                _ => true
            });
    }

    private void HideLayoutButtonClick(object sender, RoutedEventArgs e) => SetLayoutButtonHidden(true);
    private void SetLayoutButtonHidden(bool hidden)
    {
        bool previous = settings.HideLayoutButton;
        settings.HideLayoutButton = hidden;
        try { settings.Save(); }
        catch { settings.HideLayoutButton = previous; throw; }
        CloseWorkspacePicker();
        ApplySidebarSize();
    }
    private void CloseWorkspacePicker()
    {
        if (workspacePicker != null) workspacePicker.IsOpen = false;
    }
    private void WorkspaceLayoutClick(object sender, RoutedEventArgs e)
    {
        if (workspacePicker?.IsOpen == true) { CloseWorkspacePicker(); return; }
        OpenWorkspacePicker();
    }
    private void OpenWorkspacePicker()
    {
        CloseWorkspacePicker(); workspaceLayoutTiles.Clear(); workspaceAccountButtons.Clear(); workspacePaneButtons.Clear();
        var content = new StackPanel();
        var previews = new StackPanel { Orientation = Orientation.Horizontal };
        var panes = PaneServices().ToArray();
        var single = LayoutPreviewButton("single", "Single pane", panes);
        single.IsEnabled = panes.Length > 0;
        single.Click += async (_, _) =>
        {
            var state = selected ?? panes.FirstOrDefault();
            if (state == null) return;
            CloseWorkspacePicker(); StopPaneMotion(); settings.Workspace.Panes = [state.Definition.Id]; await SelectService(state);
        };
        previews.Children.Add(single); workspaceLayoutTiles.Add(single);
        for (int i = 0; i < WorkspaceLayout.Arrangements.Length; i++)
        {
            string arrangement = WorkspaceLayout.Arrangements[i];
            var tile = LayoutPreviewButton(arrangement, WorkspaceLayout.Labels[i], panes);
            tile.IsEnabled = panes.Length > 1;
            tile.Click += (_, _) => SetWorkspaceArrangement(arrangement);
            previews.Children.Add(tile); workspaceLayoutTiles.Add(tile);
        }
        content.Children.Add(previews);
        var actions = new DockPanel { Margin = new Thickness(5, 10, 5, 0) };
        var reset = PickerAction("\uE72C", "Reset pane sizes"); reset.IsEnabled = panes.Length > 1;
        reset.Click += (_, _) => SetWorkspaceArrangement(settings.Workspace.Arrangement);
        DockPanel.SetDock(reset, Dock.Right); actions.Children.Add(reset);
        var accounts = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var state in panes)
        {
            var focus = PickerAction("", state.Definition.Name); focus.Content = ServiceIcon(state, 16, state == selected ? "Accent" : "Muted");
            if (state == selected) focus.SetResourceReference(Control.BackgroundProperty, "AccentSoft");
            focus.Click += async (_, _) =>
            {
                if (IsPaneVisible(state)) FocusPane(state, state.View);
                else { await SelectService(state); OpenWorkspacePicker(); }
            };
            workspaceAccountButtons[state] = focus;
            accounts.Children.Add(focus);
        }
        workspaceAddButton = PickerAction("\uE710", "Add pane");
        workspaceAddButton.IsEnabled = panes.Length < 4;
        workspaceAddButton.Click += AddPaneClick; accounts.Children.Add(workspaceAddButton);
        var divider = new Border { Width = 1, Height = 18, Margin = new Thickness(8, 0, 12, 0) };
        divider.SetResourceReference(Border.BackgroundProperty, "Line"); accounts.Children.Add(divider);
        void PaneAction(string key, string glyph, string name, RoutedEventHandler handler)
        {
            var button = PickerAction(glyph, name); button.Click += handler;
            workspacePaneButtons[key] = button; accounts.Children.Add(button);
        }
        PaneAction("service", "\uE8AB", "Change pane service", (sender, _) =>
        {
            if (selected == null) return;
            var choices = PaneServiceChoices(selected); var menu = new ContextMenu();
            var items = choices.Items.Cast<MenuItem>().ToArray(); choices.Items.Clear();
            foreach (var item in items) menu.Items.Add(item);
            menu.PlacementTarget = (Button)sender; menu.Placement = PlacementMode.Bottom; menu.IsOpen = true;
        });
        PaneAction("earlier", "\uE72B", "Move pane earlier", (_, _) => { if (selected != null) MovePane(selected, -1); });
        PaneAction("later", "\uE72A", "Move pane later", (_, _) => { if (selected != null) MovePane(selected, 1); });
        PaneAction("solo", "\uE740", "Only this pane", async (_, _) => { if (selected != null) await SoloPane(selected); });
        PaneAction("close", "\uE8BB", "Close pane", (_, _) => { if (selected != null) ClosePane(selected); });
        RefreshWorkspacePaneControls();
        actions.Children.Add(accounts); content.Children.Add(actions);
        var savedPlaces = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        savedPlaces.Children.Add(ActionButton("Save workspace…", () => { CloseWorkspacePicker(); ShowWorkspaceEditor(); }));
        savedPlaces.Children.Add(ActionButton("Saved workspaces…", () => { CloseWorkspacePicker(); ShowLibrary(); }));
        content.Children.Add(savedPlaces);
        var surface = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(10), Child = content };
        // A popup otherwise inherits the placement button's icon font.
        System.Windows.Documents.TextElement.SetFontFamily(surface, FontFamily);
        surface.SetResourceReference(Border.BackgroundProperty, "Panel"); surface.SetResourceReference(Border.BorderBrushProperty, "Line");
        workspacePicker = new Popup { Child = surface, PlacementTarget = WorkspaceLayoutButton,
            Placement = settings.TopTabs ? PlacementMode.Bottom : PlacementMode.Right,
            HorizontalOffset = settings.TopTabs ? 0 : 8, VerticalOffset = settings.TopTabs ? 8 : 0,
            StaysOpen = false, AllowsTransparency = true, PopupAnimation = SystemParameters.ClientAreaAnimation ? PopupAnimation.Fade : PopupAnimation.None };
        workspacePicker.Closed += (_, _) => { WorkspaceLayoutButton.SetResourceReference(Control.ForegroundProperty, "Muted"); WorkspaceLayoutButton.SetResourceReference(Control.BackgroundProperty, "Panel"); };
        surface.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { CloseWorkspacePicker(); WorkspaceLayoutButton.Focus(); e.Handled = true; } };
        WorkspaceLayoutButton.SetResourceReference(Control.ForegroundProperty, "Accent");
        WorkspaceLayoutButton.SetResourceReference(Control.BackgroundProperty, "AccentSoft");
        workspacePicker.IsOpen = true;
        // The first enabled control participates in normal tab/arrow focus without explanatory copy.
        KeyboardNavigation.SetTabNavigation(surface, KeyboardNavigationMode.Cycle);
        int activeIndex = panes.Length == 1 ? 0 : Array.IndexOf(WorkspaceLayout.Arrangements, settings.Workspace.Arrangement) + 1;
        if (panes.Length > 0) workspaceLayoutTiles[Math.Max(0, activeIndex)].Focus(); else workspaceAddButton.Focus();
    }
    private Button PickerAction(string glyph, string name)
    {
        var button = new Button { Style = (Style)FindResource("IconButton"), Content = glyph, ToolTip = name, Width = 30, Height = 28, Margin = new Thickness(0, 0, 4, 0) };
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        return button;
    }
    private Button LayoutPreviewButton(string arrangement, string name, ServiceState[] panes)
    {
        bool single = arrangement == "single";
        int count = single ? 1 : panes.Length > 1 ? panes.Length : arrangement == "grid" ? 4 : arrangement.StartsWith("main-") ? 3 : 2;
        var preview = new WorkspaceLayout { Arrangement = single ? "grid" : arrangement,
            Primary = arrangement.StartsWith("main-") ? 0.6 : 0.5, Panes = Enumerable.Range(0, count).Select(i => i.ToString()).ToList() };
        preview.Normalize(preview.Panes);
        bool active = single ? panes.Length == 1 : panes.Length > 1 && settings.Workspace.Arrangement == arrangement;
        var drawing = new Canvas { Width = 76, Height = 58, IsHitTestVisible = false, RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(1, 1) };
        for (int i = 0; i < count; i++)
        {
            var cell = preview.Cell(i);
            var pane = new Border { Width = Math.Max(0, cell.Width * 76 - 3), Height = Math.Max(0, cell.Height * 58 - 3),
                CornerRadius = new CornerRadius(2.5), BorderThickness = new Thickness(1), Opacity = active ? 1 : 0.65 };
            pane.SetResourceReference(Border.BackgroundProperty, active ? "AccentSoft" : "Card");
            pane.SetResourceReference(Border.BorderBrushProperty, active ? "Accent" : "Muted");
            var state = single ? selected ?? panes.FirstOrDefault() : panes.ElementAtOrDefault(i);
            if (state != null && Math.Min(pane.Width, pane.Height) >= 16) pane.Child = ServiceIcon(state, Math.Min(12, Math.Min(pane.Width, pane.Height) - 6), active ? "Accent" : "Muted");
            Canvas.SetLeft(pane, cell.X * 76 + 1.5); Canvas.SetTop(pane, cell.Y * 58 + 1.5); drawing.Children.Add(pane);
        }
        var button = new Button { Width = 92, Height = 74, Padding = new Thickness(6), Margin = new Thickness(2, 0, 2, 0), Content = drawing, ToolTip = name };
        button.SetResourceReference(Control.BackgroundProperty, active ? "AccentSoft" : "Panel");
        button.SetResourceReference(Control.BorderBrushProperty, active ? "Accent" : "Panel");
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        System.Windows.Automation.AutomationProperties.SetHelpText(button, active ? "Selected" : "");
        void Hover(bool inside)
        {
            var transform = (ScaleTransform)drawing.RenderTransform;
            double scale = inside ? 1.04 : 1;
            if (!SystemParameters.ClientAreaAnimation) { transform.ScaleX = transform.ScaleY = scale; return; }
            var animation = new DoubleAnimation(scale, TimeSpan.FromMilliseconds(120)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            transform.BeginAnimation(ScaleTransform.ScaleXProperty, animation); transform.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
        }
        button.MouseEnter += (_, _) => Hover(true); button.MouseLeave += (_, _) => Hover(false);
        return button;
    }
    private void SetWorkspaceArrangement(string arrangement)
    {
        if (!WorkspaceLayout.Arrangements.Contains(arrangement)) return;
        CloseWorkspacePicker();
        AnimatePaneChange(() =>
        {
            settings.Workspace.Arrangement = arrangement;
            settings.Workspace.Primary = arrangement.StartsWith("main-") ? 0.6 : 0.5;
            settings.Workspace.Cuts.Clear(); RebuildPaneChrome(); settings.Save();
        });
    }
}
