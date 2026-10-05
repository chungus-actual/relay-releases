using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using Microsoft.Win32;

namespace Relay;

public partial class MainWindow
{
    private PortableSetup CreateSetup() => new()
    {
        Mode = settings.Appearance, Surface = settings.Palette, Accent = settings.AccentName,
        Compact = settings.CompactSidebar, TopTabs = settings.TopTabs, CompanionEnabled = settings.TitlebarPetEnabled,
        HidePaletteButton = settings.HidePaletteButton,
        Companion = settings.TitlebarCompanion, CaptureLinks = settings.CaptureLinks, Quiet = settings.Quiet,
        Accounts = OrderedServices().Where(s => !s.Definition.IsTerminal).Select(s => new PortableAccount { Id = s.Definition.Id, Provider = s.Definition.IconId,
            Name = s.Definition.AccountLabel.Length > 0 ? s.Definition.AccountLabel : Settings.Definitions().Single(p => p.Id == s.Definition.IconId).Name,
            Color = s.Options.IdentityColor, Visible = s.Options.ShowShortcut, KeepLive = s.Options.KeepLive,
            Notifications = s.Options.Notifications, AudioMuted = s.Options.AudioMuted, GmailAllUnread = s.Options.GmailAllUnread, Zoom = s.Options.Zoom }).ToList(),
        Workspaces = settings.SavedWorkspaces.Where(w => w.Layout.Panes.All(id => services.Any(s => s.Definition.Id == id && !s.Definition.IsTerminal))).ToList(),
        Bookmarks = settings.Bookmarks.Where(b => services.Any(s => s.Definition.Id == b.AccountId && !s.Definition.IsTerminal)).ToList()
    };
    private void ExportSetup()
    {
        var dialog = new SaveFileDialog { Title = "Export Relay settings", FileName = "Relay-setup.json", Filter = "Relay setup (*.json)|*.json" };
        if (dialog.ShowDialog(this) == true) File.WriteAllText(dialog.FileName, CreateSetup().Encode());
    }
    private void ImportSetup()
    {
        var dialog = new OpenFileDialog { Title = "Import Relay settings", Filter = "Relay setup (*.json)|*.json" };
        if (dialog.ShowDialog(this) != true) return;
        if (new FileInfo(dialog.FileName).Length > 2_000_000) throw new InvalidOperationException("This setup file is too large.");
        var setup = PortableSetup.Decode(File.ReadAllText(dialog.FileName), Settings.Definitions());
        var next = MergeSetup(settings, setup);
        if (MessageBox.Show(this, $"Merge {setup.Accounts.Count} accounts, {setup.Workspaces.Count} workspaces and {setup.Bookmarks.Count} bookmarks?\n\nAppearance and matching account preferences will be updated. Existing accounts and sign-ins stay in place. New accounts start unloaded.",
            "Import Relay settings", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return;
        ApplyImportedSettings(next);
    }
    private void ApplyImportedSettings(Settings next)
    {
        next.Save(); settings = next;
        foreach (var definition in AccountDefinitions())
        {
            var state = services.Find(s => s.Definition.Id == definition.Id);
            if (state == null) services.Add(new() { Definition = definition, Options = settings.Services[definition.Id] });
            else
            {
                bool gmailChanged = state.Options.GmailAllUnread != settings.Services[definition.Id].GmailAllUnread;
                state.Options = settings.Services[definition.Id];
                state.Definition.Name = definition.Name; state.Definition.AccountLabel = definition.AccountLabel;
                if (gmailChanged) SetGmailUnreadMode(state, state.Options.GmailAllUnread, force: true);
                foreach (var view in AccountViews(state)) { view.ZoomFactor = state.Options.Zoom; if (view.CoreWebView2 is { } core) core.IsMuted = state.Options.AudioMuted; }
                if (state.Suspended && state.Options.KeepLive) { state.Core?.Resume(); state.Suspended = false; }
            }
        }
        ApplyTheme(); RebuildShortcuts(); ApplySidebarSize(); ShowSettings();
    }
    internal static Settings MergeSetup(Settings current, PortableSetup setup)
    {
        var next = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(current))!;
        var providers = Settings.Definitions(); var mapping = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var a in setup.Accounts)
        {
            var sameID = a.Id == a.Provider ? providers.Any(p => p.Id == a.Id) : next.Accounts.Any(c => c.Id == a.Id && c.ProviderId == a.Provider);
            string? id = next.Accounts.Find(c => c.ProviderId == a.Provider && c.Label.Equals(a.Name, StringComparison.OrdinalIgnoreCase))?.Id;
            var provider = providers.Single(p => p.Id == a.Provider);
            if (id == null && a.Name.Equals(next.Services.GetValueOrDefault(a.Provider)?.AccountName is { Length: > 0 } label ? label : provider.Name, StringComparison.OrdinalIgnoreCase)) id = a.Provider;
            if (id == null && sameID && !mapping.ContainsValue(a.Id)) id = a.Id;
            if (id == null)
            {
                id = a.Provider + "_" + Guid.NewGuid().ToString("N");
                next.Accounts.Add(new() { Id = id, ProviderId = a.Provider, Label = a.Name }); next.ServiceOrder.Add(id);
            }
            mapping[a.Id] = id;
            if (mapping.Values.Count(value => value == id) > 1) throw new InvalidOperationException("Two imported accounts refer to the same local account.");
            if (!next.Services.TryGetValue(id, out var options)) next.Services[id] = options = new();
            if (id == a.Provider) options.AccountName = a.Name == provider.Name ? "" : a.Name;
            else next.Accounts.Single(c => c.Id == id).Label = a.Name;
            options.IdentityColor = a.Color; options.ShowShortcut = a.Visible; options.KeepLive = a.KeepLive;
            options.Notifications = a.Notifications; options.AudioMuted = a.AudioMuted; options.GmailAllUnread = a.GmailAllUnread; options.Zoom = a.Zoom;
        }
        next.ServiceOrder = mapping.Values.Concat(next.ServiceOrder).Distinct(StringComparer.Ordinal).ToList();
        foreach (var w in setup.Workspaces)
        {
            var layout = Productivity.Copy(w.Layout); layout.Panes = layout.Panes.Select(id => mapping[id]).ToList(); layout.Normalize(next.Services.Keys);
            next.SavedWorkspaces.RemoveAll(item => item.Id == w.Id);
            next.SavedWorkspaces.Add(new() { Id = w.Id, Name = w.Name, Layout = layout, Focused = w.Focused != null ? mapping.GetValueOrDefault(w.Focused) : null });
        }
        foreach (var b in setup.Bookmarks)
        {
            string id = mapping[b.AccountId]; next.Bookmarks.RemoveAll(item => item.Id == b.Id || item.AccountId == id && item.Url == b.Url);
            next.Bookmarks.Add(new() { Id = b.Id, AccountId = id, Name = b.Name, Url = b.Url });
        }
        if (next.Accounts.Count + providers.Count > 128 || next.SavedWorkspaces.Count > 32 || next.Bookmarks.Count > 200) throw new InvalidOperationException("The merged setup exceeds Relay's saved-item limits.");
        next.Appearance = setup.Mode; next.Palette = setup.Surface; next.AccentName = setup.Accent; next.CompactSidebar = setup.Compact;
        next.TopTabs = setup.TopTabs; next.TitlebarPetEnabled = setup.CompanionEnabled; next.TitlebarCompanion = setup.Companion;
        if (setup.HidePaletteButton is bool hidePalette) next.HidePaletteButton = hidePalette;
        next.CaptureLinks = setup.CaptureLinks; next.Quiet = setup.Quiet; return next;
    }
}
