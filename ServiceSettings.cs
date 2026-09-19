using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private StackPanel serviceSettingsList = null!;

    private void BuildServiceSettings()
    {
        var heading = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var add = new Button { Content = "+  Add account", MinWidth = 148, Height = 40, FontWeight = FontWeights.SemiBold };
        add.Style = (Style)FindResource("PrimaryButton");
        var addText = new TextBlock { Text = "+  Add account" };
        addText.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Button.Foreground)) { Source = add });
        add.Content = addText;
        add.Click += (_, _) => ShowAccountEditor();
        DockPanel.SetDock(add, Dock.Right); heading.Children.Add(add);
        var title = Label("Your services", 16, true); title.VerticalAlignment = VerticalAlignment.Center;
        heading.Children.Add(title); LocalContent.Children.Add(heading);
        serviceSettingsList = new StackPanel();
        foreach (var state in OrderedServices()) serviceSettingsList.Children.Add(ServiceSettingsRow(state));
        LocalContent.Children.Add(serviceSettingsList);
    }

    private Border ServiceSettingsRow(ServiceState state)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = ServiceIcon(state, 25, "Ink"); icon.Margin = new Thickness(0, 0, 14, 0); icon.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(icon);
        var identity = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        var name = Label(state.Definition.Name, 13, true); name.TextWrapping = TextWrapping.Wrap; identity.Children.Add(name);
        if (state.Definition.IconId == "gmail")
        {
            var mode = new ComboBox { Width = 154, HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 6, 0, 0), ToolTip = "Gmail badge", FontSize = 11 };
            mode.Items.Add("New since launch"); mode.Items.Add("All unread");
            mode.SelectedIndex = state.Options.GmailAllUnread ? 1 : 0;
            System.Windows.Automation.AutomationProperties.SetName(mode, "Gmail badge");
            mode.SelectionChanged += async (_, _) => await ChangeServiceSetting(() =>
            {
                SetGmailUnreadMode(state, mode.SelectedIndex == 1);
                return Task.CompletedTask;
            });
            identity.Children.Add(mode);
        }
        Grid.SetColumn(identity, 1); row.Children.Add(identity);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var connection = new Button { Content = state.Options.Enabled ? "Loaded" : "Load", Width = 94, Height = 32,
            ToolTip = state.Options.Enabled ? "Unload" : "Load", Margin = new Thickness(0, 0, 12, 0), Padding = new Thickness(10, 0, 10, 0), FontSize = 11 };
        connection.SetResourceReference(Button.BackgroundProperty, state.Options.Enabled ? "AccentSoft" : "Hover");
        connection.SetResourceReference(Button.ForegroundProperty, state.Options.Enabled ? "Accent" : "Ink");
        var connectionText = new TextBlock { Text = state.Options.Enabled ? "Loaded" : "Load", FontSize = 11 };
        connectionText.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Button.Foreground)) { Source = connection });
        connection.Content = connectionText;
        connection.Click += async (_, _) => await ChangeServiceSetting(async () =>
        {
            connection.IsEnabled = false;
            try { await ToggleServiceConnection(state); } finally { connection.IsEnabled = true; }
        });
        actions.Children.Add(connection);
        actions.Children.Add(ServiceVisibilityButton(state));
        actions.Children.Add(ServiceSettingIcon(state, state.Options.AudioMuted ? "\uE74F" : "\uE767",
            state.Options.AudioMuted ? "Unmute audio" : "Mute audio", state.Options.AudioMuted, () => { SetAudioMuted(state, !state.Options.AudioMuted); return Task.CompletedTask; }));
        actions.Children.Add(ServiceSettingIcon(state, state.Options.Notifications ? "\uEA8F" : "\uE7ED",
            state.Options.Notifications ? "Mute alerts" : "Enable alerts", !state.Options.Notifications, () => { state.Options.Notifications = !state.Options.Notifications; return Task.CompletedTask; }));
        actions.Children.Add(ServiceSettingIcon(state, "\uE708",
            state.Options.KeepLive ? "Allow sleep" : "Keep awake", !state.Options.KeepLive, () =>
            {
                state.Options.KeepLive = !state.Options.KeepLive;
                if (state.Options.KeepLive && state.Suspended) { state.Core?.Resume(); state.Suspended = false; state.Status = "Live"; }
                return Task.CompletedTask;
            }));
        var rename = ServiceSettingIcon(state, "\uE70F", "Rename", false, null);
        rename.Click += (_, _) => ShowAccountEditor(state);
        actions.Children.Add(rename);
        if (state.Definition.Id != state.Definition.IconId)
        {
            actions.Children.Add(ServiceSettingIcon(state, "\uE74D", "Remove", false, () =>
            {
                if (MessageBox.Show(this, "Remove this account? Saved sign-in stays on this device.", "Remove account", MessageBoxButton.YesNo) == MessageBoxResult.Yes) RemoveAccount(state);
                return Task.CompletedTask;
            }));
        }
        else
        {
            var removeSlot = ServiceSettingIcon(state, "", "", false, null);
            removeSlot.Visibility = Visibility.Hidden;
            actions.Children.Add(removeSlot);
        }
        Grid.SetColumn(actions, 2); row.Children.Add(actions);
        var card = Card(row, new Thickness(16, 14, 12, 14)); card.Margin = new Thickness(0, 0, 8, 8); card.Tag = state;
        return card;
    }

    private Button ServiceVisibilityButton(ServiceState state)
    {
        bool hidden = !state.Options.ShowShortcut;
        var button = ServiceSettingIcon(state, "", hidden ? "Show shortcut" : "Hide shortcut", hidden,
            () => { SetShortcutVisible(state, hidden); return Task.CompletedTask; });
        var canvas = new Canvas { Width = 20, Height = 20 };
        var eye = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M2,10 C6,2 14,2 18,10 C14,18 6,18 2,10 Z M12.5,10 A2.5,2.5 0 1 1 7.5,10 A2.5,2.5 0 1 1 12.5,10" + (hidden ? " M3,3 L17,17" : "")),
            StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round
        };
        eye.SetBinding(System.Windows.Shapes.Shape.StrokeProperty, new System.Windows.Data.Binding(nameof(Button.Foreground)) { Source = button });
        canvas.Children.Add(eye);
        button.Content = new Viewbox { Width = 18, Height = 18, Child = canvas };
        return button;
    }

    private Button ServiceSettingIcon(ServiceState state, string glyph, string tip, bool active, Func<Task>? action)
    {
        var button = new Button { Style = (Style)FindResource("IconButton"), Content = glyph, ToolTip = tip, Margin = new Thickness(2, 0, 2, 0) };
        System.Windows.Automation.AutomationProperties.SetName(button, state.Definition.Name + ": " + tip);
        if (active) { button.SetResourceReference(Button.BackgroundProperty, "AccentSoft"); button.SetResourceReference(Button.ForegroundProperty, "Accent"); }
        if (action != null) button.Click += async (_, _) => await ChangeServiceSetting(action);
        return button;
    }

    private async Task ChangeServiceSetting(Func<Task> change)
    {
        try { await change(); settings.Save(); Refresh(); if (localPage == "settings") RebuildSettings(); }
        catch (Exception ex)
        {
            if (App.SmokeTest) throw;
            MessageBox.Show(this, ex.Message, "Couldn't update", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

}
