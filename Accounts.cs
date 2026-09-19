using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private IEnumerable<ServiceDefinition> AccountDefinitions()
    {
        var providers = Settings.Definitions();
        var seen = providers.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var provider in providers)
        {
            if (settings.Services.TryGetValue(provider.Id, out var options) && !string.IsNullOrWhiteSpace(options.AccountName) && options.AccountName.Length <= 32)
            {
                provider.AccountLabel = options.AccountName;
                provider.Name += " · " + options.AccountName;
            }
            yield return provider;
        }
        foreach (var account in settings.Accounts)
        {
            if (account == null || string.IsNullOrWhiteSpace(account.Id) || string.IsNullOrWhiteSpace(account.Label) || account.Label.Length > 32) continue;
            var provider = providers.Find(p => p.Id == account.ProviderId);
            if (provider == null || !Regex.IsMatch(account.Id, "^[a-z0-9][a-z0-9_-]{0,63}$") || !seen.Add(account.Id)) continue;
            yield return AccountService(provider, account);
        }
    }

    private static ServiceDefinition AccountService(ServiceDefinition provider, AccountDefinition account) => new()
    {
        Id = account.Id, ProviderId = provider.IconId, AccountLabel = account.Label,
        Name = Settings.Definitions().Single(p => p.Id == provider.IconId).Name + " · " + account.Label, Url = provider.Url,
        Hosts = provider.Hosts, Color = provider.Color, Glyph = provider.Glyph
    };

    private ServiceState AddAccount(ServiceDefinition provider, string label)
    {
        label = label.Trim();
        if (label.Length is < 1 or > 32) throw new InvalidOperationException("Account name: 1–32 characters.");
        if (services.Any(s => s.Definition.IconId == provider.IconId && s.Definition.AccountLabel.Equals(label, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("That account name is taken.");
        var account = new AccountDefinition { Id = provider.IconId + "_" + Guid.NewGuid().ToString("N"), ProviderId = provider.IconId, Label = label };
        var options = new ServiceOptions { KeepLive = provider.IconId is not ("calendar" or "googlekeep") };
        settings.Accounts.Add(account); settings.Services[account.Id] = options; settings.ServiceOrder.Add(account.Id);
        try { settings.Save(); }
        catch { settings.Accounts.Remove(account); settings.Services.Remove(account.Id); settings.ServiceOrder.Remove(account.Id); throw; }
        var state = new ServiceState { Definition = AccountService(provider, account), Options = options };
        services.Add(state); RebuildShortcuts(); return state;
    }

    private void RenameAccount(ServiceState state, string label)
    {
        label = label.Trim();
        if (label.Length > 32 || (label.Length == 0 && state.Definition.Id != state.Definition.IconId)) throw new InvalidOperationException("Account name: 1–32 characters.");
        if (label.Length > 0 && services.Any(s => s != state && s.Definition.IconId == state.Definition.IconId && s.Definition.AccountLabel.Equals(label, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("That account name is taken.");
        var account = settings.Accounts.SingleOrDefault(a => a.Id == state.Definition.Id);
        string previous = account?.Label ?? state.Options.AccountName;
        if (account != null) account.Label = label; else state.Options.AccountName = label;
        try { settings.Save(); }
        catch { if (account != null) account.Label = previous; else state.Options.AccountName = previous; throw; }
        state.Definition.AccountLabel = label;
        state.Definition.Name = Settings.Definitions().Single(p => p.Id == state.Definition.IconId).Name + (label.Length > 0 ? " · " + label : "");
        RebuildShortcuts();
    }

    private void RemoveAccount(ServiceState state)
    {
        var account = settings.Accounts.Single(a => a.Id == state.Definition.Id);
        var oldOrder = settings.ServiceOrder.ToList();
        settings.Accounts.Remove(account); settings.ServiceOrder.Remove(account.Id); settings.Services.Remove(account.Id);
        try { settings.Save(); }
        catch { settings.Accounts.Add(account); settings.ServiceOrder = oldOrder; settings.Services[account.Id] = state.Options; throw; }
        DisconnectService(state);
        if (selected == state) ShowActivity();
        activity.RemoveAll(item => item.Service == state);
        services.Remove(state); RebuildShortcuts();
    }

    private void ShowAccountEditor(ServiceState? existing = null, ServiceDefinition? initial = null)
    {
        ShowLocal("accounts", existing == null ? "Add account" : "Rename account", "");
        LocalContent.Children.Clear();
        var providers = Settings.Definitions();
        var chosen = providers.Find(p => p.Id == (existing?.Definition.IconId ?? initial?.IconId)) ?? providers[0];
        var form = new StackPanel { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };
        if (existing == null)
        {
            var choices = new WrapPanel { Margin = new Thickness(0, 0, 0, 18) };
            foreach (var provider in providers)
            {
                var choice = new Button { Content = provider.Name, Tag = provider, Margin = new Thickness(0, 0, 6, 6) };
                void Paint() { foreach (Button item in choices.Children) item.SetResourceReference(Button.BackgroundProperty, ReferenceEquals(item.Tag, chosen) ? "AccentSoft" : "Card"); }
                choice.Click += (_, _) => { chosen = provider; Paint(); };
                choices.Children.Add(choice); Paint();
            }
            form.Children.Add(choices);
        }
        else form.Children.Add(Label(chosen.Name, 16, true));
        var name = new TextBox { Text = existing?.Definition.AccountLabel ?? "", MaxLength = 32, Width = 320, Padding = new Thickness(10), Margin = new Thickness(0, 8, 0, 10), FontSize = 13 };
        name.SetResourceReference(Control.BackgroundProperty, "Card"); name.SetResourceReference(Control.ForegroundProperty, "Ink"); name.SetResourceReference(Control.BorderBrushProperty, "Line");
        System.Windows.Automation.AutomationProperties.SetName(name, "Account name");
        form.Children.Add(Label("Account name", 11)); form.Children.Add(name);
        var error = Muted("", 11); form.Children.Add(error);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        var save = new Button { Content = existing == null ? "Add account" : "Save", Margin = new Thickness(0, 0, 8, 0) };
        save.SetResourceReference(Button.BackgroundProperty, "AccentSoft");
        save.Click += async (_, _) =>
        {
            try
            {
                if (existing == null) { var added = AddAccount(chosen, name.Text); await SelectService(added); }
                else { RenameAccount(existing, name.Text); ShowSettings(); }
            }
            catch (Exception ex) { error.Text = ex.Message; }
        };
        var cancel = new Button { Content = "Cancel" }; cancel.Click += (_, _) => ShowSettings();
        actions.Children.Add(save); actions.Children.Add(cancel); form.Children.Add(actions);
        LocalContent.Children.Add(form); name.Focus();
    }

    private IEnumerable<WebView2> AccountViews(ServiceState state)
    {
        if (state.View != null) yield return state.View;
        foreach (var popup in popups)
            if (popup.Tag == state && popup.Content is Border { Child: Grid layout })
                foreach (var view in layout.Children.OfType<WebView2>()) yield return view;
    }

    private void SetAudioMuted(ServiceState state, bool muted)
    {
        bool previous = state.Options.AudioMuted; state.Options.AudioMuted = muted;
        try { settings.Save(); } catch { state.Options.AudioMuted = previous; throw; }
        foreach (var view in AccountViews(state))
        {
            try { if (view.CoreWebView2 is { } core) core.IsMuted = muted; }
            catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
        }
        Refresh();
        if (localPage == "settings") RebuildSettings();
    }
}
