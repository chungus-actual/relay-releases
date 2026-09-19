using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckNewFeatures(string output)
    {
        void Stage(string name) => File.AppendAllText(Path.Combine(output, "feature-checks.txt"), DateTime.UtcNow.ToString("O") + " " + name + "\n");
        File.WriteAllText(Path.Combine(output, "feature-checks.txt"), "");
        Stage("links");
        await CheckLinkRouting();
        Stage("accounts");
        var original = services.Single(s => s.Definition.Id == "whatsapp");
        await SelectService(original);
        await original.View!.CoreWebView2.ExecuteScriptAsync("localStorage.setItem('account-scope', 'original')");
        var extra = AddAccount(original.Definition, "Work");
        Check(extra.Definition.IconId == "whatsapp" && extra.Definition.Id != original.Definition.Id && Settings.Load().Accounts.Single().Id == extra.Definition.Id, "Additional account has a stable provider and persisted unique identity");
        await SelectService(extra); await Until(() => extra.Unread == 3);
        Check(extra.View!.CoreWebView2.Profile.ProfileName == extra.Definition.Id, "Additional account gets its own browser profile");
        Check(await extra.View.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('account-scope')") == "null", "Accounts of the same service do not share site storage");
        await extra.View.CoreWebView2.ExecuteScriptAsync("localStorage.setItem('account-scope', 'work')");
        SetAudioMuted(extra, true);
        Check(extra.View.CoreWebView2.IsMuted && !original.View.CoreWebView2.IsMuted && Settings.Load().Services[extra.Definition.Id].AudioMuted, "Audio mute is per account and persists");
        await extra.View.CoreWebView2.ExecuteScriptAsync("window.open('https://relay.test/popup')");
        await Until(() => AccountViews(extra).Count(v => v.CoreWebView2 != null) == 2);
        Check(AccountViews(extra).All(v => v.CoreWebView2.IsMuted), "New popup inherits its account audio mute");
        SetAudioMuted(extra, false);
        Check(AccountViews(extra).All(v => !v.CoreWebView2.IsMuted), "Unmute updates the account and its popup");
        SetAudioMuted(extra, true);
        foreach (var popup in popups.Where(p => p.Tag == extra).ToArray()) popup.Close();
        RenameAccount(extra, "Work renamed");
        Check(extra.Definition.Name == "WhatsApp · Work renamed" && extra.View.CoreWebView2.Profile.ProfileName == extra.Definition.Id, "Renaming preserves the account profile");
        RenameAccount(extra, new string('W', 32));
        Width = 720; Height = 540;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(ServiceCaptionName.Text == extra.Definition.Name && ServiceCaptionName.TextTrimming == TextTrimming.None && BrowserOverflow.Visibility == Visibility.Visible && ServiceCaptionName.ActualWidth >= ServiceCaptionName.DesiredSize.Width - 1, "Long account name remains complete at minimum width with navigation overflow");
        Capture(Path.Combine(output, "account-caption-long.png"));
        Width = 1280; Height = 820; RenameAccount(extra, "Work renamed");
        ShowSettings(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "accounts-settings.png"));
        ShowAccountEditor(initial: original.Definition); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "account-editor.png"));
        await SelectService(extra);
        Stage("downloads");
        foreach (var source in new[] { original, extra })
        {
            await source.View!.CoreWebView2.ExecuteScriptAsync("(()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['relay download fixture'],{type:'text/plain'}));a.download='fixture.txt';document.body.append(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},1000)})()");
            await Until(() => downloads.Any(d => d.AccountId == source.Definition.Id && d.Complete));
        }
        Check(downloads.Count == 2 && downloads.All(d => d.Operation == null && d.Owner == null && File.ReadAllText(d.FilePath) == "relay download fixture"), "Downloads across accounts write files and release completed browser handles");
        DownloadsClick(this, new RoutedEventArgs()); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(DownloadsColumn.ActualWidth == 300 && DownloadItems.Children.Count == 2, "Downloads drawer shows both accounts without overlaying web content");
        Check(DownloadItems.Children.OfType<System.Windows.Controls.Border>().All(card => ((System.Windows.Controls.DockPanel)((System.Windows.Controls.StackPanel)card.Child).Children[0]).Children.OfType<System.Windows.Controls.Button>().Single().IsEnabled), "Each download entry exposes its folder action");
        Check(downloads.All(item => DownloadFolderTarget(item.FilePath).Arguments.Contains(item.FilePath)), "Download folder actions select each entry’s own saved file");
        Check(DownloadFolderTarget(Path.Combine(Path.GetDirectoryName(downloads[0].FilePath)!, "missing.txt")).FileName == Path.GetDirectoryName(downloads[0].FilePath), "Folder action still opens the destination when the file is unavailable");
        Capture(Path.Combine(output, "downloads-drawer.png"));
        var savedDownload = downloads[0].FilePath;
        ClearDownloadsClick(this, new RoutedEventArgs());
        Check(downloads.Count == 0 && File.Exists(savedDownload), "Clearing download history preserves downloaded files");
        DownloadsClick(this, new RoutedEventArgs());
        Stage("renderer crash");
        var previousView = extra.View;
        var crash = extra.View!.CoreWebView2.CallDevToolsProtocolMethodAsync("Page.crash", "{}");
        _ = crash.ContinueWith(task => { _ = task.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
        await Until(() => extra.View != null && extra.View != previousView && !extra.Recovering && extra.Unread == 3);
        Check(extra.View!.CoreWebView2.IsMuted && await extra.View.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('account-scope')") == "\"work\"", "Renderer crash recovers automatically with account storage and audio mute intact");
        Check(original.View!.CoreWebView2.Profile.ProfileName == "whatsapp" && await original.View.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('account-scope')") == "\"original\"", "Recovery preserves the other account");
        var expectedBrowserPath = Path.GetFullPath(Path.Combine(App.DataPath, "Browser"));
        Check(App.SmokeTest && Path.GetFullPath(extra.View.CoreWebView2.Environment.UserDataFolder) == expectedBrowserPath, "Crash test targets only the isolated fixture browser");
        Stage("browser crash");
        var beforeBrowserCrash = original.View;
        using (var browser = Process.GetProcessById((int)extra.View.CoreWebView2.BrowserProcessId)) browser.Kill();
        await Until(() => extra.Core != null && original.Core != null && original.View != beforeBrowserCrash && !original.Recovering && !extra.Recovering && original.Unread == 3 && extra.Unread == 3);
        Check(extra.View.CoreWebView2.IsMuted && !original.View.CoreWebView2.IsMuted, "Shared-browser crash recovers all connected accounts with independent audio state");
        Stage("retry cap and cancellation");
        extra.RecoveryAttempts.Clear();
        for (int i = 0; i < 3; i++) extra.RecoveryAttempts.Enqueue(DateTime.UtcNow);
        var cappedView = extra.View; QueueRecovery(extra);
        Check(!extra.Recovering && extra.NeedsRestart && extra.Status == "Recovery paused" && extra.View == cappedView, "Repeated crashes stop at the retry cap");
        extra.RecoveryAttempts.Clear(); extra.NeedsRestart = false;
        QueueRecovery(extra); DisconnectService(extra);
        await Task.Delay(1200);
        Check(extra.View == null && !extra.Options.Enabled && !extra.Recovering, "Disconnect cancels pending recovery without resurrecting the account");
        await SelectService(extra); await Until(() => extra.Unread == 3);
        Check(extra.View!.CoreWebView2.IsMuted && await extra.View.CoreWebView2.ExecuteScriptAsync("localStorage.getItem('account-scope')") == "\"work\"", "Reconnect retains account settings and sign-in storage");
        RemoveAccount(extra);
        Check(!services.Contains(extra) && Settings.Load().Accounts.Count == 0 && !Settings.Load().Services.ContainsKey(extra.Definition.Id), "Removing an extra account leaves the original account intact");
        Stage("Messenger chrome");
        var messenger = services.Single(s => s.Definition.Id == "messenger");
        await SelectService(messenger);
        messenger.View!.CoreWebView2.Navigate("https://www.facebook.com/messages/");
        await Until(() => messenger.View.CoreWebView2.Source.EndsWith("/messages/") && messenger.Status == "Live");
        await Task.Delay(350);
        Check(await messenger.View.CoreWebView2.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display === 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 0") == "true", "Messenger hides the Facebook nav and reclaims its height");
        await messenger.View.CoreWebView2.ExecuteScriptAsync("history.pushState({}, '', '/settings/')"); await Task.Delay(200);
        Check(await messenger.View.CoreWebView2.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display !== 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 56") == "true", "Facebook navigation is restored outside Messenger routes");
        Check(CaptionDomain("https://www.facebook.com/messages/") == "facebook.com" && CaptionDomain("https://messages.google.com/web/") == "google.com" && CaptionDomain("https://facebook.com.attacker.test/") == "facebook.com.attacker.test", "Caption shortens known service domains without disguising unrelated hosts");
        messenger.View.CoreWebView2.Navigate("https://relay.test/"); await Until(() => messenger.Unread == 3 && messenger.Status == "Live");
        await CheckServiceFixes(output);
        ShowActivity(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
}
