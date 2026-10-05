using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private async Task ProductivitySmokeTest()
    {
        string output = Path.Combine(Environment.CurrentDirectory, "artifacts"); Directory.CreateDirectory(output);
        string report = Path.Combine(output, "productivity-ui-checks.txt"); File.WriteAllText(report, "RUNNING");
        try
        {
            foreach (var state in services.Take(2)) { await SelectService(state); await Until(() => state.Status == "Live" && state.Unread == 3); }
            CheckPetWardrobeAndGrooming();
            await CheckProductivity(output);
            Check(!File.Exists(Path.Combine(App.DataPath, "errors.log")), "No runtime errors during productivity checks");
            File.WriteAllText(report, "PASS: productivity models and native browsers; bookmark manager creation/account selection/edit/deduplication/search/delete; palette visibility/persistence/native activation/dismissal; layout picker text; Outfit label; dark/light native screenshots.");
        }
        catch (Exception ex) { File.WriteAllText(report, "FAIL: " + ex); Environment.ExitCode = 1; }
        finally { quitting = true; Close(); }
    }
    private static IEnumerable<T> PlaceElements<T>(DependencyObject parent) where T : DependencyObject
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            if (child is T item) yield return item;
            foreach (var nested in PlaceElements<T>(child)) yield return nested;
        }
    }
    private async Task CheckProductivityUi(string output)
    {
        Button ButtonNamed(string name) => PlaceElements<Button>(LocalContent).Single(b => Equals(b.Content, name));
        TextBox Input(string name) => PlaceElements<TextBox>(LocalContent).Single(t => AutomationProperties.GetName(t) == name);
        void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var accounts = services.Take(2).ToArray();
        var views = accounts.Select(s => s.View).ToArray();
        ShowLibrary(); UpdateLayout(); Capture(Path.Combine(output, "saved-places-empty.png"));
        Click(ButtonNamed("Add bookmark…"));
        Check(localPage == "bookmark-editor", "Empty library opens its own bookmark editor");
        var selector = PlaceElements<Button>(LocalContent).Single(b => Equals(b.Tag, "bookmark-account")); Click(selector);
        var option = selector.ContextMenu.Items.OfType<MenuItem>().Single(i => Equals(i.Tag, accounts[1].Definition.Id));
        option.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); selector.ContextMenu.IsOpen = false;
        Input("Bookmark name").Text = "Morning inbox"; Input("HTTPS address").Text = accounts[1].Definition.Url;
        Capture(Path.Combine(output, "bookmark-editor.png")); Click(ButtonNamed("Save"));
        var saved = settings.Bookmarks.Single(b => b.Name == "Morning inbox"); string savedId = saved.Id;
        Check(saved.AccountId == accounts[1].Definition.Id && Settings.Load().Bookmarks.Any(b => b.Id == savedId), "Library-created bookmark persists for the selected account");
        Check(accounts.Select(s => s.View).SequenceEqual(views), "Managing bookmarks retains account profiles");
        Input("Search workspaces, bookmarks, or accounts").Text = "nothing-matches-this-query";
        Check(!PlaceElements<Border>(LocalContent).Any(b => Equals(b.Tag, savedId)), "Library search removes unmatched rows");
        Input("Search workspaces, bookmarks, or accounts").Text = accounts[1].Definition.Name;
        Check(PlaceElements<Border>(LocalContent).Any(b => Equals(b.Tag, savedId)), "Bookmark search matches account identity");
        placesQuery = ""; ShowLibrary(); Click(ButtonNamed("Edit"));
        Input("Bookmark name").Text = "Renamed inbox"; Click(ButtonNamed("Save"));
        Check(saved.Id == savedId && saved.Name == "Renamed inbox", "Editing a bookmark retains its identity");
        ShowBookmarkEditor(accounts[1]); Input("Bookmark name").Text = "Work inbox"; Input("HTTPS address").Text = saved.Url; Click(ButtonNamed("Save"));
        Check(settings.Bookmarks.Count(b => b.AccountId == accounts[1].Definition.Id && b.Url == saved.Url) == 1 && saved.Name == "Work inbox", "Adding a duplicate account address updates its existing bookmark");
        ShowBookmarkEditor(accounts[0]); Input("Bookmark name").Text = "Personal messages"; Input("HTTPS address").Text = accounts[0].Definition.Url; Click(ButtonNamed("Save"));
        var personal = settings.Bookmarks.Single(b => b.Name == "Personal messages");
        ShowWorkspaceEditor(); Input("Workspace name").Text = "Daily catch-up"; Click(ButtonNamed("Save"));
        var workspace = settings.SavedWorkspaces.Single(w => w.Name == "Daily catch-up");
        foreach (var mode in new[] { "Dark", "Light" })
        {
            settings.Appearance = mode; ApplyTheme(); ShowLibrary(); Width = 1000; Height = 800; LocalPage.ScrollToTop();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "saved-places-" + mode.ToLowerInvariant() + ".png"));
            Width = 720; await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Capture(Path.Combine(output, "saved-places-narrow-" + mode.ToLowerInvariant() + ".png"));
        }
        var row = PlaceElements<Border>(LocalContent).Single(b => Equals(b.Tag, savedId));
        var delete = PlaceElements<Button>(row).Single(b => Equals(b.Content, "Delete")); Click(delete); Click(delete);
        Check(!Settings.Load().Bookmarks.Any(b => b.Id == savedId) && settings.Bookmarks.Contains(personal), "Repeated deletion clears only the selected account bookmark");
        settings.Bookmarks.Remove(personal); settings.SavedWorkspaces.Remove(workspace); settings.Save();
        Width = 1180; settings.Appearance = "Dark"; ApplyTheme();

        SetPaletteButtonHidden(true);
        Check(PaletteButton.Visibility == Visibility.Collapsed && Settings.Load().HidePaletteButton, "Hiding the palette launcher persists");
        foreach (bool top in new[] { true, false })
        { SetTopTabs(top); ApplySidebarSize(); Check(PaletteButton.Visibility == Visibility.Collapsed, "Rail layout changes preserve hidden palette launcher"); }
        ShowCommandPalette(); Check(commandPalette != null, "Palette commands remain available with a hidden launcher"); commandPalette!.Close();
        RefreshSidebarContextMenu();
        SidebarFrame.ContextMenu.Items.OfType<MenuItem>().Single(m => Equals(m.Header, "Show command palette button")).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Check(PaletteButton.Visibility == Visibility.Visible && !Settings.Load().HidePaletteButton, "Rail context menu restores the palette launcher");
        OpenWorkspacePicker(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        var picker = (FrameworkElement)workspacePicker!.Child;
        foreach (var button in PlaceElements<Button>(picker).Where(b => b.Content is string text && text.Contains("workspace")))
            Check(button.FontFamily.Source == FontFamily.Source, "Workspace labels use the application text font");
        CaptureElement(picker, Path.Combine(output, "layout-picker-readable.png")); CloseWorkspacePicker();

        await SelectService(accounts[0]); Activate();
        for (int index = 0; index < 3; index++)
        {
            Click(PaletteButton); var palette = commandPalette!; palette.Activate();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(palette.IsActive, "Palette receives native activation");
            Activate();
            // Deliver both native button messages in the activation turn, as a launcher click does.
            var point = PaletteButton.TranslatePoint(new Point(PaletteButton.ActualWidth / 2, PaletteButton.ActualHeight / 2), this);
            var packed = new IntPtr(((int)point.Y << 16) | ((int)point.X & 0xffff)); var handle = new WindowInteropHelper(this).Handle;
            SendMessage(handle, 0x0201, new IntPtr(1), packed); SendMessage(handle, 0x0202, IntPtr.Zero, packed);
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(commandPalette == null && IsActive && IsVisible, "Clicking the launcher again dismisses the palette and keeps Relay active");
        }
        ShowCommandPalette(); commandPalette!.Activate();
        var other = new Window { Title = "Activation fixture", Width = 180, Height = 90, ShowInTaskbar = false };
        try
        {
            other.Show(); other.Activate(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(commandPalette == null && other.IsActive, "Switching to another window dismisses the palette without taking focus back");
        }
        finally { other.Close(); Activate(); }
        SetPetEnabled(true); CaptionPet.PetButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        foreach (int outfit in new[] { 0, 1, 2, 3 })
        {
            CaptionPet.ChooseOutfit(outfit);
            Check(PlaceElements<TextBlock>(CaptionPet.Actions["dress"]).Any(t => t.Text == "Outfit") && CaptionPet.Actions["dress"].ToolTip.ToString()!.Contains(CaptionPet.Motion.OutfitName), "Outfit category label stays stable while its tooltip identifies the selection");
        }
        CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "outfit-control.png")); CaptionPet.Playground.IsOpen = false;
    }
}
