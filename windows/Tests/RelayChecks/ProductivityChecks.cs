using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckProductivity(string output)
    {
        string fixture = File.ReadAllText(Path.Combine(Environment.CurrentDirectory, "Assets", "Fixtures", "relay-setup-v1.json"));
        var setup = PortableSetup.Decode(fixture, Settings.Definitions());
        Check(setup.HidePaletteButton == true, "Shared fixture carries the hidden palette preference");
        var merged = MergeSetup(new Settings(), setup); var again = MergeSetup(merged, setup);
        Check(again.Accounts.Count == 2 && again.SavedWorkspaces.Count == 1 && again.Bookmarks.Count == 1, "Repeated setup import is idempotent");
        var work = again.Accounts.Single(a => a.Label == "Work");
        Check(again.Bookmarks[0].AccountId == work.Id && again.SavedWorkspaces[0].Focused == work.Id && !again.Services[work.Id].Enabled && again.Services[work.Id].IdentityColor == "Sky", "Import maps workspace/bookmark references into new unloaded local profiles");
        Check(PortableSetup.Decode(setup.Encode(), Settings.Definitions()).Accounts.Count == 2, "Portable setup round trips");
        Check(again.HidePaletteButton, "Setup import hides the palette button");
        var legacy = PortableSetup.Decode(fixture.Replace("\"hidePaletteButton\": true,", ""), Settings.Definitions());
        Check(MergeSetup(new Settings { HidePaletteButton = true }, legacy).HidePaletteButton, "Older exports preserve the current palette visibility preference");
        setup.HidePaletteButton = false;
        Check(!MergeSetup(again, setup).HidePaletteButton, "Setup import can restore the palette button");
        foreach (var invalid in new[] { "{}", fixture.Replace("\"version\": 1", "\"version\": 99"), fixture.Replace("https://web.whatsapp.com/", "javascript:alert(1)"), fixture.Replace("https://web.whatsapp.com/", "https://whatsapp.com.evil.test/"), fixture.Replace("https://web.whatsapp.com/", "https://user:password@web.whatsapp.com/"), fixture.Replace("\"accountId\": \"work\"", "\"accountId\": \"missing\"") })
        {
            bool rejected = false; try { PortableSetup.Decode(invalid, Settings.Definitions()); } catch { rejected = true; }
            Check(rejected, "Invalid version, URL credentials, schemes, hosts and stale bookmark references are rejected before mutation");
        }
        var now = DateTimeOffset.UtcNow;
        Check(Productivity.Snoozed(now.AddSeconds(1).ToUnixTimeSeconds(), now) && !Productivity.Snoozed(now.ToUnixTimeSeconds(), now) && !Productivity.Snoozed(null, now), "Snooze expires at the boundary without a timer or replay");
        Check(Productivity.Matches("work chat", "Work chats", "Bookmark") && !Productivity.Matches("work cat", "Work chats"), "Search matches all words across result metadata");
        Check(Productivity.PaletteMatches("wapp", "WhatsApp") && !Productivity.PaletteMatches("wppa", "WhatsApp"), "Palette fuzzy matching preserves character order");
        var originalSetup = CreateSetup(); var changedSetup = PortableSetup.Decode(originalSetup.Encode(), Settings.Definitions());
        changedSetup.Accounts[0].Color = "Rose";
        var retainedViews = services.Select(s => s.View).ToArray(); var retainedUnread = services.Select(s => s.Unread).ToArray();
        ApplyImportedSettings(MergeSetup(settings, changedSetup));
        Check(services.Select(s => s.View).SequenceEqual(retainedViews) && services.Select(s => s.Unread).SequenceEqual(retainedUnread), "Applying appearance-only setup preserves live profiles and unread state");
        ApplyImportedSettings(MergeSetup(settings, originalSetup));

        var states = services.Where(s => s.Core != null && s.Options.Enabled).Take(2).ToArray();
        Check(states.Length == 2, "Workspace fixtures loaded");
        var saved = new SavedWorkspace { Name = "Daily catch-up", Layout = new() { Panes = states.Select(s => s.Definition.Id).ToList(), Arrangement = "columns", Cuts = [.6] }, Focused = states[1].Definition.Id };
        settings.SavedWorkspaces.Add(saved); settings.Save(); var views = states.Select(s => s.View).ToArray();
        await states[0].Core!.ExecuteScriptAsync("window.__relayWorkspaceDraft='keep this draft'");
        await OpenWorkspace(saved);
        Check(selected == states[1] && states.Select(s => s.View).SequenceEqual(views) && await states[0].Core!.ExecuteScriptAsync("window.__relayWorkspaceDraft") == "\"keep this draft\"", "Saved workspace restores focus while retaining documents and drafts");
        settings.Workspace.Resize(0, .72);
        Check(saved.Layout.Cuts[0] == .6 && Settings.Load().SavedWorkspaces.Any(w => w.Id == saved.Id), "Saved layouts persist and are independent of active divider changes");

        var state = states[0]; bool quiet = settings.Quiet, notifications = state.Options.Notifications;
        var loaded = new TaskCompletionSource();
        EventHandler<Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs>? completedNavigation = null;
        completedNavigation = (_, _) => { state.Core!.NavigationCompleted -= completedNavigation; loaded.TrySetResult(); };
        state.Core!.NavigationCompleted += completedNavigation;
        state.Core.Navigate("https://relay.test/snooze"); await loaded.Task.WaitAsync(TimeSpan.FromSeconds(25));
        await state.Core.Profile.SetPermissionStateAsync(Microsoft.Web.WebView2.Core.CoreWebView2PermissionKind.Notifications, "https://relay.test", Microsoft.Web.WebView2.Core.CoreWebView2PermissionState.Allow);
        settings.Quiet = false; state.Options.Notifications = true;
        Snooze(state, DateTimeOffset.Now.AddHours(1).ToUnixTimeSeconds()); int suppressed = suppressedNotifications;
        await state.Core!.ExecuteScriptAsync("new Notification('Snooze fixture',{body:'Synthetic'})");
        await Until(() => suppressedNotifications == suppressed + 1);
        Check(Settings.Load().Services[state.Definition.Id].SnoozedUntil == state.Options.SnoozedUntil, "Per-account snooze suppresses native notification events and survives restart");
        Snooze(state, DateTimeOffset.Now.AddMinutes(-1).ToUnixTimeSeconds());
        int events = activity.Count;
        await state.Core.ExecuteScriptAsync("new Notification('Expired snooze',{body:'Synthetic'})");
        await Until(() => activity.Count > events || activity.Any(a => a.Title == "Expired snooze"));
        Check(suppressedNotifications == suppressed + 1, "Expired snooze allows the next event without replaying earlier alerts");
        Snooze(state, null); settings.Quiet = quiet; state.Options.Notifications = notifications;

        string[] hosts = state.Definition.Hosts; state.Definition.Hosts = [.. hosts, "relay.test"];
        var bookmark = new AccountBookmark { Name = "Inbox", AccountId = state.Definition.Id, Url = "https://relay.test/bookmark" };
        settings.Bookmarks.Add(bookmark); await OpenBookmark(bookmark);
        await Until(() => state.Core?.Source == bookmark.Url && !state.Loading);
        Check(selected == state && state.View == views[0], "Bookmark navigates the intended account's retained profile");
        settings.Bookmarks.Remove(bookmark); await OpenBookmark(bookmark);
        state.Definition.Hosts = hosts;

        ShowSettings(); var search = LocalContent.Children.OfType<TextBox>().Single(); search.Text = "absolutely-no-matching-setting";
        Check(LocalContent.Children.OfType<FrameworkElement>().Count(e => e.Visibility == Visibility.Visible) == 2, "Settings search has a clear empty state");
        search.Text = "export"; Check(LocalContent.Children.OfType<Border>().Any(e => e.Visibility == Visibility.Visible && SettingsText(e).Contains("Export settings")), "Settings search finds export controls in their section"); search.Text = "";

        foreach (string mode in new[] { "Dark", "Light" })
        {
            settings.Appearance = mode; ApplyTheme(); ShowCommandPalette(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(commandPalette != null, "Palette opens above browser content");
            var panel = (DockPanel)((Border)commandPalette!.Content).Child;
            var query = panel.Children.OfType<TextBox>().Single(); var list = panel.Children.OfType<ListBox>().Single();
            query.Text = "daily catch";
            Check(list.Items.Count == 1 && ((ListBoxItem)list.Items[0]).Tag is PaletteCommand { Title: "Daily catch-up" }, "Palette searches saved workspaces");
            query.Text = ""; commandPalette.UpdateLayout();
            var surface = (FrameworkElement)commandPalette.Content;
            var bitmap = new RenderTargetBitmap((int)surface.ActualWidth, (int)surface.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(surface);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using (var file = File.Create(Path.Combine(output, "command-palette-" + mode.ToLowerInvariant() + ".png"))) encoder.Save(file);
            if (mode == "Light")
            {
                query.Text = "Workspaces & bookmarks";
                commandPalette.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(commandPalette), 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                Check(localPage == "library", "Return executes the selected palette command");
            }
            else commandPalette.Close();
            Check(commandPalette == null, "Closing palette clears its window state without reentrant deactivation");
        }

        string history = Path.Combine(App.DataPath, "history-fixture.json"), completed = Path.Combine(App.DataPath, "completed-fixture.txt"); File.WriteAllText(completed, "keep");
        var row = new DownloadHistoryRecord { Id = "one", AccountId = "fixture", AccountName = "Fixture", Path = completed, Status = "Complete", Started = 1 };
        File.WriteAllText(history, JsonSerializer.Serialize(new[] { row, row }));
        Check(ReadDownloadHistory(history).Count == 1, "Restart history ignores duplicate transfer records");
        var restored = ReadDownloadHistory(history)[0]; File.Delete(completed);
        Check(restored.Status == "Complete" && !File.Exists(restored.Path), "Missing files remain historical records rather than active transfers");
        settings.SavedWorkspaces.Remove(saved); settings.Appearance = "Dark"; ApplyTheme(); settings.Save();
        await CheckProductivityUi(output);
        File.WriteAllText(Path.Combine(output, "productivity-checks.txt"), "PASS: portable setup validation/idempotent merge/profile mapping, persistent workspaces/document retention, scoped bookmark navigation, snooze suppression/expiry, settings search, palette dark/light, download history deduplication/missing files.");
    }
}
