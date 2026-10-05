using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using System.Windows.Controls.Primitives;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckWorkspacePanes(string output)
    {
        var ids = new[] { "a", "b", "c", "d", "e" };
        var model = new WorkspaceLayout { Panes = ["stale", "a", "a", "b", "c", "d", "e"], Arrangement = "unknown", Primary = double.NaN };
        model.Normalize(ids);
        Check(model.Panes.SequenceEqual(ids.Take(4)) && model.Arrangement == "grid", "Workspace drops stale/duplicate IDs and caps restored panes at four");
        Check(!model.Add("a") && !model.Add("e"), "Duplicate and fifth-pane additions are no-ops");
        model.Select("e", "b");
        Check(model.Panes.SequenceEqual(new[] { "a", "e", "c", "d" }), "Sidebar replaces only the focused pane");
        model.Select("a", "e");
        Check(model.Panes.Count == 4 && model.Panes[1] == "e", "Selecting an existing pane keeps the arrangement");
        foreach (var arrangement in WorkspaceLayout.Arrangements)
        for (int count = 1; count <= 4; count++)
        {
            model = new WorkspaceLayout { Panes = ids.Take(count).ToList(), Arrangement = arrangement };
            model.Normalize(ids);
            foreach (var divider in model.Dividers()) model.Resize(divider.Index, 0.72);
            var cells = Enumerable.Range(0, count).Select(model.Cell).ToArray();
            Check(Math.Abs(cells.Sum(c => c.Width * c.Height) - 1) < 0.000001, "Resized " + arrangement + " tiles the full workspace at count " + count);
            for (int i = 0; i < count; i++)
            {
                var a = cells[i];
                Check(a.X >= 0 && a.Y >= 0 && a.Width > 0 && a.Height > 0 && a.X + a.Width <= 1.000001 && a.Y + a.Height <= 1.000001, "Pane geometry stays in bounds");
                for (int j = i + 1; j < count; j++)
                { var b = cells[j]; Check(Math.Min(a.X + a.Width, b.X + b.Width) <= Math.Max(a.X, b.X) + 0.000001 || Math.Min(a.Y + a.Height, b.Y + b.Height) <= Math.Max(a.Y, b.Y) + 0.000001, "Pane geometry never overlaps"); }
            }
            foreach (var divider in model.Dividers()) { model.Resize(divider.Index, -100); model.Resize(divider.Index, 100); model.Resize(divider.Index, double.NaN); }
            Check(Enumerable.Range(0, count).All(i => model.Cell(i).Width >= 0.099 && model.Cell(i).Height >= 0.099), "Divider clamps prevent collapsed panes");
        }
        var states = services.Take(4).ToArray();
        settings.Workspace = new();
        await SelectService(states[0]);
        for (int i = 1; i < 4; i++) await AddPane(states[i]);
        await Until(() => states.All(s => s.Core != null && !s.Loading));
        var views = states.Select(s => s.View).ToArray();
        for (int i = 0; i < 4; i++) await states[i].Core!.ExecuteScriptAsync("window.__paneToken=" + i);
        await CheckNativePaneFocus(states);
        await CheckCompactPaneControls(states);
        await CheckWorkspacePicker(output);
        await AddPane(services[4]);
        Check(settings.Workspace.Panes.Count == 4 && !settings.Workspace.Panes.Contains(services[4].Definition.Id), "Runtime rejects a fifth pane");
        foreach (var arrangement in WorkspaceLayout.Arrangements)
        {
            settings.Workspace.Arrangement = arrangement; settings.Workspace.Cuts.Clear(); RebuildPaneChrome();
            WebHost.UpdateLayout();
            var drag = paneDividers[0];
            double beforeDrag = drag.Divider.Index < 0 ? settings.Workspace.Primary : settings.Workspace.Cuts[drag.Divider.Index];
            drag.Thumb.RaiseEvent(new DragDeltaEventArgs(drag.Divider.Vertical ? 24 : 0, drag.Divider.Vertical ? 0 : 24) { RoutedEvent = Thumb.DragDeltaEvent });
            drag.Thumb.RaiseEvent(new DragCompletedEventArgs(24, 24, false) { RoutedEvent = Thumb.DragCompletedEvent });
            double afterDrag = drag.Divider.Index < 0 ? settings.Workspace.Primary : settings.Workspace.Cuts[drag.Divider.Index];
            Check(afterDrag > beforeDrag, "Divider drag events resize the workspace");
            foreach (var divider in settings.Workspace.Dividers()) settings.Workspace.Resize(divider.Index, 0.68);
            ArrangePanes();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(states.All(s => s.View!.Visibility == Visibility.Visible), "All four services stay visible in " + arrangement);
            foreach (var (thumb, _) in paneDividers)
            {
                var point = thumb.TransformToAncestor(this).Transform(new Point(thumb.ActualWidth / 2, thumb.ActualHeight / 2));
                Check(!NativeChildAt(this, point), "Native browser content leaves the draggable divider accessible");
            }
            for (int i = 0; i < 4; i++) Check(states[i].View == views[i] && await states[i].Core!.ExecuteScriptAsync("window.__paneToken") == i.ToString(), "Arrangement and resizing preserve live documents");
        }
        settings.Workspace.Arrangement = "grid"; settings.Workspace.Cuts.Clear(); RebuildPaneChrome();
        settings.Workspace.Resize(-1, 0.65); settings.Workspace.Resize(0, 0.4); ArrangePanes(); settings.Save();
        var restored = Settings.Load().Workspace;
        Check(restored.Panes.SequenceEqual(settings.Workspace.Panes) && restored.Primary == 0.65 && restored.Cuts[0] == 0.4, "Workspace arrangement and divider proportions survive saving");
        foreach (var state in states) { state.Options.KeepLive = false; state.HiddenAt = DateTime.UtcNow.AddMinutes(-5); }
        await SuspendIdle();
        Check(states.All(s => !s.Suspended), "Every visible pane is protected from idle suspension");
        ShowActivity();
        Check(states.All(s => s.View!.Visibility == Visibility.Hidden), "Local pages hide every pane without unloading it");
        var messenger = states.Single(s => s.Definition.IconId == "messenger");
        var messengerMenu = railButtons[messenger.Definition.Id].ContextMenu;
        var refreshMessenger = messengerMenu.Items.OfType<MenuItem>().Single(item => Equals(item.Header, "Refresh Messenger display"));
        messengerMenu.RaiseEvent(new RoutedEventArgs(ContextMenu.OpenedEvent));
        Check(!refreshMessenger.IsEnabled, "Hidden Messenger panes disable manual display refresh");
        var hiddenEvents = ReportEvents.Snapshot();
        await RefreshMessengerDisplay(messenger);
        Check(ReportEvents.Snapshot() == hiddenEvents, "Stale refresh commands ignore hidden Messenger panes");
        await SelectService(states[1]);
        Check(states.All(s => s.View!.Visibility == Visibility.Visible), "Returning restores the whole workspace");
        messengerMenu.RaiseEvent(new RoutedEventArgs(ContextMenu.OpenedEvent));
        Check(selected != messenger && refreshMessenger.IsEnabled, "Visible Messenger panes allow display refresh without taking focus");
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "workspace-four-panes.png"));
        PaneActionsButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var close = PaneActionsButton.ContextMenu.Items.OfType<MenuItem>().Single(item => Equals(item.Header, "Close pane"));
        PaneActionsButton.ContextMenu.IsOpen = false;
        close.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        ClosePane(states[1]);
        Check(settings.Workspace.Panes.Count == 3 && selected != states[1] && states[1].Core != null, "Closing an active pane selects a survivor, preserves its account, and ignores duplicates");
        var focused = selected;
        states[1].View!.RaiseEvent(new RoutedEventArgs(UIElement.GotFocusEvent));
        Check(selected == focused && settings.Workspace.Panes.Count == 3, "Late focus events from a closed pane cannot replace the active pane");
        DisconnectService(states[2]);
        Check(!settings.Workspace.Panes.Contains(states[2].Definition.Id), "Unloading removes stale workspace IDs");
        settings.Workspace.Panes = [states[0].Definition.Id];
        foreach (var state in states) state.Options.KeepLive = true;
        await SelectService(states[0]);
        Check(paneDividers.Count == 0 && PaneActionsButton.Visibility == Visibility.Collapsed && states[0].View!.Visibility == Visibility.Visible, "Single-pane mode clears divider controls");
    }
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    private async Task ClickNativePane(ServiceState state)
    {
        Activate(); SetForegroundWindow(new WindowInteropHelper(this).Handle);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        var screen = state.View!.PointToScreen(new Point(state.View.ActualWidth / 2, state.View.ActualHeight / 2));
        var target = state.View.Handle;
        var local = new ResizePoint();
        for (int depth = 0; depth < 16; depth++)
        {
            local = new ResizePoint { X = (int)screen.X, Y = (int)screen.Y };
            Check(ScreenToClient(target, ref local), "Native pane click converts to child coordinates");
            var child = ChildWindowFromPointEx(target, local, 1);
            if (child == IntPtr.Zero || child == target) break;
            target = child;
        }
        Check(target != new WindowInteropHelper(this).Handle, "Pane click targets an actual native browser child");
        var packed = new IntPtr((local.Y << 16) | (local.X & 0xffff));
        SendMessage(target, 0x0201, new IntPtr(1), packed);
        SendMessage(target, 0x0202, IntPtr.Zero, packed);
    }
    private async Task CheckNativePaneFocus(ServiceState[] states)
    {
        foreach (var state in states)
            await state.Core!.ExecuteScriptAsync("document.body.innerHTML='<input id=focusDraft value=Unsent style=\"position:fixed;inset:0;width:100%;height:100%;box-sizing:border-box\">'; window.paneClicks=0; document.addEventListener('click',e=>{if(e.isTrusted) window.paneClicks++})");
        await SelectService(states[0]);
        var order = settings.Workspace.Panes.ToArray();
        var dividers = paneDividers.Select(d => d.Thumb).ToArray();
        foreach (var state in new[] { states[1], states[2], states[0], states[3], states[1] })
        {
            await ClickNativePane(state);
            await Until(() => selected == state);
            Check(Settings.Load().Selected == state.Definition.Id && ServiceCaptionName.Text == state.Definition.Name,
                "Native browser clicks move the focused-pane caption and persisted selection");
            Check(await state.Core!.ExecuteScriptAsync("document.activeElement.id==='focusDraft' && document.getElementById('focusDraft').value==='Unsent' && window.paneClicks>0") == "true",
                "A native click reaches the page and preserves its input focus and draft");
        }
        Check(settings.Workspace.Panes.SequenceEqual(order) && paneDividers.Select(d => d.Thumb).SequenceEqual(dividers),
            "Focus changes do not rebuild or reorder the workspace");
        states[1].View!.RaiseEvent(new RoutedEventArgs(UIElement.GotFocusEvent));
        using var obsolete = new Microsoft.Web.WebView2.Wpf.WebView2();
        FocusPane(states[0], obsolete);
        Check(selected == states[1], "Duplicate and replaced-browser focus notifications cannot steal selection");
        OpenWorkspacePicker();
        workspaceAccountButtons[states[2]].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(workspacePicker!.IsOpen && selected == states[2] && workspacePaneButtons.Count == 5,
            "Layout can choose another pane while keeping its focused controls open");
        workspaceAccountButtons[states[0]].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(!workspacePaneButtons["earlier"].IsEnabled && workspacePaneButtons["later"].IsEnabled, "Focused move actions respect pane order");
        workspacePaneButtons["later"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Until(() => !paneRendering);
        Check(settings.Workspace.Panes[1] == states[0].Definition.Id && selected == states[0], "Layout reorders the chosen pane without changing focus");
        MovePane(states[0], -1); await Until(() => !paneRendering);
        ShowActivity();
        states[2].View!.RaiseEvent(new RoutedEventArgs(UIElement.GotFocusEvent));
        Check(selected == null, "Hidden browser focus cannot reopen a workspace from a local page");
        await SelectService(states[1]);
    }
    private async Task CheckCompactPaneControls(ServiceState[] states)
    {
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        foreach (var state in states)
        {
            var cell = settings.Workspace.Cell(settings.Workspace.Panes.IndexOf(state.Definition.Id));
            Check(Math.Abs(state.View!.ActualHeight - (cell.Height * WebHost.ActualHeight - 6)) < 2
                && Math.Abs(state.View.TranslatePoint(new Point(), WebHost).Y - (cell.Y * WebHost.ActualHeight + 3)) < 2,
                "Pane browsers reclaim the title strip and retain only the resize gutter");
        }
        await SelectService(states[1]);
        Check(PaneActionsButton.IsVisible && Equals(paneOutlines[states[1]].BorderBrush, Brush("Accent"))
            && Equals(paneOutlines[states[0]].BorderBrush, Brush("Line")), "The compact title-bar control and outline follow pane focus");
        Check(!NativeChildAt(this, PaneActionsButton.TranslatePoint(new Point(14, 14), this)), "Native browser content cannot cover pane actions");
        OpenWorkspacePicker();
        ((MenuItem)WorkspaceLayoutButton.ContextMenu.Items[0]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Check(Settings.Load().HideLayoutButton && WorkspaceLayoutButton.Visibility == Visibility.Collapsed && workspacePicker?.IsOpen == false,
            "Right-click Hide persists and dismisses an open layout picker");
        BuildRail(); SetTopTabs(true);
        Check(WorkspaceLayoutButton.Visibility == Visibility.Collapsed && settings.Workspace.Panes.Count == 4 && states.All(s => s.View!.Visibility == Visibility.Visible),
            "Rail rebuild and orientation preserve hiding without disturbing live panes");
        RefreshSidebarContextMenu();
        var restore = SidebarFrame.ContextMenu.Items.OfType<MenuItem>().Single(item => Equals(item.Header, "Show Layout button"));
        restore.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Check(!Settings.Load().HideLayoutButton && WorkspaceLayoutButton.Visibility == Visibility.Visible, "The rail context menu restores Layout and persists the choice");
        SetTopTabs(false);
        ShowActivity();
        Check(PaneActionsButton.Visibility == Visibility.Collapsed, "Local pages clear the focused-pane control");
        await SelectService(states[1]);
    }
    private async Task CheckWorkspacePicker(string output)
    {
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(WorkspaceLayoutButton.TranslatePoint(new Point(), SidebarHeading).Y >= ActivityButton.ActualHeight,
            "The layout picker sits directly beneath Activity");
        OpenWorkspacePicker();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(workspacePicker?.IsOpen == true && workspaceLayoutTiles.Count == 6 && workspaceAddButton?.IsEnabled == false,
            "Visual layout picker exposes six shapes and disables adding a fifth pane");
        Check(workspaceLayoutTiles.All(b => b.Content is Canvas), "Layout choices are drawn shapes, not text rows");
        CaptureElement((FrameworkElement)workspacePicker!.Child, Path.Combine(output, "layout-picker-dark.png"));
        workspaceLayoutTiles[1].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(workspacePicker.IsOpen == false && settings.Workspace.Arrangement == "columns", "Choosing a drawn preset closes the flyout and applies its layout");
        SetWorkspaceArrangement("rows"); SetWorkspaceArrangement("main-left");
        await Until(() => !paneRendering);
        Check(settings.Workspace.Arrangement == "main-left" && paneMotionFrom.Count == 0, "Rapid preset changes finish at the latest arrangement without a stale animation");
        WebHost.UpdateLayout();
        var first = PaneServices().First();
        Check(Math.Abs(first.View!.ActualWidth - (WebHost.ActualWidth * 0.6 - 6)) < 2 && paneDividers.All(d => d.Thumb.Visibility == Visibility.Visible), "Animated browsers land on exact native bounds and restore resize handles");
        SetWorkspaceArrangement("grid");
        ShowActivity();
        Check(!paneRendering && paneMotionFrom.Count == 0 && workspacePicker.IsOpen == false, "Leaving the workspace cancels pending animation and closes the picker");
        await SelectService(first);
        SetWorkspaceArrangement("grid"); await Until(() => !paneRendering);
        WebHost.UpdateLayout();
        var drag = paneDividers[0];
        double start = drag.Thumb.TranslatePoint(new Point(3, 3), WebHost).X / WebHost.ActualWidth;
        drag.Thumb.RaiseEvent(new DragDeltaEventArgs(8, 0) { RoutedEvent = Thumb.DragDeltaEvent });
        drag.Thumb.RaiseEvent(new DragDeltaEventArgs(16, 0) { RoutedEvent = Thumb.DragDeltaEvent });
        Check(Math.Abs(settings.Workspace.Primary - (start + 16 / WebHost.ActualWidth)) < 0.00001,
            "Coalesced pointer events use the displayed divider origin instead of accumulating stale deltas");
        drag.Thumb.RaiseEvent(new DragCompletedEventArgs(16, 0, false) { RoutedEvent = Thumb.DragCompletedEvent });
        Check(!paneRendering && Settings.Load().Workspace.Primary == settings.Workspace.Primary, "Drag completion flushes the final frame and saves its exact size");
        var appearance = settings.Appearance;
        settings.Appearance = "Light"; ApplyTheme(); OpenWorkspacePicker();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CaptureElement((FrameworkElement)workspacePicker!.Child, Path.Combine(output, "layout-picker-light.png"));
        CloseWorkspacePicker(); settings.Appearance = appearance; ApplyTheme();
        SetTopTabs(true); Width = 720;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        OpenWorkspacePicker();
        Check(workspacePicker!.Placement == PlacementMode.Bottom && WorkspaceLayoutButton.ActualWidth > 0, "Top tabs place the same graphical picker beside Activity and below the rail");
        CaptureElement((FrameworkElement)workspacePicker.Child, Path.Combine(output, "layout-picker-narrow.png"));
        var surface = (FrameworkElement)workspacePicker.Child;
        surface.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(surface), 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        Check(!workspacePicker.IsOpen, "Escape dismisses the graphical picker");
        SetTopTabs(false); Width = 1280;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }

}
