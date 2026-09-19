using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckFollowupFixes(string output)
    {
        var messenger = services.Single(s => s.Definition.Id == "messenger");
        await SelectService(messenger);
        messenger.Core!.Navigate("https://www.facebook.com/messages/nested");
        await Until(() => messenger.Core!.Source.EndsWith("/nested") && messenger.Status == "Live");
        await Task.Delay(300);
        const string fillsViewport = "Math.abs(document.querySelector('[role=navigation]').getBoundingClientRect().bottom-innerHeight)<2 && Math.abs(document.querySelector('.thread').getBoundingClientRect().bottom-(innerHeight-16))<2 && document.querySelector('#composer').getBoundingClientRect().bottom<=innerHeight";
        Check(await messenger.Core!.ExecuteScriptAsync(fillsViewport) == "true", "Messenger sidebar and nested chat reach the viewport bottom, preserving the chat's 16px inset and visible composer");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('.layout').classList.add('cached');history.pushState({},'', '/messages/nested-cached')");
        await Task.Delay(250);
        Check(await messenger.Core.ExecuteScriptAsync(fillsViewport) == "true", "Switching to a cached chat remeasures the reused pane and keeps the composer visible");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('.thread').style.marginTop='32px';document.querySelector('.thread').style.height='calc(100vh - 104px)'");
        await Task.Delay(250);
        Check(await messenger.Core.ExecuteScriptAsync(fillsViewport) == "true", "Site inline layout changes replace stale pane measurements");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('.layout').classList.remove('cached');document.querySelector('.thread').style.removeProperty('margin-top');document.querySelector('.thread').style.removeProperty('height');history.pushState({},'', '/messages/nested')");
        await Task.Delay(250);
        Check(await messenger.Core.ExecuteScriptAsync(fillsViewport) == "true", "Switching back to the original cached chat restores the correct composer height");
        Width = 900; Height = 680;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Task.Delay(250);
        Check(await messenger.Core.ExecuteScriptAsync(fillsViewport) == "true", "Messenger inner panes stay full height after resizing");
        using (var preview = File.Create(Path.Combine(output, "messenger-nested-viewport.png")))
            await messenger.Core.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png, preview);
        await messenger.Core.ExecuteScriptAsync("history.pushState({},'', '/settings/')");
        await Task.Delay(200);
        Check(await messenger.Core.ExecuteScriptAsync("document.querySelector('[role=navigation]').getBoundingClientRect().top===56 && Math.abs(document.querySelector('.thread').getBoundingClientRect().bottom-(innerHeight-16))<2") == "true", "Leaving Messenger restores original nested pane sizing");
        Width = 1280; Height = 820;
        messenger.Core.Navigate("https://relay.test/"); await Until(() => messenger.Unread == 3 && messenger.Status == "Live");

        var calendar = services.Single(s => s.Definition.Id == "calendar");
        await SelectService(calendar);
        calendar.Core!.Navigate("https://workspace.google.com/products/calendar/");
        await Until(() => calendar.Core!.Source.Contains("workspace.google.com") && calendar.Status == "Live");
        await calendar.Core.ExecuteScriptAsync("window.open('https://accounts.google.com/calendar-fixture')");
        await Until(() => AccountViews(calendar).Any(v => v != calendar.View && ServiceState.TryCore(v)?.DocumentTitle == "Gmail fixture"));
        var auth = AccountViews(calendar).Single(v => v != calendar.View).CoreWebView2;
        Check(auth.Profile.ProfileName == calendar.Core.Profile.ProfileName, "Calendar popup shares the original account's profile");
        await auth.ExecuteScriptAsync("document.cookie='relay-calendar-session=fixture; Domain=google.com; Path=/; Secure; SameSite=Lax';document.cookie='relay-calendar=fixture; Domain=google.com; Path=/; Secure; SameSite=Lax; Max-Age=3600';location.href='https://calendar.google.com/calendar/u/0/r'");
        await Until(() => IsGoogleApp("calendar", calendar.Core!.Source) && calendar.Status == "Live" && !popups.Any(p => p.Tag == calendar));
        Check(await calendar.Core.ExecuteScriptAsync("document.cookie.includes('relay-calendar=fixture') && document.cookie.includes('relay-calendar-session=fixture')") == "true", "Calendar sign-in returns the app route to the main view with shared cookies");
        DisconnectService(calendar); await SelectService(calendar);
        Check((await calendar.Core!.CookieManager.GetCookiesAsync("https://calendar.google.com/")).Any(c => c.Name == "relay-calendar"), "Persistent Calendar sign-in cookie survives disconnect and reconnect");
        calendar.LastAddress = "https://workspace.google.com/products/calendar/";
        Check(ServiceStartAddress(calendar) == GoogleAppHome("calendar"), "Reconnect replaces a remembered public Calendar landing page with its app route");
        calendar.Core.Navigate(calendar.LastAddress); await Until(() => calendar.Status == "Live" && calendar.Core.Source.Contains("workspace.google.com"));
        ReloadClick(this, new RoutedEventArgs());
        await Until(() => IsGoogleApp("calendar", calendar.Core!.Source) && calendar.Status == "Live");
        Check(!IsGoogleApp("calendar", "https://calendar.google.com.attacker.test/calendar/") && !IsGoogleApp("calendar", "https://accounts.google.com/"), "Calendar return excludes lookalike and unfinished sign-in URLs");
        calendar.Core.Navigate("https://relay.test/"); await Until(() => calendar.Unread == 3 && calendar.Status == "Live");
        DisconnectService(calendar);

        var gmail = services.Single(s => s.Definition.Id == "gmail");
        await SelectService(gmail);
        var originalView = gmail.View;
        await gmail.Core!.ExecuteScriptAsync("localStorage.setItem('rename-default','kept')");
        RenameAccount(gmail, "Personal");
        Check(gmail.Definition.Name == "Gmail · Personal" && gmail.View == originalView && gmail.Core.Profile.ProfileName == "gmail", "Renaming the original account leaves its active browser profile untouched");
        Check(Settings.Load().Services["gmail"].AccountName == "Personal" && AccountDefinitions().Single(d => d.Id == "gmail").Name == "Gmail · Personal", "Original account name survives settings reload");
        var extra = AddAccount(gmail.Definition, "Work");
        Check(extra.Definition.Name == "Gmail · Work", "Adding from a renamed original uses the provider name exactly once");
        bool rejected = false;
        try { RenameAccount(extra, "personal"); } catch (InvalidOperationException) { rejected = true; }
        Check(rejected, "Default and extra accounts share duplicate-name validation");
        ShowSettings();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        LocalPage.ScrollToEnd();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "renamed-default-accounts.png"));
        RemoveAccount(extra);
        RenameAccount(gmail, "");
        Check(gmail.Definition.Name == "Gmail" && await gmail.Core.ExecuteScriptAsync("localStorage.getItem('rename-default')") == "\"kept\"", "Clearing an original account nickname restores the provider name without losing storage");

        const long gib = 1024L * 1024 * 1024;
        var roomy = ResourceLimits.ForMemory(128 * gib);
        Check(roomy.MemoryLevel(1600L * 1024 * 1024) == 0 && roomy.MemoryLevel(2 * gib) == 1 && roomy.MemoryLevel(4 * gib) == 2, "Memory thresholds allow the measured normal workload but still flag 2/4 GiB");
        var modest = ResourceLimits.ForMemory(8 * gib);
        Check(modest.MemoryWarning == 8 * gib / 10 && modest.MemoryCritical == 8 * gib / 5, "Small-memory systems use proportional warning thresholds");
        var pressure = new ResourcePressure();
        pressure.Observe(60); pressure.Observe(2);
        Check(pressure.CpuLevel == 0, "A short CPU spike does not turn the indicator red");
        pressure.Observe(60); pressure.Observe(60); pressure.Observe(60);
        Check(pressure.CpuLevel == 2, "Sustained CPU overrun still turns red");
        pressure.Observe(1);
        Check(pressure.CpuLevel == 0, "CPU indicator clears after recovery");
        using (var process = Process.GetCurrentProcess())
        {
            long resident = NativeMemory.PrivateResident(process, out bool approximate);
            Check(!approximate && resident > 0 && resident <= process.WorkingSet64, "Native memory sampling returns private resident RAM rather than duplicated shared pages");
        }
        ShowActivity();
    }
}
