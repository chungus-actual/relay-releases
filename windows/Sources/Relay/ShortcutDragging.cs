using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private Button? draggedButton;
    private int dragOrigin, dragDestination;
    private double dragGrab, dragPitch;
    private readonly DispatcherTimer shortcutDragTimer = new(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(16) };

    private double DragAxis(Point point) => settings.TopTabs ? point.X : point.Y;
    private DependencyProperty DragProperty => settings.TopTabs ? TranslateTransform.XProperty : TranslateTransform.YProperty;
    private double DragOffset => settings.TopTabs ? ServiceRailScroll.HorizontalOffset : ServiceRailScroll.VerticalOffset;
    private double DragViewport => settings.TopTabs ? ServiceRailScroll.ViewportWidth : ServiceRailScroll.ViewportHeight;
    private void ScrollDrag(double offset)
    {
        if (settings.TopTabs) ServiceRailScroll.ScrollToHorizontalOffset(offset);
        else ServiceRailScroll.ScrollToVerticalOffset(offset);
    }

    private void InitializeShortcutDragging()
    {
        shortcutDragTimer.Tick += (_, _) =>
        {
            if (draggingShortcut == null) return;
            if (Mouse.LeftButton != MouseButtonState.Pressed) { FinishShortcutDrag(false); return; }
            var point = Mouse.GetPosition(ServiceRailScroll);
            double axis = DragAxis(point);
            if (axis < 24) ScrollDrag(DragOffset - 7);
            else if (axis > DragViewport - 24) ScrollDrag(DragOffset + 7);
            UpdateShortcutDrag(axis);
        };
        ServiceRailScroll.PreviewMouseWheel += (_, e) => { if (settings.TopTabs) { ScrollDrag(DragOffset - e.Delta); e.Handled = true; } };
        Deactivated += (_, _) => FinishShortcutDrag(false);
        PreviewKeyDown += (_, e) => { if (draggingShortcut != null && e.Key == Key.Escape) { FinishShortcutDrag(false); e.Handled = true; } };
    }

    private Dictionary<string, double> RailPositions() => railButtons.ToDictionary(pair => pair.Key,
        pair => DragAxis(pair.Value.TranslatePoint(new Point(), ServiceRail)));

    private void AnimateRailFrom(Dictionary<string, double> previous)
    {
        ServiceRail.UpdateLayout();
        foreach (var (id, button) in railButtons)
        {
            if (!previous.TryGetValue(id, out double y)) continue;
            double offset = y - DragAxis(button.TranslatePoint(new Point(), ServiceRail));
            var transform = new TranslateTransform(); button.RenderTransform = transform;
            if (SystemParameters.ClientAreaAnimation && Math.Abs(offset) > 0.1)
                transform.BeginAnimation(DragProperty, new DoubleAnimation(offset, 0, TimeSpan.FromMilliseconds(170))
                    { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
        }
    }

    private void BeginShortcutDrag(Button button, ServiceState state, double grab, bool capturePointer = true)
    {
        ServiceRail.UpdateLayout();
        draggingShortcut = state; draggedButton = button;
        dragOrigin = dragDestination = Array.IndexOf(shortcutServices, state);
        dragPitch = settings.TopTabs ? button.ActualWidth + button.Margin.Left + button.Margin.Right : button.ActualHeight + button.Margin.Top + button.Margin.Bottom;
        dragGrab = grab;
        foreach (var item in railButtons.Values)
        {
            item.RenderTransform = new TranslateTransform();
            ToolTipService.SetIsEnabled(item, false);
        }
        button.SetResourceReference(Button.BorderBrushProperty, "Accent");
        Panel.SetZIndex(button, 1);
        button.Cursor = settings.TopTabs ? Cursors.SizeWE : Cursors.SizeNS;
        if (capturePointer) { Mouse.Capture(button, CaptureMode.Element); shortcutDragTimer.Start(); }
    }

    private void UpdateShortcutDrag(double viewportPosition)
    {
        if (draggingShortcut == null || draggedButton == null) return;
        double maxTop = Math.Max(0, (settings.TopTabs ? ServiceRail.ActualWidth : ServiceRail.ActualHeight) - dragPitch);
        double top = Math.Clamp(viewportPosition + DragOffset - dragGrab,
            Math.Min(DragOffset, maxTop),
            Math.Min(maxTop, Math.Max(DragOffset, DragOffset + DragViewport - dragPitch)));
        ((TranslateTransform)draggedButton.RenderTransform).SetValue(DragProperty, top - dragOrigin * dragPitch);
        int destination = Math.Clamp((int)Math.Round(top / dragPitch), 0, shortcutServices.Length - 1);
        if (destination == dragDestination) return;
        dragDestination = destination;
        for (int i = 0; i < shortcutServices.Length; i++)
        {
            if (i == dragOrigin) continue;
            double offset = i > dragOrigin && i <= destination ? -dragPitch : i < dragOrigin && i >= destination ? dragPitch : 0;
            var transform = (TranslateTransform)railButtons[shortcutServices[i].Definition.Id].RenderTransform;
            if (SystemParameters.ClientAreaAnimation)
                transform.BeginAnimation(DragProperty, new DoubleAnimation(offset, TimeSpan.FromMilliseconds(140))
                    { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            else transform.SetValue(DragProperty, offset);
        }
    }

    private void FinishShortcutDrag(bool commit)
    {
        if (draggingShortcut == null) return;
        var source = draggingShortcut;
        var target = shortcutServices[dragDestination];
        bool after = dragDestination > dragOrigin;
        var positions = RailPositions();
        shortcutDragTimer.Stop();
        draggingShortcut = null;
        var button = draggedButton; draggedButton = null;
        foreach (var item in railButtons.Values)
        {
            item.RenderTransform = new TranslateTransform();
            ToolTipService.SetIsEnabled(item, true);
            Panel.SetZIndex(item, 0);
        }
        button?.ClearValue(Button.BorderBrushProperty);
        button?.ClearValue(CursorProperty);
        button?.ReleaseMouseCapture();
        try
        {
            if (commit && source != target) MoveShortcut(source, target, after, positions);
            else AnimateRailFrom(positions);
        }
        catch (Exception ex)
        {
            AnimateRailFrom(positions);
            if (App.SmokeTest) throw;
            MessageBox.Show(this, ex.Message, "Couldn't move shortcut", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }
}
