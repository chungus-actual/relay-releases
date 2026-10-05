using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace Relay;

public partial class MainWindow
{
    private string placesQuery = "";
    private void ShowLibrary()
    {
        ShowLocal("library", "Workspaces & bookmarks", ""); LocalContent.Children.Clear();
        var search = SettingsInput("Search workspaces, bookmarks, or accounts", placesQuery);
        search.Padding = new Thickness(6, 4, 6, 4); search.Height = 38;
        LocalContent.Children.Add(search);
        var workspaces = new StackPanel();
        var save = ActionButton("Save current workspace…", () => ShowWorkspaceEditor());
        save.IsEnabled = settings.Workspace.Panes.Count > 0;
        if (!save.IsEnabled) save.ToolTip = "Open an account to save a workspace.";
        LocalContent.Children.Add(PlacesHeading("Workspaces", save)); LocalContent.Children.Add(workspaces);
        var bookmarks = new StackPanel();
        var add = ActionButton("Add bookmark…", () => ShowBookmarkEditor()); add.IsEnabled = services.Count > 0;
        LocalContent.Children.Add(PlacesHeading("Bookmarks", add)); LocalContent.Children.Add(bookmarks);
        void Filter()
        {
            placesQuery = search.Text; workspaces.Children.Clear(); bookmarks.Children.Clear();
            foreach (var saved in settings.SavedWorkspaces)
            {
                string accounts = string.Join(" · ", saved.Layout.Panes.Select(id => services.Find(s => s.Definition.Id == id)?.Definition.Name).OfType<string>());
                if (!Productivity.Matches(placesQuery, saved.Name, accounts)) continue;
                workspaces.Children.Add(SavedPlaceRow(saved.Name, accounts, saved.Id,
                    AsyncActionButton("Open", () => OpenWorkspace(saved)), ActionButton("Edit", () => ShowWorkspaceEditor(saved)),
                    ActionButton("Delete", () => { settings.SavedWorkspaces.Remove(saved); settings.Save(); Filter(); })));
            }
            if (workspaces.Children.Count == 0) workspaces.Children.Add(PlacesEmpty(settings.SavedWorkspaces.Count == 0 ? "No saved workspaces yet." : "No matching workspaces."));
            foreach (var account in OrderedServices())
            {
                var items = settings.Bookmarks.Where(b => b.AccountId == account.Definition.Id && Productivity.Matches(placesQuery, b.Name, b.Url, account.Definition.Name)).ToArray();
                if (items.Length == 0) continue;
                var heading = Label(account.Definition.Name, 12, true); heading.Margin = new Thickness(0, 12, 0, 8); bookmarks.Children.Add(heading);
                foreach (var bookmark in items)
                    bookmarks.Children.Add(SavedPlaceRow(bookmark.Name, bookmark.Url, bookmark.Id,
                        AsyncActionButton("Open", () => OpenBookmark(bookmark)), ActionButton("Edit", () => ShowBookmarkEditor(account, bookmark)),
                        ActionButton("Delete", () => { settings.Bookmarks.Remove(bookmark); settings.Save(); Filter(); })));
            }
            if (bookmarks.Children.Count == 0) bookmarks.Children.Add(PlacesEmpty(settings.Bookmarks.Count == 0 ? "No bookmarks yet." : "No matching bookmarks."));
        }
        search.TextChanged += (_, _) => Filter(); Filter();
    }
    private DockPanel PlacesHeading(string title, Button action)
    {
        var heading = new DockPanel { Margin = new Thickness(0, 16, 0, 10), LastChildFill = true };
        action.Margin = new Thickness(8, 0, 0, 0); DockPanel.SetDock(action, Dock.Right); heading.Children.Add(action);
        var label = Label(title, 16, true); label.VerticalAlignment = VerticalAlignment.Center; heading.Children.Add(label); return heading;
    }
    private Border PlacesEmpty(string text) => Card(Muted(text, 12), new Thickness(16));
    private Border SavedPlaceRow(string name, string detail, string id, params Button[] buttons)
    {
        var row = new DockPanel();
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        foreach (var button in buttons) { button.Margin = new Thickness(4, 0, 0, 0); actions.Children.Add(button); }
        DockPanel.SetDock(actions, Dock.Right); row.Children.Add(actions);
        var title = Label(name, 13, true); title.TextTrimming = TextTrimming.CharacterEllipsis; title.TextWrapping = TextWrapping.NoWrap; title.ToolTip = name;
        var subtitle = Muted(detail, 11); subtitle.TextTrimming = TextTrimming.CharacterEllipsis; subtitle.TextWrapping = TextWrapping.NoWrap; subtitle.ToolTip = detail;
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; text.Children.Add(title); text.Children.Add(subtitle); row.Children.Add(text);
        var card = Card(row, new Thickness(16)); card.Tag = id; card.Margin = new Thickness(0, 0, 0, 8); return card;
    }
    private void ShowWorkspaceEditor(SavedWorkspace? existing = null)
    {
        var snapshot = Productivity.Copy(settings.Workspace); var focus = selected?.Definition.Id ?? lastFocusedAccount;
        ShowLocal("workspace-editor", existing == null ? "Save workspace" : "Edit workspace", ""); LocalContent.Children.Clear();
        var form = new StackPanel();
        var input = SettingsInput("Workspace name", existing?.Name ?? ""); input.MaxLength = 80;
        form.Children.Add(Label("Name", 12)); form.Children.Add(input);
        form.Children.Add(Muted(string.Join(" · ", (existing?.Layout ?? snapshot).Panes.Select(id => services.Find(s => s.Definition.Id == id)?.Definition.Name).OfType<string>()), 12));
        var replace = new CheckBox { Content = "Replace saved panes with the current layout", IsChecked = false, Margin = new Thickness(0, 10, 0, 10), IsEnabled = snapshot.Panes.Count > 0 };
        if (existing != null) form.Children.Add(replace);
        var actions = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
        actions.Children.Add(ActionButton("Save", () =>
        {
            string name = Productivity.Name(input.Text);
            if (existing != null && !settings.SavedWorkspaces.Contains(existing)) throw new InvalidOperationException("This workspace no longer exists.");
            if (settings.SavedWorkspaces.Any(w => w != existing && w.Name.Equals(name, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("That workspace name is already in use.");
            if (existing == null && settings.SavedWorkspaces.Count >= 32) throw new InvalidOperationException("You can save up to 32 workspaces.");
            var layout = existing == null || replace.IsChecked == true ? snapshot : existing.Layout;
            if (layout.Panes.Count == 0) throw new InvalidOperationException("Open an account before saving a workspace.");
            if (existing == null) settings.SavedWorkspaces.Add(new() { Name = name, Layout = layout, Focused = focus });
            else { existing.Name = name; existing.Layout = layout; if (replace.IsChecked == true) existing.Focused = focus; }
            settings.Save(); placesQuery = ""; ShowLibrary();
        }));
        actions.Children.Add(ActionButton("Cancel", ShowLibrary)); form.Children.Add(actions); LocalContent.Children.Add(Card(form)); input.Focus();
    }
    private void ShowBookmarkEditor(ServiceState? initial = null, AccountBookmark? existing = null)
    {
        var chosen = initial ?? services.Find(s => s.Definition.Id == (selected?.Definition.Id ?? lastFocusedAccount)) ?? OrderedServices().FirstOrDefault();
        if (chosen == null) return;
        string Address(ServiceState account) => account.Core?.Source is string source && Productivity.BookmarkAllowed(source, account.Definition) ? source : account.Definition.Url;
        ShowLocal("bookmark-editor", existing == null ? "Add bookmark" : "Edit bookmark", ""); LocalContent.Children.Clear();
        var form = new StackPanel();
        var name = SettingsInput("Bookmark name", existing?.Name ?? chosen.Definition.Name); name.MaxLength = 80;
        var url = SettingsInput("HTTPS address", existing?.Url ?? Address(chosen)); url.MaxLength = 4096;
        var account = ActionButton(chosen.Definition.Name + " ▾", () => { });
        account.HorizontalAlignment = HorizontalAlignment.Left; account.Tag = "bookmark-account";
        account.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = account, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            foreach (var state in OrderedServices())
            {
                var item = new MenuItem { Header = state.Definition.Name, IsCheckable = true, IsChecked = state == chosen, Tag = state.Definition.Id };
                item.Click += (_, _) =>
                {
                    if (name.Text == chosen.Definition.Name) name.Text = state.Definition.Name;
                    if (url.Text == Address(chosen)) url.Text = Address(state);
                    chosen = state; account.Content = state.Definition.Name + " ▾";
                    System.Windows.Automation.AutomationProperties.SetName(account, "Account: " + state.Definition.Name);
                };
                menu.Items.Add(item);
            }
            account.ContextMenu = menu; menu.IsOpen = true;
        };
        System.Windows.Automation.AutomationProperties.SetName(account, "Account: " + chosen.Definition.Name);
        form.Children.Add(Label("Account", 12)); form.Children.Add(account);
        form.Children.Add(Label("Name", 12)); form.Children.Add(name); form.Children.Add(Label("Address", 12)); form.Children.Add(url);
        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        actions.Children.Add(ActionButton("Save", () =>
        {
            if (!services.Contains(chosen) || existing != null && !settings.Bookmarks.Contains(existing)) throw new InvalidOperationException("This account or bookmark no longer exists.");
            var label = Productivity.Name(name.Text); var target = url.Text.Trim();
            if (!Productivity.BookmarkAllowed(target, chosen.Definition)) throw new InvalidOperationException("Choose an HTTPS page belonging to this account's service.");
            var item = existing ?? settings.Bookmarks.Find(b => b.AccountId == chosen.Definition.Id && b.Url == target);
            if (item == null) { if (settings.Bookmarks.Count >= 200) throw new InvalidOperationException("You can save up to 200 bookmarks."); item = new(); settings.Bookmarks.Add(item); }
            settings.Bookmarks.RemoveAll(b => b != item && b.AccountId == chosen.Definition.Id && b.Url == target);
            item.AccountId = chosen.Definition.Id; item.Name = label; item.Url = target; settings.Save(); placesQuery = ""; ShowLibrary();
        }));
        actions.Children.Add(ActionButton("Cancel", ShowLibrary)); form.Children.Add(actions); LocalContent.Children.Add(Card(form)); name.Focus();
    }
}
