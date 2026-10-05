using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Relay;

public partial class MainWindow
{
    private void ShowSettings()
    {
        ShowLocal("settings", "Settings", "");
        LocalContent.Children.Clear();
        var appearance = new StackPanel();
        appearance.Children.Add(Label("Appearance", 15, true));
        appearance.Children.Add(ChoiceRow("Mode", new[] { "System", "Dark", "Light" }, settings.Appearance, value => settings.Appearance = value));
        appearance.Children.Add(ChoiceRow("Surface", new[] { "Graphite", "Ocean", "Dune" }, settings.Palette, value => settings.Palette = value, true));
        var accentLabel = Muted("Accent", 11); accentLabel.Margin = new Thickness(0, 17, 0, 8); appearance.Children.Add(accentLabel);
        var accents = new WrapPanel();
        foreach (var name in new[] { "Mint", "Sky", "Iris", "Rose", "Amber" })
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new Ellipse { Width = 12, Height = 12, Fill = ColorBrush(AccentColor(name, darkTheme)), Margin = new Thickness(0, 0, 8, 0) });
            content.Children.Add(Label(name, 11));
            var button = new Button { Content = content, Margin = new Thickness(0, 0, 7, 0), Padding = new Thickness(10, 8, 10, 8), ToolTip = name + " accent" };
            button.SetResourceReference(Button.BackgroundProperty, settings.AccentName == name ? "AccentSoft" : "Card");
            button.SetResourceReference(Button.BorderBrushProperty, settings.AccentName == name ? "Accent" : "Line");
            button.Click += (_, _) => { settings.AccentName = name; ApplyTheme(); settings.Save(); RebuildSettings(); };
            accents.Children.Add(button);
        }
        appearance.Children.Add(accents);
        AddCheck(appearance, "Top tabs", settings.TopTabs, SetTopTabs);
        AddCheck(appearance, "Command palette button", !settings.HidePaletteButton, value => SetPaletteButtonHidden(!value));
        AddCheck(appearance, "Companion", settings.TitlebarPetEnabled, SetPetEnabled);
        appearance.Children.Add(ChoiceRow("Companion", new[] { "Puke", "Roof", "Rock" }, new PetMotion(kind: settings.TitlebarCompanion).Name, SetPetCompanion));
        LocalContent.Children.Add(Card(appearance));
        var window = new StackPanel();
        window.Children.Add(Label("General", 15, true));
        bool enabled = false;
        try { enabled = StartupRegistration.IsEnabled; } catch (Exception ex) { Log(ex); }
        startupToggle = AddCheck(window, "Launch at login", enabled, StartupRegistration.SetEnabled);
        AddCheck(window, "Keep running when closed", settings.CloseToTray, value => settings.CloseToTray = value);
        AddCheck(window, "Capture links", settings.CaptureLinks, value => settings.CaptureLinks = value);
        var windowCard = Card(window); windowCard.Margin = new Thickness(0, 14, 0, 0); LocalContent.Children.Add(windowCard);
        var notifications = new StackPanel { Tag = "notifications alerts quiet focus do not disturb snooze resume" };
        notifications.Children.Add(Label("Notifications", 15, true));
        AddCheck(notifications, "Quiet mode", settings.Quiet, value => { settings.Quiet = value; Refresh(); });
        var snooze = ActionButton("Snooze notifications…", () => { });
        snooze.HorizontalAlignment = HorizontalAlignment.Left;
        snooze.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = snooze, Placement = PlacementMode.Bottom };
            AddSnoozeChoices(menu, null); menu.IsOpen = true;
        };
        notifications.Children.Add(snooze);
        if (Productivity.Snoozed(settings.SnoozedUntil, DateTimeOffset.Now))
        {
            notifications.Children.Add(Muted("Snoozed until " + DateTimeOffset.FromUnixTimeSeconds(settings.SnoozedUntil!.Value).LocalDateTime.ToString("g"), 12));
            var resume = ActionButton("Resume now", () => Snooze(null, null)); resume.HorizontalAlignment = HorizontalAlignment.Left; notifications.Children.Add(resume);
        }
        var notificationCard = Card(notifications); notificationCard.Margin = new Thickness(0, 14, 0, 0); LocalContent.Children.Add(notificationCard);
        SettingsActions("Navigation", "workspaces bookmarks command palette search shortcuts",
            ActionButton("Command palette · Ctrl+K", ShowCommandPalette), ActionButton("Workspaces & bookmarks", ShowLibrary));
        BuildServiceSettings();
        SettingsActions("Settings backup", "export import backup restore transfer setup",
            ActionButton("Export settings…", ExportSetup), ActionButton("Import settings…", ImportSetup));
        SettingsActions("Support", "help report problem bug", ActionButton("Report a problem…", () => ShowBugReport()));
        BuildUpdateSettings();
        InstallSettingsSearch();
    }
    private void SettingsActions(string title, string keywords, params Button[] buttons)
    {
        var section = new StackPanel { Tag = keywords };
        section.Children.Add(Label(title, 15, true));
        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var button in buttons) actions.Children.Add(button);
        section.Children.Add(actions);
        var card = Card(section); card.Margin = new Thickness(0, 14, 0, 0); LocalContent.Children.Add(card);
    }
    private StackPanel ChoiceRow(string label, string[] values, string selectedValue, Action<string> set, bool previews = false)
    {
        var group = new StackPanel { Margin = new Thickness(0, 16, 0, 0) };
        group.Children.Add(Muted(label, 11));
        var choices = new UniformGrid { Columns = values.Length, Margin = new Thickness(-3, 8, -3, 0) };
        foreach (var value in values)
        {
            var content = new StackPanel();
            if (previews)
            {
                var color = value == "Ocean" ? "#1B3046" : value == "Dune" ? "#8E7E66" : "#454D58";
                var preview = new Grid { Height = 23, Margin = new Thickness(0, 0, 0, 8) };
                preview.Children.Add(new Border { Background = ColorBrush(color), CornerRadius = new CornerRadius(4), Opacity = 0.5 });
                preview.Children.Add(new Border { Background = ColorBrush(color), CornerRadius = new CornerRadius(4), Width = 14, HorizontalAlignment = HorizontalAlignment.Left });
                preview.Children.Add(new Border { Background = ColorBrush(AccentColor(settings.AccentName, darkTheme)), CornerRadius = new CornerRadius(2), Width = 20, Height = 3, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(22, 0, 0, 0) });
                content.Children.Add(preview);
            }
            var name = Label(value, 12, value == selectedValue); name.HorizontalAlignment = HorizontalAlignment.Center; content.Children.Add(name);
            var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(12, 9, 12, 9), Margin = new Thickness(3, 0, 3, 0) };
            button.SetResourceReference(Button.BackgroundProperty, value == selectedValue ? "AccentSoft" : "Card");
            button.SetResourceReference(Button.BorderBrushProperty, value == selectedValue ? "Accent" : "Line");
            button.Click += (_, _) => { set(value); ApplyTheme(); settings.Save(); RebuildSettings(); };
            choices.Children.Add(button);
        }
        group.Children.Add(choices); return group;
    }
    private CheckBox AddCheck(Panel panel, string text, bool value, Action<bool> changed)
    {
        var content = new StackPanel(); content.Children.Add(Label(text, 12));
        var check = new CheckBox { Content = content, IsChecked = value };
        System.Windows.Automation.AutomationProperties.SetName(check, text);
        check.Click += (_, _) =>
        {
            try { changed(check.IsChecked == true); settings.Save(); }
            catch (Exception ex)
            {
                check.IsChecked = !check.IsChecked;
                if (App.SmokeTest) throw;
                MessageBox.Show(this, ex.Message, "Couldn't update this setting", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        };
        panel.Children.Add(check); return check;
    }
}
