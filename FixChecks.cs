using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckGoogleKeep()
    {
        var keep = services.Single(s => s.Definition.Id == "googlekeep");
        Check(!keep.Options.Enabled && !keep.Options.KeepLive && keep.View == null,
            "Google Keep starts unloaded and can sleep in the background");
        Check(keep.Definition.Owns("https://keep.google.com/") && !keep.Definition.Owns("https://keep.google.com.attacker.test/"),
            "Google Keep uses an exact provider boundary");
        await SelectService(keep);
        await Until(() => keep.Status == "Live");
        Check(keep.Core!.Profile.ProfileName == "googlekeep", "Google Keep has an isolated account profile");
        await keep.Core.ExecuteScriptAsync("window.open('https://accounts.google.com/relay-keep-fixture')");
        await Until(() => AccountViews(keep).Any(view => view != keep.View && ServiceState.TryCore(view)?.Source.Contains("accounts.google.com") == true));
        var auth = AccountViews(keep).Single(view => view != keep.View).CoreWebView2;
        await auth.ExecuteScriptAsync("document.cookie='relay-keep-auth=fixture; Domain=google.com; Path=/; Secure; SameSite=Lax'; location.href='https://keep.google.com/#home'");
        await Until(() => keep.Core!.Source == "https://keep.google.com/#home" && keep.Status == "Live" && !popups.Any(p => p.Tag == keep));
        Check(await keep.Core.ExecuteScriptAsync("document.cookie.includes('relay-keep-auth=fixture')") == "true",
            "Google Keep sign-in returns to the main service with shared account cookies");
        var extra = AddAccount(keep.Definition, "Scratch");
        await SelectService(extra);
        var cookies = await extra.Core!.CookieManager.GetCookiesAsync("https://keep.google.com/");
        Check(!cookies.Any(cookie => cookie.Name == "relay-keep-auth") && extra.Core.Profile.ProfileName != keep.Core.Profile.ProfileName,
            "Extra Google Keep accounts do not share sign-in cookies");
        RemoveAccount(extra);
        await SelectService(keep);
        keep.Core.Navigate("https://relay.test/");
        await Until(() => keep.Unread == 3 && keep.Status == "Live");
    }

    private async Task CheckServiceFixes(string output)
    {
        var messenger = services.Single(s => s.Definition.Id == "messenger");
        await SelectService(messenger);
        messenger.Core!.Navigate("https://www.facebook.com/messages/fragmented");
        await Until(() => messenger.Core!.Source.EndsWith("/fragmented") && messenger.Status == "Live");
        await Task.Delay(400);
        Check(await messenger.Core!.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display === 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 0 && getComputedStyle(document.querySelector('#chat-header')).display !== 'none'") == "true", "Fragmented zero-height Facebook header is removed under strict style CSP while chat controls remain");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('[role=banner]').style.display='block';document.querySelector('[role=main]').style.top='60px'");
        await Task.Delay(200);
        Check(await messenger.Core.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display === 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 0") == "true", "Facebook style updates do not restore the removed navbar");
        await messenger.Core.ExecuteScriptAsync("history.pushState({},'', '/settings/')");
        await Task.Delay(200);
        Check(await messenger.Core.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display !== 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 60") == "true", "Fragmented header and offsets return on non-Messenger routes");
        await messenger.Core.ExecuteScriptAsync("history.pushState({},'', '/messages/fragmented')");
        await Task.Delay(200);
        Check(await messenger.Core.ExecuteScriptAsync("getComputedStyle(document.querySelector('[role=banner]')).display === 'none' && document.querySelector('[role=main]').getBoundingClientRect().top === 0") == "true", "Returning to Messenger through SPA navigation reapplies the trim");
        messenger.Core.Navigate("https://relay.test/");
        await Until(() => messenger.Unread == 3 && messenger.Status == "Live");

        var gmail = services.Single(s => s.Definition.Id == "gmail");
        settings.CaptureLinks = false;
        smokeExternalLinks.Clear();
        await SelectService(gmail);
        gmail.Core!.Navigate("https://workspace.google.com/intl/en-US/gmail/");
        await Until(() => gmail.Core!.Source.Contains("workspace.google.com") && gmail.Status == "Live");
        await gmail.Core.ExecuteScriptAsync("window.open('https://accounts.google.com/relay-fixture')");
        await Until(() => AccountViews(gmail).Any(v => ServiceState.TryCore(v)?.Source.Contains("accounts.google.com") == true));
        var authView = AccountViews(gmail).Single(v => v != gmail.View);
        var authCore = authView.CoreWebView2;
        Check(authCore.Profile.ProfileName == gmail.Core.Profile.ProfileName, "Gmail sign-in popup uses the account's actual profile");
        await authCore.ExecuteScriptAsync("document.cookie='relay-auth=fixture; Domain=google.com; Path=/; Secure; SameSite=Lax'; localStorage.setItem('auth-fixture','yes'); location.href='https://accounts.google.com/relay-session-handoff'");
        await Until(() => IsGmailInbox(gmail.Core!.Source) && gmail.Status == "Live" && !popups.Any(p => p.Tag == gmail));
        Check(await gmail.Core.ExecuteScriptAsync("document.cookie.includes('relay-auth=fixture')") == "true", "Completed Gmail login returns to the main inbox with shared cookies and closes its popup");
        Check(smokeExternalLinks.Count == 0, "Google popup session redirects stay in Relay with link capture disabled");
        var extraGmail = AddAccount(gmail.Definition, "Separate");
        await SelectService(extraGmail);
        var extraCookies = await extraGmail.Core!.CookieManager.GetCookiesAsync("https://mail.google.com/");
        Check(!extraCookies.Any(c => c.Name == "relay-auth"), "Gmail popup sign-in does not leak into another account");
        extraGmail.Core.Navigate("https://accounts.google.com/relay-main-signin");
        await Until(() => extraGmail.Core.Source == "https://accounts.google.com/relay-main-signin" && extraGmail.Status == "Live");
        await extraGmail.Core.ExecuteScriptAsync("document.cookie='relay-main-auth=fixture; Domain=google.com; Path=/; Secure; SameSite=Lax';location.href='https://accounts.google.com/relay-session-handoff'");
        await Until(() => IsGmailInbox(extraGmail.Core.Source) && extraGmail.Status == "Live");
        Check(smokeExternalLinks.Count == 0 && await extraGmail.Core.ExecuteScriptAsync("document.cookie.includes('relay-main-auth=fixture')") == "true",
            "Main-view Google session redirects reach the signed-in inbox without an external browser or reload");
        Check(!(await gmail.Core.CookieManager.GetCookiesAsync("https://mail.google.com/")).Any(c => c.Name == "relay-main-auth"),
            "Main-view Google sign-in retains the extra account's isolated profile");
        await extraGmail.Core.ExecuteScriptAsync("location.href='https://external.relay.test/after-google-auth'");
        await Until(() => smokeExternalLinks.Count == 1);
        Check(IsGmailInbox(extraGmail.Core.Source), "External links still leave Relay after Google sign-in completes");
        smokeExternalLinks.Clear();
        RemoveAccount(extraGmail);

        await SelectService(gmail);
        await gmail.Core.ExecuteScriptAsync("window.open('https://mail.google.com/mail/u/0/#compose')");
        await Until(() => AccountViews(gmail).Any(v => v != gmail.View && IsGmailInbox(ServiceState.TryCore(v)?.Source ?? "")));
        await Task.Delay(200);
        Check(popups.Any(p => p.Tag == gmail) && gmail.Core.Source.EndsWith("#inbox"), "Ordinary Gmail message/compose popups stay open and do not hijack the main inbox");
        foreach (var popup in popups.Where(p => p.Tag == gmail).ToArray()) popup.Close();
        Check(!IsGmailInbox("https://mail.google.com.attacker.test/mail/u/0/") && !IsGoogleSignIn("https://accounts.google.com.attacker.test/"), "Auth handoff validates exact Google hosts");
        // Earlier unread tests leave new-since-launch mode enabled. This fixture
        // checks a raw title count, independently of its accumulated baseline.
        bool allUnread = gmail.Options.GmailAllUnread;
        SetGmailUnreadMode(gmail, true);
        gmail.Core.Navigate("https://relay.test/"); await Until(() => gmail.Unread == 3 && gmail.Status == "Live");
        SetGmailUnreadMode(gmail, allUnread);

        ShowSettings();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        var first = services.Single(s => s.Definition.Id == "messenger");
        Button Control(string tip) => ((StackPanel)((Grid)serviceSettingsList.Children.OfType<Border>().Single(b => b.Tag == first).Child).Children[2]).Children.OfType<Button>().Single(b => Equals(b.ToolTip, tip));
        bool wasMuted = first.Options.AudioMuted;
        Control(wasMuted ? "Unmute audio" : "Mute audio").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Check(first.Options.AudioMuted != wasMuted && Settings.Load().Services[first.Definition.Id].AudioMuted == first.Options.AudioMuted, "Service-row audio button toggles and persists");
        Control(wasMuted ? "Mute audio" : "Unmute audio").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        bool alerts = first.Options.Notifications;
        Control(alerts ? "Mute alerts" : "Enable alerts").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Check(first.Options.Notifications != alerts && Settings.Load().Services[first.Definition.Id].Notifications == !alerts, "Service-row alert button toggles and persists");
        Control(alerts ? "Enable alerts" : "Mute alerts").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        bool keepLive = first.Options.KeepLive;
        Control(keepLive ? "Allow sleep" : "Keep awake").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Check(first.Options.KeepLive != keepLive && Settings.Load().Services[first.Definition.Id].KeepLive == !keepLive, "Service-row sleep button toggles and persists");
        Control(keepLive ? "Keep awake" : "Allow sleep").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Check(Control(first.Options.ShowShortcut ? "Hide shortcut" : "Show shortcut").IsEnabled && Control("Rename").IsEnabled, "Service row exposes visibility and rename directly");
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        LocalPage.ScrollToVerticalOffset(serviceSettingsList.TranslatePoint(new Point(), LocalContent).Y - 55);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "service-settings-rows.png"));
        Width = 720; Height = 720;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        LocalPage.ScrollToVerticalOffset(serviceSettingsList.TranslatePoint(new Point(), LocalContent).Y - 55);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "service-settings-compact.png"));
        Check(serviceSettingsList.ActualWidth <= LocalPage.ViewportWidth && serviceSettingsList.ActualWidth > 450, "Service rows fit the minimum window width");
        Width = 1280; Height = 820;
        Check(!GreetingOptions(DateTime.Now, 0, 3).Any(line => line.Contains("unclench")), "Removed greeting cannot be selected");
        await CheckFollowupFixes(output);
        await CheckGoogleKeep();
        ShowActivity();
    }
}
