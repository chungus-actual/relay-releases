using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private void HandleProcessFailure(ServiceState state, Task<CoreWebView2Environment>? runtime, CoreWebView2ProcessFailedKind kind)
    {
        if (quitting || !state.Options.Enabled) return;
        if (kind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
        {
            if (!ReferenceEquals(runtime, environment)) return;
            environment = null;
            foreach (var affected in services.Where(s => s.Options.Enabled && s.View != null).ToArray()) QueueRecovery(affected);
        }
        else if (kind is CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.FrameRenderProcessExited) QueueRecovery(state);
        // Chromium replaces GPU/helper processes itself. Do not reload healthy pages for those events.
    }

    private void QueueRecovery(ServiceState state)
    {
        if (quitting || !state.Options.Enabled) return;
        state.NeedsRestart = true; state.Unread = null;
        if (state.Recovering) return;
        state.Recovering = true;
        int generation = ++state.RecoveryGeneration;
        _ = RecoverService(state, generation);
    }

    private async Task RecoverService(ServiceState state, int generation)
    {
        bool Current() => !quitting && state.Options.Enabled && state.RecoveryGeneration == generation;
        try
        {
            while (Current())
            {
                var now = DateTime.UtcNow;
                while (state.RecoveryAttempts.TryPeek(out var attempt) && now - attempt > TimeSpan.FromMinutes(2)) state.RecoveryAttempts.Dequeue();
                if (state.RecoveryAttempts.Count >= 3)
                {
                    state.Status = "Recovery paused";
                    if (selected == state) { ErrorText.Text = "Recovery paused"; ErrorPanel.Visibility = Visibility.Visible; }
                    return;
                }
                int delay = state.RecoveryAttempts.Count switch { 0 => 1, 1 => 3, _ => 10 };
                state.RecoveryAttempts.Enqueue(now);
                state.Status = "Reconnecting…"; Refresh();
                await Task.Delay(TimeSpan.FromSeconds(delay));
                if (!Current()) return;
                ReleaseServiceViews(state);
                state.NeedsRestart = false;
                await EnsureService(state);
                if (!Current()) return;
                if (state.Core != null && !state.NeedsRestart)
                {
                    if (selected == state) ErrorPanel.Visibility = Visibility.Collapsed;
                    return;
                }
                state.NeedsRestart = true;
            }
        }
        catch (Exception ex)
        {
            if (Current()) { state.NeedsRestart = true; state.Status = "Recovery paused"; Log(ex); }
        }
        finally
        {
            if (state.RecoveryGeneration == generation) { state.Recovering = false; Refresh(); }
        }
    }

    private void ReleaseServiceViews(ServiceState state)
    {
        StopAccountDownloads(state);
        foreach (var popup in popups.Where(p => p.Tag == state).ToArray()) popup.Close();
        var view = state.View; state.View = null;
        if (view != null)
        {
            if (FocusManager.GetFocusedElement(this) == view) FocusManager.SetFocusedElement(this, ActivityButton);
            WebHost.Children.Remove(view); view.Dispose();
        }
        state.Suspended = false; state.MediaUsed = false;
    }
}
