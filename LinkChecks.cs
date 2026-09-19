using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckLinkRouting()
    {
        Check(!new Settings().CaptureLinks && !JsonSerializer.Deserialize<Settings>("{}")!.CaptureLinks,
            "Link capture defaults off for new and existing settings");
        var discord = services.Single(s => s.Definition.Id == "discord");
        Check(discord.Definition.Url == "https://discord.com/channels/@me"
            && TryFindResource("ServiceIcon.discord") is System.Windows.Media.Geometry,
            "Discord ships with its web app home and shared service icon");
        foreach (var address in new[] { discord.Definition.Url, "https://discord.com/login", "https://discord.com/channels/123/456" })
            Check(discord.Definition.Owns(address) && ServiceLink(discord, new Uri(address)), "Discord app routes stay embedded");
        foreach (var address in new[] { "http://discord.com", "https://discord.com.evil.test", "https://notdiscord.com", "https://cdn.discordapp.com/file" })
            Check(!discord.Definition.Owns(address) && !ServiceLink(discord, new Uri(address)), "Unrelated hosts do not inherit Discord service routing");
        await SelectService(discord);
        discord.Core!.Navigate(discord.Definition.Url);
        await Until(() => discord.Core.Source == discord.Definition.Url && discord.Status == "Live");
        await discord.Core.ExecuteScriptAsync("document.title='(4) Discord'");
        await Until(() => discord.Unread == 4);
        DismissService(discord);
        TitleUnreadChanged(discord);
        Check(discord.Badge == "", "Repeated Discord count stays dismissed");
        await discord.Core.ExecuteScriptAsync("document.title='(5) Discord'");
        await Until(() => discord.Unread == 5);
        int discordActivity = activity.Count(item => item.Service == discord);
        TitleUnreadChanged(discord);
        Check(activity.Count(item => item.Service == discord) == discordActivity, "Duplicate Discord count does not duplicate activity");
        await discord.Core.ExecuteScriptAsync("document.title='Discord | Friends'");
        await Until(() => discord.Badge == "");
        var state = services.Single(s => s.Definition.Id == "messenger");
        await SelectService(state);
        await Until(() => state.Status == "Live");
        var core = state.Core!;
        string original = core.Source;
        settings.CaptureLinks = false;
        smokeExternalLinks.Clear();
        await core.ExecuteScriptAsync("(()=>{const a=document.createElement('a');a.href='https://external.relay.test/same-window';document.body.append(a);a.click();a.remove()})()");
        await Until(() => smokeExternalLinks.Count == 1);
        await Task.Delay(150);
        Check(core.Source == original && state.Status == "Live" && ErrorPanel.Visibility != Visibility.Visible,
            "Same-window external links open in the default browser without replacing or breaking the service");
        await core.ExecuteScriptAsync("window.open('https://external.relay.test/popup')");
        await Until(() => smokeExternalLinks.Count == 2);
        Check(!popups.Any(p => p.Tag == state), "External popup links do not create Relay windows");
        await core.ExecuteScriptAsync("window.open('https://l.facebook.com/l.php?u=https%3A%2F%2Fexternal.relay.test%2Fwrapped')");
        await Until(() => smokeExternalLinks.Count == 3);
        Check(smokeExternalLinks.Last() == "https://external.relay.test/wrapped", "Facebook chat redirects open their destination externally");
        await core.ExecuteScriptAsync("(()=>{const p=window.open('about:blank');setTimeout(()=>p.location.href='https://external.relay.test/deferred',200)})()");
        await Until(() => smokeExternalLinks.Count == 4 && !popups.Any(p => p.Tag == state));
        Check(core.Source == original, "Deferred blank-window links route externally and close the empty popup");
        Check(ServiceLink(state, new Uri("https://www.facebook.com/messages/thread"))
            && ServiceLink(state, new Uri("https://accounts.google.com/signin"))
            && !ServiceLink(state, new Uri("https://accounts.google.com.attacker.test/signin"))
            && WebLink("javascript:alert(1)") == null && WebLink("file:///C:/test") == null,
            "Service navigation and sign-in remain embedded; host lookalikes and non-web schemes stay distinct");
        Check(services.Where(s => s.Definition.IconId is "gmail" or "calendar" or "googlemessages" or "googlekeep" or "youtubemusic")
            .All(s => ServiceLink(s, new Uri("https://accounts.youtube.com/accounts/SetSID?continue=https%3A%2F%2Fmail.google.com%2Fmail%2F"))
                && !ServiceLink(s, new Uri("https://accounts.youtube.com.attacker.test/accounts/SetSID"))
                && !ServiceLink(s, new Uri("https://www.youtube.com/watch?v=fixture"))
                && !ServiceLink(s, new Uri("http://accounts.youtube.com/accounts/SetSID")))
            && IsGoogleSignIn("https://accounts.youtube.com/accounts/SetSID")
            && !IsGoogleSignIn("https://accounts.youtube.com.attacker.test/accounts/SetSID"),
            "All Google services retain HTTPS session handoffs while ordinary YouTube links and lookalikes remain external");
        foreach (var address in new[] { "https://fbcdn.net/file", "https://scontent.xx.fbcdn.net/file", "https://cdn.fbsbx.com/file" })
        {
            var uri = new Uri(address);
            Check(ProviderAttachment(state, uri) && !state.Definition.Owns(address)
                && !ProviderAttachment(discord, uri), "Messenger attachment routing does not grant service ownership");
        }
        foreach (var address in new[] { "http://fbcdn.net/file", "https://fbcdn.net.evil.test/file", "https://notfbcdn.net/file" })
            Check(!ProviderAttachment(state, new Uri(address)), "Attachment routing rejects insecure and unrelated hosts");
        foreach (var script in new[] {
            "(()=>{const a=document.createElement('a');a.href='https://cdn.fbsbx.com/file';document.body.append(a);a.click();a.remove()})()",
            "window.open('https://scontent.xx.fbcdn.net/file')" })
        {
            int before = downloads.Count;
            await core.ExecuteScriptAsync(script);
            try { await Until(() => downloads.Count > before && downloads.First().Complete); }
            catch
            {
                System.IO.File.WriteAllText("artifacts/attachment-diagnostics.txt",
                    $"Before: {before}, script: {script}\n" + string.Join("\n", downloads.Select(d =>
                        $"{d.Status}, complete={d.Complete}, bytes={d.Received}/{d.Total}, reason={d.Operation?.InterruptReason}")));
                throw;
            }
            var download = downloads.First();
            Check(System.IO.File.ReadAllText(download.FilePath) == "Relay attachment fixture"
                && download.AccountId == state.Definition.Id && smokeExternalLinks.Count == 4
                && download.Operation == null && download.Owner == null,
                "Messenger CDN main/popup attachment bytes reach the account download drawer with capture off");
            downloads.Remove(download);
        }
        await Until(() => downloadPopups.Count == 0 && !popups.Any(p => p.Tag == state));
        Check(!popups.Any(p => p.Tag == state), "Finished attachment popups release their retained owners");
        settings.CaptureLinks = true; settings.Save();
        Check(Settings.Load().CaptureLinks, "Link capture preference persists");
        await core.ExecuteScriptAsync("window.open('https://external.relay.test/captured')");
        await Until(() => AccountViews(state).Any(v => v != state.View && ServiceState.TryCore(v)?.Source == "https://external.relay.test/captured"));
        var captured = AccountViews(state).Single(v => v != state.View);
        Check(captured.CoreWebView2.Profile.ProfileName == core.Profile.ProfileName && smokeExternalLinks.Count == 4,
            "Enabling capture keeps links in Relay using the account profile");
        settings.CaptureLinks = false; settings.Save();
        await captured.CoreWebView2.ExecuteScriptAsync("location.href='https://external.relay.test/after-toggle'");
        await Until(() => smokeExternalLinks.Count == 5);
        Check(!Settings.Load().CaptureLinks, "Disabling capture takes effect in existing windows and persists");
        foreach (var popup in popups.Where(p => p.Tag == state).ToArray()) popup.Close();
        smokeExternalLinks.Clear();
    }
}
