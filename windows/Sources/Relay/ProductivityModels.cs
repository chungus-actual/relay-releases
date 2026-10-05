using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Relay;

public sealed class SavedWorkspace
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    public WorkspaceLayout Layout { get; set; } = new();
    public string? Focused { get; set; }
}

public sealed class AccountBookmark
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string AccountId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
}

public static class Productivity
{
    public static readonly string[] Colors = ["", "Mint", "Sky", "Iris", "Rose", "Amber"];
    public static bool Snoozed(long? until, DateTimeOffset now) => until > now.ToUnixTimeSeconds();
    public static bool Matches(string query, params string[] values) => query.Split(' ', StringSplitOptions.RemoveEmptyEntries)
        .All(word => values.Any(value => value.Contains(word, StringComparison.OrdinalIgnoreCase)));
    public static bool PaletteMatches(string query, params string[] values) => query.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(word => values.Any(value =>
    {
        int index = 0; foreach (char c in value) if (index < word.Length && char.ToUpperInvariant(c) == char.ToUpperInvariant(word[index])) index++;
        return index == word.Length;
    }));
    public static string Name(string value)
    {
        value = value.Trim();
        if (value.Length is < 1 or > 80 || value.Any(char.IsControl)) throw new InvalidOperationException("Use a name between 1 and 80 characters.");
        return value;
    }
    public static bool BookmarkAllowed(string value, ServiceDefinition service) => value.Length <= 4096 &&
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.UserInfo.Length == 0 && service.Owns(value);
    public static WorkspaceLayout Copy(WorkspaceLayout layout) => new() { Panes = [.. layout.Panes], Arrangement = layout.Arrangement, Primary = layout.Primary, Cuts = [.. layout.Cuts] };
}

// A versioned, platform-independent setup. Authentication, downloads and machine paths are never exported.
public sealed class PortableSetup
{
    public int Version { get; set; } = 1;
    public string Mode { get; set; } = "Dark";
    public string Surface { get; set; } = "Graphite";
    public string Accent { get; set; } = "Mint";
    public bool Compact { get; set; }
    public bool TopTabs { get; set; }
    public bool? HidePaletteButton { get; set; }
    public bool CompanionEnabled { get; set; }
    public string Companion { get; set; } = "puke";
    public bool CaptureLinks { get; set; }
    public bool Quiet { get; set; }
    public List<PortableAccount> Accounts { get; set; } = [];
    public List<SavedWorkspace> Workspaces { get; set; } = [];
    public List<AccountBookmark> Bookmarks { get; set; } = [];
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public string Encode() => JsonSerializer.Serialize(this, Json);
    public static PortableSetup Decode(string text, List<ServiceDefinition> services)
    {
        if (text.Length > 2_000_000) throw new InvalidOperationException("This setup file is too large.");
        using var document = JsonDocument.Parse(text);
        foreach (string required in new[] { "version", "mode", "surface", "accent", "compact", "topTabs", "companionEnabled", "companion", "captureLinks", "quiet", "accounts", "workspaces", "bookmarks" })
            if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty(required, out _)) throw new InvalidOperationException("Incomplete Relay setup.");
        static void Require(JsonElement element, params string[] keys)
        {
            if (element.ValueKind != JsonValueKind.Object || keys.Any(key => !element.TryGetProperty(key, out _))) throw new InvalidOperationException("Incomplete Relay setup entry.");
        }
        foreach (var account in document.RootElement.GetProperty("accounts").EnumerateArray()) Require(account, "id", "provider", "name", "color", "visible", "keepLive", "notifications", "audioMuted", "gmailAllUnread", "zoom");
        foreach (var workspace in document.RootElement.GetProperty("workspaces").EnumerateArray()) { Require(workspace, "id", "name", "layout"); Require(workspace.GetProperty("layout"), "panes", "arrangement", "primary", "cuts"); }
        foreach (var bookmark in document.RootElement.GetProperty("bookmarks").EnumerateArray()) Require(bookmark, "id", "accountId", "name", "url");
        var value = JsonSerializer.Deserialize<PortableSetup>(text, Json) ?? throw new InvalidOperationException("Empty setup file.");
        if (value.Version != 1 || value.Accounts == null || value.Workspaces == null || value.Bookmarks == null ||
            value.Accounts.Count > 128 || value.Workspaces.Count > 32 || value.Bookmarks.Count > 200)
            throw new InvalidOperationException("Unsupported or invalid Relay setup.");
        if (!new[] { "System", "Dark", "Light" }.Contains(value.Mode) || !new[] { "Graphite", "Ocean", "Dune" }.Contains(value.Surface) ||
            !Productivity.Colors.Skip(1).Contains(value.Accent) || !new[] { "puke", "roof", "rock" }.Contains(value.Companion))
            throw new InvalidOperationException("Invalid appearance settings.");
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var a in value.Accounts)
        {
            if (a == null || string.IsNullOrWhiteSpace(a.Id) || a.Id.Length > 80 || !keys.Add(a.Id) || a.Name == null ||
                services.All(s => s.Id != a.Provider) || !Productivity.Colors.Contains(a.Color) || !double.IsFinite(a.Zoom) || a.Zoom < .5 || a.Zoom > 2)
                throw new InvalidOperationException("Invalid account in setup.");
            a.Name = Productivity.Name(a.Name);
        }
        if (value.Accounts.GroupBy(a => a.Provider + "\n" + a.Name, StringComparer.OrdinalIgnoreCase).Any(g => g.Count() > 1))
            throw new InvalidOperationException("Duplicate account names in setup.");
        keys.Clear();
        foreach (var w in value.Workspaces)
        {
            if (w == null || string.IsNullOrEmpty(w.Id) || !keys.Add(w.Id) || w.Name == null || w.Layout?.Panes == null || w.Layout.Cuts == null ||
                w.Layout.Panes.Count is < 1 or > 4 || w.Layout.Panes.Any(id => value.Accounts.All(a => a.Id != id)))
                throw new InvalidOperationException("Invalid workspace in setup.");
            w.Name = Productivity.Name(w.Name); w.Layout.Normalize(value.Accounts.Select(a => a.Id));
            if (!w.Layout.Panes.Contains(w.Focused ?? "")) w.Focused = w.Layout.Panes.FirstOrDefault();
        }
        keys.Clear();
        foreach (var b in value.Bookmarks)
        {
            if (b == null || string.IsNullOrEmpty(b.Id) || !keys.Add(b.Id) || b.Name == null || b.Url == null ||
                value.Accounts.Find(a => a.Id == b.AccountId) is not { } a || !Productivity.BookmarkAllowed(b.Url, services.Single(s => s.Id == a.Provider)))
                throw new InvalidOperationException("A bookmark does not belong to its account's service.");
            b.Name = Productivity.Name(b.Name);
        }
        return value;
    }
}

public sealed class PortableAccount
{
    public string Id { get; set; } = "";
    public string Provider { get; set; } = "";
    public string Name { get; set; } = "";
    public string Color { get; set; } = "";
    public bool Visible { get; set; } = true;
    public bool KeepLive { get; set; } = true;
    public bool Notifications { get; set; } = true;
    public bool AudioMuted { get; set; }
    public bool GmailAllUnread { get; set; }
    public double Zoom { get; set; } = 1;
}
