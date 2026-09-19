using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Web.WebView2.Wpf;
using Microsoft.Web.WebView2.Core;
using System.Runtime.InteropServices;

namespace Relay;

public sealed class ServiceDefinition
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string ProviderId { get; set; } = "";
    public string AccountLabel { get; set; } = "";
    public string IconId => string.IsNullOrEmpty(ProviderId) ? Id : ProviderId;
    public string Url { get; set; } = "";
    public string Color { get; set; } = "";
    public string Glyph { get; set; } = "";
    public string[] Hosts { get; set; } = [];
    public bool Owns(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && Array.Exists(Hosts, host => uri.Host.Equals(host, StringComparison.OrdinalIgnoreCase)
            || uri.Host.EndsWith("." + host, StringComparison.OrdinalIgnoreCase));
}

public sealed class ServiceOptions
{
    public string AccountName { get; set; } = "";
    public bool Enabled { get; set; } = false;
    public bool ShowShortcut { get; set; } = true;
    public bool KeepLive { get; set; } = true;
    public bool Notifications { get; set; } = true;
    public bool GmailAllUnread { get; set; }
    public bool AudioMuted { get; set; }
    public double Zoom { get; set; } = 1;
}

public sealed class AccountDefinition
{
    public string Id { get; set; } = "";
    public string ProviderId { get; set; } = "";
    public string Label { get; set; } = "";
}

public sealed class Settings
{
    public bool Dark { get; set; } = true; // Retained to migrate the original settings.
    public string Appearance { get; set; } = "";
    public string Palette { get; set; } = "Graphite";
    public string AccentName { get; set; } = "Mint";
    public bool CompactSidebar { get; set; }
    public bool TopTabs { get; set; }
    public bool Quiet { get; set; }
    public bool CloseToTray { get; set; } = true;
    public bool CaptureLinks { get; set; }
    public string Selected { get; set; } = "activity";
    public Dictionary<string, ServiceOptions> Services { get; set; } = [];
    public List<string> ServiceOrder { get; set; } = [];
    public List<AccountDefinition> Accounts { get; set; } = [];
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    private static string FilePath => Path.Combine(App.DataPath, "settings.json");
    public static Settings Load()
    {
        if (!File.Exists(FilePath)) return new();
        try
        {
            var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), JsonOptions) ?? new();
            settings.Services ??= [];
            settings.ServiceOrder ??= [];
            settings.Accounts ??= [];
            return settings;
        }
        catch (JsonException) { File.Copy(FilePath, FilePath + ".invalid-" + DateTime.UtcNow.Ticks); return new(); }
    }
    public void Save()
    {
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this, JsonOptions));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
    public static List<ServiceDefinition> Definitions() => JsonSerializer.Deserialize<List<ServiceDefinition>>(
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "services.json")), JsonOptions) ?? [];
}

public sealed class ServiceState : INotifyPropertyChanged
{
    public required ServiceDefinition Definition { get; init; }
    public required ServiceOptions Options { get; init; }
    public WebView2? View;
    public CoreWebView2? Core => TryCore(View);
    internal static CoreWebView2? TryCore(WebView2? view)
    {
        try { return view?.CoreWebView2; }
        catch (Exception ex) when (ex is InvalidOperationException or COMException) { return null; }
    }
    public bool Loading;
    public bool Suspended;
    public bool NeedsRestart;
    public int RecoveryGeneration;
    public bool Recovering;
    public string LastAddress = "";
    public readonly Queue<DateTime> RecoveryAttempts = new();
    public bool MediaUsed;
    public DateTime HiddenAt = DateTime.UtcNow;
    public string PageTitle = "";
    public bool Attention;
    public bool NativeAttention;
    public bool UnreadPolling;
    public int UnreadRevision;
    public string UnreadKey = "";
    public string? DismissedUnreadKey;
    public int? Unread;
    public int? LastGmailUnread;
    public int? GmailUnreadBaseline;
    public int? GmailRawUnread;
    public string Status = "Not loaded";
    public string Badge => Unread is > 0 ? (Unread > 99 ? "99+" : Unread.ToString()!) : Attention ? "\u2022" : "";
    public event PropertyChangedEventHandler? PropertyChanged;
    public void Changed([CallerMemberName] string? name = null) { PropertyChanged?.Invoke(this, new(name)); PropertyChanged?.Invoke(this, new(nameof(Badge))); }

    public static int? CountFromTitle(string title)
    {
        // Only trust common leading unread formats; arbitrary numbers can be dates or conversation text.
        var match = Regex.Match(title, @"^\s*[\(\[](?<count>\d{1,6})\+?[\)\]](?:\s|$)");
        if (!match.Success) match = Regex.Match(title, @"^Inbox\s*\((?<count>\d{1,6})\)(?:\s|$)", RegexOptions.IgnoreCase);
        return match.Success && int.TryParse(match.Groups["count"].Value, out var n) ? n : null;
    }
}

public sealed record ActivityItem(ServiceState Service, string Title, string Body, DateTimeOffset Time, Action? Open);
