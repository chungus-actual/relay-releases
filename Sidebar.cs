using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace Relay;

public partial class MainWindow
{
    private void ApplySidebarSize()
    {
        bool compact = settings.CompactSidebar, top = settings.TopTabs;
        SidebarColumn.Width = new GridLength(top ? 0 : compact ? 36 : 64);
        TopRailRow.Height = new GridLength(top ? compact ? 40 : 50 : 0);
        Grid.SetRowSpan(SidebarFrame, top ? 1 : 2);
        Grid.SetColumnSpan(SidebarFrame, top ? 3 : 1);
        SidebarFrame.BorderThickness = top ? new Thickness(0, 0, 0, 1) : new Thickness(0, 0, 1, 0);
        SidebarContent.Margin = top ? new Thickness(8, 2, 8, 2) : compact ? new Thickness(2, 8, 2, 8) : new Thickness(7, 12, 7, 12);
        SidebarDivider.Margin = top ? new Thickness(8, 6, 8, 6) : compact ? new Thickness(6, 8, 6, 8) : new Thickness(10, 12, 10, 12);
        SidebarDivider.Width = top ? 1 : double.NaN;
        SidebarDivider.Height = top ? 20 : 1;
        DockPanel.SetDock(SidebarUtilities, top ? Dock.Right : Dock.Bottom);
        DockPanel.SetDock(SidebarHeading, top ? Dock.Left : Dock.Top);
        SidebarUtilities.Orientation = SidebarUtilityItems.Orientation = SidebarHeading.Orientation = ServiceRail.Orientation = top ? Orientation.Horizontal : Orientation.Vertical;
        SidebarUtilities.VerticalAlignment = top ? VerticalAlignment.Center : VerticalAlignment.Bottom;
        SidebarHeading.VerticalAlignment = top ? VerticalAlignment.Center : VerticalAlignment.Stretch;
        ServiceRail.VerticalAlignment = top ? VerticalAlignment.Center : VerticalAlignment.Stretch;
        ServiceRailScroll.HorizontalScrollBarVisibility = top ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Disabled;
        ServiceRailScroll.VerticalScrollBarVisibility = top ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Hidden;
        foreach (var button in new FrameworkElement[] { ActivityButton, QuietButton, SettingsButton, SidebarToggle, UsageHover, DownloadsButton, UpdateButton }) button.Width = compact ? 30 : 46;
        ActivityButton.Height = compact ? 32 : 42;
        QuietButton.Height = DownloadsButton.Height = SettingsButton.Height = compact ? 32 : 38;
        SidebarToggle.Content = compact ? "\uE76C" : "\uE76B";
        SidebarToggle.ToolTip = top ? compact ? "Roomier tabs" : "Compact tabs" : compact ? "Expand sidebar" : "Compact sidebar";
        System.Windows.Automation.AutomationProperties.SetName(SidebarToggle, (string)SidebarToggle.ToolTip);

    }

    private void SetTopTabs(bool top)
    {
        FinishShortcutDrag(false);
        settings.TopTabs = top;
        BuildRail();
    }

    private void SidebarToggleClick(object sender, RoutedEventArgs e)
    {
        bool previous = settings.CompactSidebar;
        settings.CompactSidebar = !previous;
        try { settings.Save(); }
        catch (Exception ex)
        {
            settings.CompactSidebar = previous;
            MessageBox.Show(this, ex.Message, "Couldn't save sidebar size", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        BuildRail();
    }

    private async Task ToggleServiceConnection(ServiceState state)
    {
        if (state.Options.Enabled)
        {
            DisconnectService(state);
            settings.Save();
            if (selected == state) ShowActivity();
            else Refresh();
        }
        else await SelectService(state);
        if (localPage == "settings") RebuildSettings();
    }
}
