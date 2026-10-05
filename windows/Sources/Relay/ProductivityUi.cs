using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace Relay;

public partial class MainWindow
{
    private Window? commandPalette;
    private string? lastFocusedAccount;
    private readonly Dictionary<string, int> bookmarkNavigations = [];
    private string settingsQuery = "";
    private sealed record PaletteCommand(string Title, string Detail, Func<Task> Run);
    private static string SettingsText(DependencyObject element)
    {
        string result = element is TextBlock text ? text.Text : element is ContentControl { Content: string value } ? value : "";
        if (element is FrameworkElement { Tag: string keywords }) result += " " + keywords;
        foreach (var child in LogicalTreeHelper.GetChildren(element).OfType<DependencyObject>()) result += " " + SettingsText(child);
        return result;
    }
    private void InstallSettingsSearch()
    {
        var input = SettingsInput("Search settings", settingsQuery);
        input.Height = 38; input.Padding = new Thickness(6, 4, 6, 4); input.FontSize = 13;
        input.Margin = new Thickness(0, 0, 0, 14);
        var sections = LocalContent.Children.OfType<FrameworkElement>().ToArray();
        var empty = Muted("No matching settings. Try appearance, notifications, or an account name.", 12);
        LocalContent.Children.Insert(0, input); LocalContent.Children.Add(empty);
        void Filter()
        {
            settingsQuery = input.Text;
            foreach (var section in sections) section.Visibility = Productivity.Matches(settingsQuery, SettingsText(section)) ? Visibility.Visible : Visibility.Collapsed;
            foreach (var row in serviceSettingsList.Children.OfType<FrameworkElement>()) row.Visibility = Productivity.Matches(settingsQuery, SettingsText(row), row.Tag is ServiceState state ? state.Definition.Name + " services accounts identity color load sleep awake notifications mute zoom" : "") ? Visibility.Visible : Visibility.Collapsed;
            serviceSettingsList.Visibility = serviceSettingsList.Children.OfType<FrameworkElement>().Any(row => row.Visibility == Visibility.Visible) ? Visibility.Visible : Visibility.Collapsed;
            empty.Visibility = sections.Any(s => s.Visibility == Visibility.Visible) ? Visibility.Collapsed : Visibility.Visible;
        }
        input.TextChanged += (_, _) => Filter(); Filter();
    }
    private Button ActionButton(string title, Action action)
    {
        var button = new Button { Content = title, FontFamily = FontFamily, Margin = new Thickness(0, 4, 8, 4), Padding = new Thickness(10, 7, 10, 7) };
        button.SetResourceReference(Control.BackgroundProperty, "Panel"); button.SetResourceReference(Control.BorderBrushProperty, "Line");
        button.Click += (_, _) => { try { action(); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Relay"); } };
        return button;
    }
    private Button AsyncActionButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title, FontFamily = FontFamily, Margin = new Thickness(0, 4, 8, 4), Padding = new Thickness(10, 7, 10, 7) };
        button.SetResourceReference(Control.BackgroundProperty, "Panel"); button.SetResourceReference(Control.BorderBrushProperty, "Line");
        button.Click += async (_, _) => { try { await action(); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Relay"); } };
        return button;
    }
    private TextBox SettingsInput(string title, string text = "")
    {
        var input = new TextBox { Text = text, Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 6, 0, 10) };
        input.SetResourceReference(Control.BackgroundProperty, "Card"); input.SetResourceReference(Control.ForegroundProperty, "Ink");
        input.SetResourceReference(Control.BorderBrushProperty, "Line");
        input.Style = (Style)FindResource("LabeledInput"); input.Tag = title;
        System.Windows.Automation.AutomationProperties.SetName(input, title); return input;
    }
    private void HidePaletteButtonClick(object sender, RoutedEventArgs e) => SetPaletteButtonHidden(true);
    private void SetPaletteButtonHidden(bool hidden)
    {
        bool previous = settings.HidePaletteButton; settings.HidePaletteButton = hidden;
        try { settings.Save(); } catch { settings.HidePaletteButton = previous; throw; }
        ApplySidebarSize();
    }
    private void PaletteClick(object sender, RoutedEventArgs e) => ToggleCommandPalette();
    private void ToggleCommandPalette()
    {
        if (commandPalette is { } window) DismissCommandPalette(window);
        else ShowCommandPalette();
    }
    private void DismissCommandPalette(Window window)
    {
        window.Close();
        if (!quitting && IsVisible) { Activate(); selected?.View?.Focus(); }
    }
    private void ShowCommandPalette()
    {
        if (commandPalette != null) { commandPalette.Activate(); return; }
        var window = new Window { Owner = this, Title = "Relay · Find your way", Width = 590, Height = 480,
            ResizeMode = ResizeMode.NoResize, WindowStyle = WindowStyle.None, ShowInTaskbar = false, ShowActivated = !App.SmokeTest, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        window.SetResourceReference(BackgroundProperty, "Panel"); window.SetResourceReference(ForegroundProperty, "Ink");
        var surface = new DockPanel { Margin = new Thickness(22) };
        var heading = new DockPanel();
        var pet = new PetDrawing(new PetMotion(kind: settings.TitlebarCompanion), true) { Width = 65, Height = 38, IsHitTestVisible = false };
        DockPanel.SetDock(pet, Dock.Right); heading.Children.Add(pet);
        var text = new StackPanel(); text.Children.Add(Label("Find your way", 19, true)); text.Children.Add(Muted("Accounts, workspaces, bookmarks & actions", 11)); heading.Children.Add(text);
        DockPanel.SetDock(heading, Dock.Top); surface.Children.Add(heading);
        var search = SettingsInput("Search commands"); search.Margin = new Thickness(0, 16, 0, 12);
        search.Tag = "Search accounts, places, or actions"; search.MaxLength = 200;
        DockPanel.SetDock(search, Dock.Top); surface.Children.Add(search);
        var footer = Muted("↑ ↓  choose     Enter  open     Esc  back", 11); footer.Margin = new Thickness(0, 12, 0, 0);
        DockPanel.SetDock(footer, Dock.Bottom); surface.Children.Add(footer);
        var results = new ListBox { BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent };
        results.ItemContainerStyle = (Style)FindResource("CommandPaletteItem");
        ScrollViewer.SetHorizontalScrollBarVisibility(results, ScrollBarVisibility.Disabled);
        results.SetResourceReference(ForegroundProperty, "Ink"); surface.Children.Add(results);
        var commands = new List<PaletteCommand>();
        foreach (var state in OrderedServices()) commands.Add(new(state.Definition.Name,
            "Account" + (state.Badge.Length > 0 ? " · " + state.Badge + " unread" : "") + (!state.Options.ShowShortcut ? " · Hidden" : ""), () => SelectService(state)));
        foreach (var saved in settings.SavedWorkspaces) commands.Add(new(saved.Name, "Workspace · " + saved.Layout.Panes.Count + " panes", () => OpenWorkspace(saved)));
        foreach (var bookmark in settings.Bookmarks)
        {
            var account = services.Find(s => s.Definition.Id == bookmark.AccountId);
            if (account != null) commands.Add(new(bookmark.Name, "Bookmark · " + account.Definition.Name, () => OpenBookmark(bookmark)));
        }
        void Command(string title, Action action) => commands.Add(new(title, "Action", () => { action(); return Task.CompletedTask; }));
        Command("Settings", ShowSettings); Command("Activity", ShowActivity);
        Command("Workspaces & bookmarks", ShowLibrary); Command("Save current workspace", () => ShowWorkspaceEditor());
        if (selected is { } activeAccount) Command("Bookmark current page", () => ShowBookmarkEditor(activeAccount));
        Command("Downloads", () => { if (DownloadsPanel.Visibility != Visibility.Visible) DownloadsClick(this, new RoutedEventArgs()); });
        Command("Snooze notifications for 1 hour", () => Snooze(null, DateTimeOffset.Now.AddHours(1).ToUnixTimeSeconds()));
        Command("Resume snoozed notifications", () => Snooze(null, null));
        Command("Export settings", ExportSetup); Command("Import settings", ImportSetup);
        if (mediaService is { } playingAccount)
        {
            string action = mediaPlaying ? "pause" : "play";
            commands.Add(new(mediaPlaying ? "Pause playback" : "Play", "Playback · " + playingAccount.Definition.Name,
                () => mediaService == playingAccount ? MediaAction(action) : Task.CompletedTask));
            if (MediaPreviousButton.IsEnabled) commands.Add(new("Previous track", "Playback", () => mediaService == playingAccount ? MediaAction("previoustrack") : Task.CompletedTask));
            if (MediaNextButton.IsEnabled) commands.Add(new("Next track", "Playback", () => mediaService == playingAccount ? MediaAction("nexttrack") : Task.CompletedTask));
        }
        var empty = Label("No matches. Try an account name or an action.", 12);
        void Filter()
        {
            results.Items.Clear();
            foreach (var command in commands.Where(c => Productivity.PaletteMatches(search.Text, c.Title, c.Detail)).OrderBy(c => c.Title.StartsWith(search.Text, StringComparison.OrdinalIgnoreCase) ? 0 : c.Title.Contains(search.Text, StringComparison.OrdinalIgnoreCase) ? 1 : 2))
            {
                var row = new StackPanel { Margin = new Thickness(8, 7, 8, 7) };
                row.Children.Add(Label(command.Title, 13, true)); row.Children.Add(Muted(command.Detail, 10));
                var item = new ListBoxItem { Content = row, Tag = command, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                System.Windows.Automation.AutomationProperties.SetName(item, command.Title + ", " + command.Detail); results.Items.Add(item);
            }
            if (results.Items.Count == 0) results.Items.Add(new ListBoxItem { Content = empty, IsEnabled = false });
            else results.SelectedIndex = 0;
        }
        async Task Run()
        {
            if (results.SelectedItem is not ListBoxItem { Tag: PaletteCommand command }) return;
            DismissCommandPalette(window);
            try { await command.Run(); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Relay"); }
        }
        search.TextChanged += (_, _) => Filter();
        window.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.Escape || e.Key == Key.K && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; DismissCommandPalette(window); }
            else if (e.Key == Key.Enter) { e.Handled = true; await Run(); }
            else if (e.Key is Key.Up or Key.Down) { e.Handled = true; results.SelectedIndex = Math.Clamp(results.SelectedIndex + (e.Key == Key.Down ? 1 : -1), 0, Math.Max(0, results.Items.Count - 1)); results.ScrollIntoView(results.SelectedItem); }
        };
        results.PreviewMouseLeftButtonUp += async (_, _) => await Run();
        window.Content = new Border { Child = surface, BorderThickness = new Thickness(1), BorderBrush = Brush("Line"), Background = Brush("Panel") };
        bool closing = false;
        window.Closing += (_, _) => closing = true;
        window.Deactivated += (_, _) => Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, new Action(() =>
        {
            if (closing || commandPalette != window || window.IsActive) return;
            // Let native activation finish before destroying its outgoing window.
            // A click on the launcher is handled by its normal toggle event.
            if (IsActive && PaletteButton.IsVisible && new Rect(PaletteButton.RenderSize).Contains(Mouse.GetPosition(PaletteButton))) return;
            window.Close();
        }));
        window.Closed += (_, _) => { if (commandPalette == window) commandPalette = null; };
        commandPalette = window; Filter(); window.Show(); search.Focus();
    }

    private void Snooze(ServiceState? account, long? until)
    {
        if (account == null) settings.SnoozedUntil = until; else account.Options.SnoozedUntil = until;
        settings.Save(); Refresh();
        if (localPage == "settings") RebuildSettings();
    }
    private MenuItem SnoozeMenu(ServiceState? account)
    {
        var menu = new MenuItem { Header = "Snooze notifications" };
        menu.SubmenuOpened += (_, _) => { menu.Items.Clear(); AddSnoozeChoices(menu, account); };
        AddSnoozeChoices(menu, account);
        return menu;
    }
    private void AddSnoozeChoices(ItemsControl menu, ServiceState? account)
    {
        foreach (var (name, minutes) in new[] { ("30 minutes", 30), ("1 hour", 60), ("8 hours", 480) })
        { var item = new MenuItem { Header = name }; item.Click += (_, _) => Snooze(account, DateTimeOffset.Now.AddMinutes(minutes).ToUnixTimeSeconds()); menu.Items.Add(item); }
        var morning = new MenuItem { Header = "Until tomorrow at 9 AM" };
        morning.Click += (_, _) => Snooze(account, new DateTimeOffset(DateTime.Today.AddDays(1).AddHours(9)).ToUnixTimeSeconds()); menu.Items.Add(morning);
        var until = account?.Options.SnoozedUntil ?? (account == null ? settings.SnoozedUntil : null);
        var resume = new MenuItem { Header = "Resume now", IsEnabled = Productivity.Snoozed(until, DateTimeOffset.Now) };
        resume.Click += (_, _) => Snooze(account, null); menu.Items.Add(new Separator()); menu.Items.Add(resume);
    }
    private async Task OpenWorkspace(SavedWorkspace saved)
    {
        if (!settings.SavedWorkspaces.Contains(saved)) return;
        var layout = Productivity.Copy(saved.Layout); layout.Normalize(services.Select(s => s.Definition.Id));
        if (layout.Panes.Count == 0) throw new InvalidOperationException("This workspace's accounts are no longer available.");
        foreach (var state in services.Where(s => layout.Panes.Contains(s.Definition.Id))) state.Options.Enabled = true;
        settings.Workspace = layout;
        await SelectService(services.Single(s => s.Definition.Id == (layout.Panes.Contains(saved.Focused ?? "") ? saved.Focused : layout.Panes[0])));
    }
    private async Task OpenBookmark(AccountBookmark bookmark)
    {
        var state = services.Find(s => s.Definition.Id == bookmark.AccountId);
        if (state == null || !settings.Bookmarks.Contains(bookmark) || !Productivity.BookmarkAllowed(bookmark.Url, state.Definition)) return;
        int generation = bookmarkNavigations.GetValueOrDefault(bookmark.AccountId) + 1; bookmarkNavigations[bookmark.AccountId] = generation;
        await SelectService(state);
        if (services.Contains(state) && selected == state && state.Options.Enabled && settings.Bookmarks.Contains(bookmark) && bookmarkNavigations[bookmark.AccountId] == generation) state.Core?.Navigate(bookmark.Url);
    }
}
