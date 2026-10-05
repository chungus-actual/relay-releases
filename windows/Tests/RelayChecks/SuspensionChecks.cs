using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckIdleSuspension(string output)
    {
        var account = services[0]; var other = services[1];
        var core = account.Core!; var view = account.View!;
        bool timerRunning = idleTimer.IsEnabled;
        idleTimer.Stop();
        try
        {
            await Until(() => !suspending);
            account.Options.KeepLive = false;
            account.HiddenAt = DateTime.UtcNow.AddMinutes(-3);
            int requests = 0;
            Task<bool> Decline(CoreWebView2 _) { requests++; return Task.FromResult(false); }

            account.MediaUsed = true;
            await SuspendIdle(Decline);
            Check(requests == 0 && !account.Suspended, "Media activity prevents a suspension request");
            account.MediaUsed = false;
            await core.ExecuteScriptAsync("window.suspensionDraft = 'Unsent suspension fixture'");

            // The native API is best-effort. Require Relay to request suspension and
            // reflect its real result; a refusal must not become a false Sleeping state.
            bool? accepted = null; Exception? nativeFailure = null;
            await SuspendIdle(async native =>
            {
                requests++;
                try { accepted = await native.TrySuspendAsync(); return accepted.Value; }
                catch (Exception ex) { nativeFailure = ex; throw; }
            });
            File.WriteAllText(Path.Combine(output, "suspension-diagnostics.txt"),
                $"Runtime: {core.Environment.BrowserVersionString}\nNative accepted: {accepted}\nRelay suspended: {account.Suspended}\nNative suspended: {core.IsSuspended}\nNative failure: {nativeFailure}\n");
            Check(requests == 1 && accepted.HasValue && nativeFailure == null, "Eligible hidden service calls the native suspension API without an error: " + nativeFailure);
            bool nativeAccepted = accepted ?? throw new InvalidOperationException("Native suspension returned no result.");
            Check(account.Suspended == nativeAccepted && core.IsSuspended == nativeAccepted, "Relay suspension state matches the native result");
            CheckSleepIndicator(account, nativeAccepted);
            CaptureElement(railButtons[account.Definition.Id], Path.Combine(output, nativeAccepted ? "sleep-indicator.png" : "sleep-declined.png"));
            await SelectService(account);
            Check(!account.Suspended && !core.IsSuspended && account.View == view, "Selecting a service resumes its retained native browser");
            Check(await core.ExecuteScriptAsync("window.suspensionDraft") == "\"Unsent suspension fixture\"", "Native suspend or refusal followed by selection retains the document");

            // Exercise both host outcomes on every runtime, even if its native
            // heuristics consistently accept or consistently refuse this fixture.
            await SelectService(other);
            account.HiddenAt = DateTime.UtcNow.AddMinutes(-3);
            requests = 0;
            await SuspendIdle(Decline);
            Check(requests == 1 && !account.Suspended && account.Status == "Live", "Declined suspension keeps the service live and eligible for another attempt");
            CheckSleepIndicator(account, false);
            Task<bool> Accept(CoreWebView2 _) { requests++; return Task.FromResult(true); }
            await SuspendIdle(Accept);
            Check(requests == 2 && account.Suspended && account.Status == "Sleeping", "A later accepted request marks the service sleeping");
            CheckSleepIndicator(account, true);
            await SuspendIdle(Accept);
            Check(requests == 2, "An already sleeping service is not suspended twice");
            await SelectService(account);
            Check(!account.Suspended && account.Status == "Live", "Selection clears accepted suspension and the sleeping label");
            CheckSleepIndicator(account, false);

            await SelectService(other);
            account.HiddenAt = DateTime.UtcNow.AddMinutes(-3);
            var pending = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var request = SuspendIdle(_ => { requests++; return pending.Task; });
            Check(requests == 3, "Delayed suspension request started");
            await SelectService(account);
            pending.SetResult(true);
            await request;
            Check(!account.Suspended && !core.IsSuspended && account.Status == "Live", "Late acceptance cannot put a reselected service to sleep");
            CheckSleepIndicator(account, false);
            Check(account.View == view && await core.ExecuteScriptAsync("window.suspensionDraft") == "\"Unsent suspension fixture\"", "Decline, retry, duplicate and stale completion preserve the same document");
            File.AppendAllText(Path.Combine(output, "suspension-diagnostics.txt"), "PASS: native result, decline/retry, accepted state, duplicate suppression, selection, stale completion, badge and document retention.\n");
        }
        finally
        {
            account.MediaUsed = false;
            if (timerRunning) idleTimer.Start();
        }
    }

    private void CheckSleepIndicator(ServiceState account, bool sleeping)
    {
        RefreshRail();
        var row = railVisuals[account.Definition.Id];
        Check((row.Sleep.Visibility == Visibility.Visible) == sleeping && row.Count.Text == account.Badge,
            "Sleep indicator reflects suspension independently of unread count");
    }
}
