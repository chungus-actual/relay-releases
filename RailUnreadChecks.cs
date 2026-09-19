using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckRailAndUnread(string output)
    {
        var originalOrder = settings.ServiceOrder.ToList();
        var source = shortcutServices[0];
        var originalView = source.View;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        ServiceRailScroll.ScrollToTop();
        ServiceRail.UpdateLayout();
        BeginShortcutDrag(railButtons[source.Definition.Id], source, 12, false);
        shortcutDragTimer.Stop();
        UpdateShortcutDrag(dragPitch * 3 + 12);
        await Task.Delay(180);
        Check(dragDestination == 3 && ((TranslateTransform)railButtons[shortcutServices[1].Definition.Id].RenderTransform).Y < -dragPitch + 1,
            $"Dragging previews the new slot and slides neighboring shortcuts aside (target={dragDestination}, source={dragOrigin}, pitch={dragPitch}, offset={((TranslateTransform)railButtons[shortcutServices[1].Definition.Id].RenderTransform).Y}, active={draggingShortcut != null}, height={ServiceRail.ActualHeight}, viewport={ServiceRailScroll.ViewportHeight})");
        Check(draggedButton!.Cursor == Cursors.SizeNS
            && ((TranslateTransform)draggedButton.RenderTransform).X == 0, "Shortcut drag uses its own cursor and stays on the rail's horizontal axis");
        Capture(Path.Combine(output, "rail-drag-preview.png"));
        UpdateShortcutDrag(100000);
        Check(draggedButton!.TranslatePoint(new Point(), ServiceRailScroll).Y + draggedButton.ActualHeight <= ServiceRailScroll.ViewportHeight + 2,
            "Dragging beyond the rail clamps the icon inside its viewport");
        FinishShortcutDrag(false);
        Check(settings.ServiceOrder.SequenceEqual(originalOrder) && Mouse.Captured == null && !shortcutDragTimer.IsEnabled,
            "Canceling a drag restores order and releases capture");
        BeginShortcutDrag(railButtons[source.Definition.Id], source, 12, false); shortcutDragTimer.Stop();
        UpdateShortcutDrag(dragPitch * 2 + 12); FinishShortcutDrag(true);
        Check(shortcutServices[2] == source && Settings.Load().ServiceOrder.SequenceEqual(settings.ServiceOrder) && source.View == originalView,
            "Dropping commits the preview order without replacing service sessions");
        settings.ServiceOrder = originalOrder; settings.Save(); RebuildShortcuts();
        await Task.Delay(180);
        SetTopTabs(true); settings.Save();
        Width = 720;
        await SelectService(source);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(Settings.Load().TopTabs && SidebarColumn.ActualWidth == 0 && ServiceRail.Orientation == System.Windows.Controls.Orientation.Horizontal,
            "Top tabs persist and return the left rail's width to content");
        Check(WebHost.TranslatePoint(new Point(), this).X < 5 && ServiceRailScroll.ScrollableWidth > 0
            && SettingsButton.TranslatePoint(new Point(SettingsButton.ActualWidth, 0), this).X <= ActualWidth,
            "Top tabs scroll while keeping utilities visible at minimum width");
        BeginShortcutDrag(railButtons[source.Definition.Id], source, 12, false);
        UpdateShortcutDrag(dragPitch * 2 + 12);
        await Task.Delay(180);
        Check(dragDestination == 2 && ((TranslateTransform)railButtons[shortcutServices[1].Definition.Id].RenderTransform).X < -dragPitch + 1
            && ((TranslateTransform)draggedButton!.RenderTransform).Y == 0, "Top tabs reorder horizontally with the same neighbor animation");
        Capture(Path.Combine(output, "top-tabs-drag.png"));
        FinishShortcutDrag(false);
        SidebarToggleClick(this, new RoutedEventArgs());
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(TopRailRow.ActualHeight == 40 && SettingsButton.IsVisible, "Compact top tabs keep a slim strip and accessible settings");
        Capture(Path.Combine(output, "top-tabs-compact.png"));
        SidebarToggleClick(this, new RoutedEventArgs());
        SetTopTabs(false); settings.Save(); Width = 1280;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(TopRailRow.ActualHeight == 0 && SidebarColumn.ActualWidth == 64 && !Settings.Load().TopTabs,
            "Switching back restores the vertical rail");
        SetShortcutVisible(source, false);
        await OpenHiddenService(source);
        Check(source.Options.ShowShortcut && railButtons.ContainsKey(source.Definition.Id) && Settings.Load().Services[source.Definition.Id].ShowShortcut,
            "Opening a hidden service restores and persists its rail shortcut");

        var messenger = services.Single(s => s.Definition.Id == "messenger");
        await SelectService(messenger);
        messenger.Core!.Navigate("https://www.facebook.com/messages/unread-fixture");
        await Until(() => messenger.Core!.Source.Contains("unread-fixture") && messenger.Status == "Live");
        await messenger.Core.ExecuteScriptAsync("""
            document.body.innerHTML='<div role="main"><div id="pane" style="height:200px;overflow:auto"><div style="height:2000px">Chat</div></div><input id="draft" value="Unsent message"></div>';
            window.refreshes=0;window.token=Math.random();window.originalToken=window.token;
            const pane=document.getElementById('pane');pane.addEventListener('scroll',e=>{if(e.isTrusted && pane.scrollTop!==window.expectedTop) window.refreshes++;});pane.scrollTop=420;
            """);
        await Task.Delay(300);
        foreach (var offset in new[] { 420, 0, 1800 })
        {
            await messenger.Core.ExecuteScriptAsync($"pane.scrollTop={offset}");
            await Task.Delay(100);
            ShowSettings();
            await messenger.Core.ExecuteScriptAsync("window.refreshes=0;window.expectedTop=pane.scrollTop");
            await SelectService(messenger);
            await messenger.Core.ExecuteScriptAsync("window.__relayMessengerChrome.activate();window.__relayMessengerChrome.activate()");
            await Task.Delay(300);
            Check(await messenger.Core.ExecuteScriptAsync("window.refreshes>0 && pane.scrollTop===window.expectedTop && document.getElementById('draft').value==='Unsent message' && window.token===window.originalToken") == "true",
                "Messenger activation refreshes chat and preserves scroll, draft, and document");
        }
        await messenger.Core.ExecuteScriptAsync("""
            pane.scrollTop=420;
            pane.addEventListener('scroll', function userScroll(e) {
              if (e.isTrusted && pane.scrollTop===421) { pane.scrollTop=700; pane.removeEventListener('scroll', userScroll); }
            });
            window.__relayMessengerChrome.activate();
            """);
        await Task.Delay(300);
        Check(await messenger.Core.ExecuteScriptAsync("pane.scrollTop===700") == "true",
            "Messenger activation preserves a newer scroll");
        await messenger.Core.ExecuteScriptAsync("""
            document.title='(987) Facebook';
            document.body.innerHTML='<nav><a id="total" aria-label="Messenger, 4 unread messages"></a></nav><div role="grid"><div role="row"><a href="/messages/t/fixture"><span aria-label="Unread"></span></a></div></div>';
            """);
        await ReadProviderUnread(messenger);
        await Until(() => messenger.Unread == 4);
        Check(messenger.Badge == "4", "Messenger-specific unread total overrides unrelated Facebook notification count");
        var savedActivity = activity.ToArray();
        var other = services.Single(s => s.Definition.Id == "whatsapp");
        activity.Add(new(messenger, "Fixture", "", DateTimeOffset.Now, null));
        activity.Add(new(other, "Keep", "", DateTimeOffset.Now, null));
        var dismiss = railButtons[messenger.Definition.Id].ContextMenu.Items.OfType<System.Windows.Controls.MenuItem>().Single(item => Equals(item.Header, "Dismiss"));
        dismiss.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.MenuItem.ClickEvent));
        await ReadProviderUnread(messenger);
        Check(messenger.Badge == "" && !activity.Any(a => a.Service == messenger) && activity.Any(a => a.Service == other),
            "Per-service dismissal clears its badge and activity without touching other accounts or returning on the next poll");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('#total').setAttribute('aria-label','Messenger, 5 unread messages')");
        await ReadProviderUnread(messenger);
        Check(messenger.Unread == 5, "Fresh unread evidence restores a dismissed service badge");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('#total').remove()");
        await ReadProviderUnread(messenger);
        Check(messenger.Unread == null && messenger.Badge == "•", "Virtualized unread rows show activity without inventing an exact total");
        await messenger.Core.ExecuteScriptAsync("document.querySelector('[aria-label=Unread]').remove();document.body.insertAdjacentHTML('beforeend','<button aria-label=\"Mark as unread\">Unread</button>')");
        await ReadProviderUnread(messenger);
        Check(messenger.Badge == "", "Read chats and the Mark as unread action do not create a false unread badge");
        await messenger.Core.ExecuteScriptAsync("document.title='(12+) Messenger'");
        await ReadProviderUnread(messenger);
        await Until(() => messenger.Unread == 12);
        Check(ServiceState.CountFromTitle("(99+) Messenger") == 99, "Unread titles accept capped counts");
        var gmail = services.Single(s => s.Definition.Id == "gmail");
        gmail.Options.GmailAllUnread = true;
        await SelectService(gmail);
        gmail.Core!.Navigate("https://mail.google.com/mail/u/0/#sent");
        await Until(() => gmail.Core!.Source.Contains("mail.google.com/mail/") && gmail.Status == "Live");
        await gmail.Core.ExecuteScriptAsync("""
            document.title='Sent Mail - Gmail';
            document.body.innerHTML='<nav><div class="aim"><a href="#inbox">Inbox</a><span class="bsU">1,234</span></div></nav>';
            """);
        await Until(() => gmail.Unread == 1234);
        int gmailActivity = activity.Count(item => item.Service == gmail);
        await ReadProviderUnread(gmail);
        Check(activity.Count(item => item.Service == gmail) == gmailActivity, "Unchanged Gmail count does not duplicate pending activity");
        await gmail.Core.ExecuteScriptAsync("document.querySelector('.bsU').textContent='1,235'");
        await Until(() => gmail.Unread == 1235);
        Check(activity.Count(item => item.Service == gmail) == gmailActivity + 1, "Gmail polling captures new unread mail without a title change");
        SetGmailUnreadMode(gmail, false);
        settings.Save();
        Check(gmail.Unread == 0 && !Settings.Load().Services[gmail.Definition.Id].GmailAllUnread,
            "New-since-launch mode excludes backlog and persists");
        await gmail.Core.ExecuteScriptAsync("document.querySelector('.bsU').textContent='1,236'");
        await Until(() => gmail.Unread == 1);
        Check(activity.Count(item => item.Service == gmail) == 1, "Only the new unread increment creates pending activity");
        DismissService(gmail);
        await ReadProviderUnread(gmail);
        Check(gmail.Badge == "" && !activity.Any(item => item.Service == gmail), "Dismissed Gmail unread stays dismissed");
        await gmail.Core.ExecuteScriptAsync("document.querySelector('.bsU').remove()");
        await Until(() => gmail.Unread == 0);
        Check(gmail.Badge == "", "Reading all Gmail inbox mail clears its badge");
        await SelectService(messenger);
        activity.Clear(); activity.AddRange(savedActivity);
        messenger.Core.Navigate("https://relay.test/");
        await Until(() => messenger.Unread == 3 && messenger.Status == "Live");
    }
}
