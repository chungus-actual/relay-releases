using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace Relay;

public partial class MainWindow
{
    private readonly Dictionary<ServiceState, Border> paneOutlines = [];
    private readonly Dictionary<ServiceState, Button> paneErrors = [];
    private readonly List<(Thumb Thumb, WorkspaceLayout.Divider Divider)> paneDividers = [];
    private IEnumerable<ServiceState> PaneServices() => settings.Workspace.Panes.Select(id => services.Find(s => s.Definition.Id == id)).OfType<ServiceState>();
    private bool IsPaneVisible(ServiceState state) => selected != null && state.Options.Enabled && settings.Workspace.Panes.Contains(state.Definition.Id);

    private void ArrangePanes()
    {
        double width = WebHost.ActualWidth, height = WebHost.ActualHeight;
        bool multi = settings.Workspace.Panes.Count > 1;
        foreach (var state in services)
        {
            if (IsDetached(state)) continue;
            bool visible = IsPaneVisible(state);
            if (state.View is { } browser)
            {
                if (!visible && browser.Visibility == Visibility.Visible) state.HiddenAt = DateTime.UtcNow;
                var visibility = visible && !(paneErrors.ContainsKey(state) && PaneLoadFailed(state)) ? Visibility.Visible : Visibility.Hidden;
                if (browser.Visibility != visibility) browser.Visibility = visibility;
            }
            if (!visible) continue;
            int index = settings.Workspace.Panes.IndexOf(state.Definition.Id);
            var cell = PresentedPaneCell(state.Definition.Id, settings.Workspace.Cell(index));
            double x = cell.X * width, y = cell.Y * height, w = cell.Width * width, h = cell.Height * height;
            double inset = multi ? 3 : 0;
            if (state.View is { } view) PlacePaneElement(view, x + inset, y + inset, w - inset * 2, h - inset * 2);
            if (paneOutlines.TryGetValue(state, out var outline)) PlacePaneElement(outline, x + 1, y + 1, w - 2, h - 2);
            if (paneErrors.TryGetValue(state, out var error)) PlacePaneElement(error, x + inset, y + inset, w - inset * 2, h - inset * 2);
        }
        var dividers = settings.Workspace.Dividers();
        for (int i = 0; i < paneDividers.Count && i < dividers.Count; i++)
        {
            var d = dividers[i]; var thumb = paneDividers[i].Thumb;
            thumb.Visibility = paneMotionFrom.Count > 0 ? Visibility.Hidden : Visibility.Visible;
            PlacePaneElement(thumb, d.Vertical ? d.Position * width - 3 : d.Start * width,
                d.Vertical ? d.Start * height : d.Position * height - 3,
                d.Vertical ? 6 : d.Length * width, d.Vertical ? d.Length * height : 6);
        }
    }
    private static void PlacePaneElement(FrameworkElement view, double x, double y, double width, double height)
    {
        view.HorizontalAlignment = HorizontalAlignment.Left; view.VerticalAlignment = VerticalAlignment.Top;
        view.Margin = new Thickness(x, y, 0, 0); view.Width = Math.Max(0, width); view.Height = Math.Max(0, height);
    }
    private static bool PaneLoadFailed(ServiceState state) => !state.Loading && (state.Core == null || state.Status.StartsWith("Load failed") || state.Status == "Recovery paused");
    private void RefreshPaneStatus()
    {
        PaneActionsButton.Visibility = selected != null && settings.Workspace.Panes.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        System.Windows.Automation.AutomationProperties.SetName(PaneActionsButton, selected == null ? "Pane actions" : selected.Definition.Name + " pane actions");
        foreach (var (state, outline) in paneOutlines)
            outline.SetResourceReference(Border.BorderBrushProperty, state == selected ? "Accent" : "Line");
        RefreshCaptionLayout();
        foreach (var (state, error) in paneErrors)
        {
            bool failed = PaneLoadFailed(state);
            error.Content = state.Definition.Name + (failed ? " — " + state.Status + ". Click to retry." : " — Loading…");
            error.Visibility = IsPaneVisible(state) && (failed || state.Core == null) ? Visibility.Visible : Visibility.Collapsed;
            // WebView2 is a native child window: hide a failed browser so it cannot cover the retry control.
            if (!IsDetached(state) && state.View is { } view) view.Visibility = IsPaneVisible(state) && !failed ? Visibility.Visible : Visibility.Hidden;
        }
        if (settings.Workspace.Panes.Count > 1) ErrorPanel.Visibility = Visibility.Collapsed;
    }
    private void RebuildPaneChrome()
    {
        foreach (var state in PaneServices().Where(serviceWindows.ContainsKey).ToArray()) DockServiceWindow(state);
        foreach (var outline in paneOutlines.Values) WebHost.Children.Remove(outline);
        foreach (var error in paneErrors.Values) WebHost.Children.Remove(error);
        foreach (var item in paneDividers) WebHost.Children.Remove(item.Thumb);
        paneOutlines.Clear(); paneErrors.Clear(); paneDividers.Clear();
        CloseWorkspacePicker();
        if (settings.Workspace.Panes.Count > 1)
        {
            foreach (var state in PaneServices())
            {
                var outline = new Border { BorderThickness = new Thickness(1), IsHitTestVisible = false };
                paneOutlines[state] = outline; WebHost.Children.Add(outline);
                var error = new Button { FontSize = 12, Padding = new Thickness(8), Visibility = Visibility.Collapsed };
                error.Click += async (_, _) => { await SelectService(state); ReloadClick(this, new RoutedEventArgs()); };
                Panel.SetZIndex(error, 1); paneErrors[state] = error; WebHost.Children.Add(error);
            }
            foreach (var divider in settings.Workspace.Dividers())
            {
                var thumb = new Thumb { Cursor = divider.Vertical ? Cursors.SizeWE : Cursors.SizeNS, Focusable = true, ToolTip = "Drag to resize; arrow keys adjust; double-click to reset" };
                thumb.SetResourceReference(Control.BackgroundProperty, "Line");
                var visual = new FrameworkElementFactory(typeof(Border)); visual.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
                thumb.Template = new ControlTemplate(typeof(Thumb)) { VisualTree = visual };
                System.Windows.Automation.AutomationProperties.SetName(thumb, divider.Vertical ? "Resize pane widths" : "Resize pane heights");
                thumb.DragDelta += (_, e) => { var origin = thumb.TranslatePoint(new Point(3, 3), WebHost); double position = divider.Vertical ? (origin.X + e.HorizontalChange) / Math.Max(1, WebHost.ActualWidth) : (origin.Y + e.VerticalChange) / Math.Max(1, WebHost.ActualHeight); settings.Workspace.Resize(divider.Index, position); QueuePaneArrange(); };
                thumb.DragStarted += (_, _) => StopPaneMotion();
                thumb.DragCompleted += (_, _) => { StopPaneMotion(); ArrangePanes(); settings.Save(); };
                thumb.MouseDoubleClick += (_, _) => { settings.Workspace.Resize(divider.Index, divider.Index < 0 ? 0.5 : (divider.Index + 1.0) / (settings.Workspace.Cuts.Count + 1)); ArrangePanes(); settings.Save(); };
                thumb.KeyDown += (_, e) => { double delta = e.Key is Key.Left or Key.Up ? -0.02 : e.Key is Key.Right or Key.Down ? 0.02 : 0; if (delta == 0) return; double current = divider.Index < 0 ? settings.Workspace.Primary : settings.Workspace.Cuts[divider.Index]; settings.Workspace.Resize(divider.Index, current + delta); ArrangePanes(); settings.Save(); e.Handled = true; };
                Panel.SetZIndex(thumb, 3); paneDividers.Add((thumb, divider)); WebHost.Children.Add(thumb);
            }
        }
        ArrangePanes(); RefreshPaneStatus();
    }
    private void FocusPane(ServiceState state, Microsoft.Web.WebView2.Wpf.WebView2? source)
    {
        if (quitting || source == null || state.View != source || !IsPaneVisible(state) || IsDetached(state) || state == selected) return;
        // The browser already owns input. Preserve its clicked element, selection, and caret.
        CloseServiceAddress();
        selected = state; settings.Selected = state.Definition.Id;
        state.Attention = state.NativeAttention = false;
        settings.Save(); Refresh(); RefreshWorkspacePaneControls();
    }
    private void MovePane(ServiceState state, int offset)
    {
        int index = settings.Workspace.Panes.IndexOf(state.Definition.Id), target = index + offset;
        if (index < 0 || target < 0 || target >= settings.Workspace.Panes.Count) return;
        AnimatePaneChange(() => { (settings.Workspace.Panes[index], settings.Workspace.Panes[target]) = (settings.Workspace.Panes[target], settings.Workspace.Panes[index]); RebuildPaneChrome(); settings.Save(); });
    }
    private async Task SoloPane(ServiceState state)
    {
        if (!settings.Workspace.Panes.Contains(state.Definition.Id)) return;
        settings.Workspace.Panes = [state.Definition.Id]; await SelectService(state);
    }
    private MenuItem PaneServiceChoices(ServiceState state)
    {
        var choose = new MenuItem { Header = "Choose service" };
        foreach (var service in OrderedServices().Where(s => s == state || !settings.Workspace.Panes.Contains(s.Definition.Id)))
        {
            var item = new MenuItem { Header = service.Definition.Name, Icon = ServiceIcon(service, 16), IsChecked = service == state };
            item.Click += async (_, _) => { if (!settings.Workspace.Panes.Contains(state.Definition.Id)) return; await SelectService(state); await SelectService(service); }; choose.Items.Add(item);
        }
        return choose;
    }
    private async Task AddPane(ServiceState state)
    {
        if (!services.Contains(state) || !settings.Workspace.Add(state.Definition.Id)) return;
        await SelectService(state);
    }
    private void ClosePane(ServiceState state)
    {
        settings.Workspace.Remove(state.Definition.Id);
        if (state == selected)
        {
            var next = PaneServices().FirstOrDefault();
            if (next != null) _ = SelectService(next); else ShowActivity();
        }
        RebuildPaneChrome(); settings.Save();
    }
    private void PaneActionsClick(object sender, RoutedEventArgs e)
    {
        if (selected != null) OpenPaneMenu(PaneActionsButton, selected);
    }
    private void OpenPaneMenu(Button anchor, ServiceState state)
    {
        var menu = new ContextMenu();
        menu.Items.Add(PaneServiceChoices(state));
        var retry = new MenuItem { Header = "Reload" }; retry.Click += async (_, _) => { await SelectService(state); ReloadClick(this, new RoutedEventArgs()); }; menu.Items.Add(retry);
        menu.Items.Add(new Separator());
        foreach (int offset in new[] { -1, 1 })
        {
            int index = settings.Workspace.Panes.IndexOf(state.Definition.Id), target = index + offset;
            var move = new MenuItem { Header = offset < 0 ? "Move earlier" : "Move later", IsEnabled = target >= 0 && target < settings.Workspace.Panes.Count };
            move.Click += (_, _) => MovePane(state, offset); menu.Items.Add(move);
        }
        menu.Items.Add(new Separator());
        var solo = new MenuItem { Header = "Only this pane" }; solo.Click += async (_, _) => await SoloPane(state); menu.Items.Add(solo);
        var close = new MenuItem { Header = "Close pane" }; close.Click += (_, _) => ClosePane(state); menu.Items.Add(close);
        menu.PlacementTarget = anchor; menu.Placement = PlacementMode.Bottom; anchor.ContextMenu = menu; menu.IsOpen = true;
    }
    private void AddPaneClick(object sender, RoutedEventArgs e)
    {
        CloseWorkspacePicker();
        var menu = new ContextMenu();
        foreach (var state in OrderedServices().Where(s => !settings.Workspace.Panes.Contains(s.Definition.Id)))
        { var item = new MenuItem { Header = state.Definition.Name, Icon = ServiceIcon(state, 16) }; item.Click += async (_, _) => await AddPane(state); menu.Items.Add(item); }
        menu.PlacementTarget = WorkspaceLayoutButton; menu.Placement = settings.TopTabs ? PlacementMode.Bottom : PlacementMode.Right; menu.IsOpen = true;
    }
}
