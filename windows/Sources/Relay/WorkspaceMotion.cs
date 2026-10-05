using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private readonly Dictionary<string, WorkspaceLayout.CellRect> presentedPaneCells = [];
    private readonly Dictionary<string, WorkspaceLayout.CellRect> paneMotionFrom = [];
    private long paneMotionStart;
    private bool paneRendering, paneArrangeQueued;
    private const double PaneTransitionSeconds = 0.18;

    private WorkspaceLayout.CellRect PresentedPaneCell(string id, WorkspaceLayout.CellRect target)
    {
        var cell = target;
        if (paneMotionFrom.TryGetValue(id, out var from))
        {
            double t = Math.Clamp(Stopwatch.GetElapsedTime(paneMotionStart).TotalSeconds / PaneTransitionSeconds, 0, 1);
            double eased = 1 - Math.Pow(1 - t, 3);
            cell = new(from.X + (target.X - from.X) * eased, from.Y + (target.Y - from.Y) * eased,
                from.Width + (target.Width - from.Width) * eased, from.Height + (target.Height - from.Height) * eased);
        }
        presentedPaneCells[id] = cell;
        return cell;
    }
    private void AnimatePaneChange(Action change)
    {
        StopPaneMotion();
        if (SystemParameters.ClientAreaAnimation && IsVisible && selected != null)
            foreach (var state in PaneServices())
                if (presentedPaneCells.TryGetValue(state.Definition.Id, out var cell)) paneMotionFrom[state.Definition.Id] = cell;
        paneMotionStart = Stopwatch.GetTimestamp();
        change();
        if (paneMotionFrom.Count > 0) QueuePaneArrange();
    }
    // A burst of pointer events needs one native browser layout per display frame.
    private void QueuePaneArrange()
    {
        paneArrangeQueued = true;
        if (paneRendering) return;
        paneRendering = true;
        CompositionTarget.Rendering += RenderPaneFrame;
    }
    private void RenderPaneFrame(object? sender, EventArgs e)
    {
        if (quitting || selected == null) { StopPaneMotion(); return; }
        bool moving = paneMotionFrom.Count > 0;
        if (moving && Stopwatch.GetElapsedTime(paneMotionStart).TotalSeconds >= PaneTransitionSeconds) paneMotionFrom.Clear();
        if (paneArrangeQueued || moving) { paneArrangeQueued = false; ArrangePanes(); }
        if (paneMotionFrom.Count == 0 && !paneArrangeQueued) StopPaneMotion();
    }
    private void StopPaneMotion()
    {
        if (paneRendering) CompositionTarget.Rendering -= RenderPaneFrame;
        paneRendering = false; paneArrangeQueued = false; paneMotionFrom.Clear();
    }
}
