using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private ServiceState[] shortcutServices = [];
    private ServiceState? draggingShortcut;

    internal static List<string> NormalizeServiceOrder(IEnumerable<string> requested, IEnumerable<string> available)
    {
        var known = available.ToList();
        var result = requested.Where(known.Contains).Distinct(StringComparer.Ordinal).ToList();
        result.AddRange(known.Where(id => !result.Contains(id)));
        return result;
    }
    private ServiceState[] OrderedServices() => settings.ServiceOrder.Select(id => services.Single(s => s.Definition.Id == id)).ToArray();
    private void InitializeShortcutOrder()
    {
        settings.ServiceOrder = NormalizeServiceOrder(settings.ServiceOrder, services.Select(s => s.Definition.Id));
        shortcutServices = OrderedServices().Where(s => s.Options.ShowShortcut).ToArray();
    }
    private void RebuildShortcuts()
    {
        InitializeShortcutOrder();
        BuildRail();
        BuildTrayMenu();
        if (localPage == "settings") RebuildSettings();
    }
    private void SetShortcutVisible(ServiceState state, bool visible)
    {
        bool previous = state.Options.ShowShortcut;
        state.Options.ShowShortcut = visible;
        try { settings.Save(); }
        catch { state.Options.ShowShortcut = previous; throw; }
        if (!visible && selected == state) ShowActivity();
        RebuildShortcuts();
    }
    private void MoveShortcut(ServiceState source, ServiceState target, bool after, Dictionary<string, double>? positions = null)
    {
        if (source == target || !source.Options.ShowShortcut || !target.Options.ShowShortcut) return;
        positions ??= RailPositions();
        var old = settings.ServiceOrder.ToList();
        settings.ServiceOrder.Remove(source.Definition.Id);
        int index = settings.ServiceOrder.IndexOf(target.Definition.Id);
        settings.ServiceOrder.Insert(index + (after ? 1 : 0), source.Definition.Id);
        try { settings.Save(); }
        catch { settings.ServiceOrder = old; throw; }
        RebuildShortcuts();
        AnimateRailFrom(positions);
    }
    private void MoveShortcutBy(ServiceState state, int delta)
    {
        int index = Array.IndexOf(shortcutServices, state);
        int next = index + delta;
        if (index < 0 || next < 0 || next >= shortcutServices.Length) return;
        MoveShortcut(state, shortcutServices[next], delta > 0);
    }
    private void SidebarContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        for (var element = e.OriginalSource as DependencyObject; element != null && element != SidebarFrame;
             element = element is Visual ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element))
        {
            if (element is System.Windows.Controls.Primitives.ButtonBase button)
            {
                // Service buttons keep their own menus; utility buttons are not empty rail space.
                if (button.ContextMenu == null) e.Handled = true;
                return;
            }
            if (element == UsageHover) { e.Handled = true; return; }
        }
        var menu = SidebarFrame.ContextMenu;
        menu.Items.Clear();
        foreach (var state in OrderedServices().Where(s => !s.Options.ShowShortcut))
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            var icon = ServiceIcon(state, 16); icon.Margin = new Thickness(0, 0, 10, 0);
            content.Children.Add(icon); content.Children.Add(Label(state.Definition.Name, 12));
            var item = new MenuItem { Header = content };
            System.Windows.Automation.AutomationProperties.SetName(item, state.Definition.Name);
            item.Click += async (_, _) => await OpenHiddenService(state);
            menu.Items.Add(item);
        }
        if (menu.Items.Count == 0) menu.Items.Add(new MenuItem { Header = "Nothing hidden", IsEnabled = false });
    }

    private async System.Threading.Tasks.Task OpenHiddenService(ServiceState state)
    {
        SetShortcutVisible(state, true);
        await SelectService(state);
    }

    private void ConfigureShortcut(Button button, ServiceState state)
    {
        Point? start = null;
        double grabY = 0;
        button.PreviewMouseLeftButtonDown += (_, e) => { start = e.GetPosition(ServiceRailScroll); grabY = DragAxis(e.GetPosition(button)); };
        button.PreviewMouseLeftButtonUp += (_, e) =>
        {
            start = null;
            if (draggingShortcut != state) return;
            e.Handled = true; FinishShortcutDrag(true);
        };
        button.PreviewMouseMove += (_, e) =>
        {
            if (draggingShortcut == state && e.LeftButton == MouseButtonState.Pressed) { UpdateShortcutDrag(DragAxis(e.GetPosition(ServiceRailScroll))); e.Handled = true; return; }
            if (start is not { } point || e.LeftButton != MouseButtonState.Pressed || draggingShortcut != null) return;
            var current = e.GetPosition(ServiceRailScroll);
            if (Math.Abs(current.X - point.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(current.Y - point.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            start = null; e.Handled = true;
            BeginShortcutDrag(button, state, grabY);
            UpdateShortcutDrag(DragAxis(current));
        };
        button.LostMouseCapture += (_, _) => { start = null; if (draggingShortcut == state) FinishShortcutDrag(false); };
        button.PreviewKeyDown += (_, e) =>
        {
            if (Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && e.Key is Key.Up or Key.Down or Key.Left or Key.Right)
            {
                MoveShortcutBy(state, e.Key is Key.Up or Key.Left ? -1 : 1);
                railButtons[state.Definition.Id].Focus(); e.Handled = true;
            }
        };
        var menu = new ContextMenu();
        menu.SetResourceReference(ContextMenu.BackgroundProperty, "Card"); menu.SetResourceReference(ContextMenu.ForegroundProperty, "Ink"); menu.SetResourceReference(ContextMenu.BorderBrushProperty, "Line");
        var up = new MenuItem { Header = settings.TopTabs ? "Move left" : "Move up", InputGestureText = settings.TopTabs ? "Ctrl+Shift+←" : "Ctrl+Shift+↑" }; up.Click += (_, _) => MoveShortcutBy(state, -1);
        var down = new MenuItem { Header = settings.TopTabs ? "Move right" : "Move down", InputGestureText = settings.TopTabs ? "Ctrl+Shift+→" : "Ctrl+Shift+↓" }; down.Click += (_, _) => MoveShortcutBy(state, 1);
        var hide = new MenuItem { Header = "Hide shortcut" }; hide.Click += (_, _) => SetShortcutVisible(state, false);
        var connection = new MenuItem { Header = state.Options.Enabled ? "Unload" : "Load" };
        connection.Click += async (_, _) =>
        {
            try { await ToggleServiceConnection(state); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Couldn't change connection", MessageBoxButton.OK, MessageBoxImage.Information); }
        };
        var dismiss = new MenuItem { Header = "Dismiss" }; dismiss.Click += (_, _) => DismissService(state);
        var audio = new MenuItem(); audio.Click += (_, _) => SetAudioMuted(state, !state.Options.AudioMuted);
        var another = new MenuItem { Header = "Add account" }; another.Click += (_, _) => ShowAccountEditor(initial: state.Definition);
        var rename = new MenuItem { Header = "Rename" }; rename.Click += (_, _) => ShowAccountEditor(state);
        menu.Items.Add(connection); menu.Items.Add(audio); menu.Items.Add(dismiss); menu.Items.Add(CreateZoomMenu(state)); menu.Items.Add(another); menu.Items.Add(rename); menu.Items.Add(new Separator());
        menu.Items.Add(up); menu.Items.Add(down); menu.Items.Add(new Separator()); menu.Items.Add(hide);
        menu.Opened += (_, _) => { dismiss.IsEnabled = state.Unread > 0 || state.Attention || activity.Any(item => item.Service == state); connection.Header = state.Options.Enabled ? "Unload" : "Load"; audio.Header = state.Options.AudioMuted ? "Unmute audio" : "Mute audio"; int index = Array.IndexOf(shortcutServices, state); up.IsEnabled = index > 0; down.IsEnabled = index < shortcutServices.Length - 1; };
        button.ContextMenu = menu;
    }
}
