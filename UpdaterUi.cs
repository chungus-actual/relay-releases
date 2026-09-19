using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Relay;

public partial class MainWindow
{
    private readonly CancellationTokenSource updateLifetime = new();
    private readonly HttpClient updateHttp = new() { Timeout = TimeSpan.FromMinutes(20) };
    private ReleaseUpdate? pendingUpdate;
    private string? updateStage, updateHash;
    private bool updateBusy;
    private string updateStatus = "Check updates";
    private Button? updateSettingsButton;
    private sealed record CachedUpdate(string Version, string Stage, string Hash);
    private bool LocalBuild => File.Exists(Path.Combine(AppContext.BaseDirectory, "relay-local-build"));
    private static bool InstalledBuild()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\{F35259AB-5848-4623-B12E-2B74B2A4DE73}_is1");
        return key?.GetValue("InstallLocation") is string location &&
            Path.GetFullPath(location).TrimEnd('\\').Equals(Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }

    private void BuildUpdateSettings()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 24, 0, 0) };
        var version = Muted("Relay " + App.DisplayVersion, 10); version.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(version);
        updateSettingsButton = new Button { FontSize = 11, Margin = new Thickness(14, 0, 0, 0), Padding = new Thickness(10, 5, 10, 5) };
        updateSettingsButton.Click += UpdateClick;
        row.Children.Add(updateSettingsButton); LocalContent.Children.Add(row);
        RefreshUpdateUi();
    }

    private void RefreshUpdateUi()
    {
        if (quitting) return;
        if (updateSettingsButton != null)
        {
            updateSettingsButton.Content = LocalBuild ? "Local build" : updateStatus;
            updateSettingsButton.IsEnabled = !LocalBuild && !updateBusy;
        }
        UpdateButton.Visibility = updateHash != null ? Visibility.Visible : Visibility.Collapsed;
        UpdateButton.IsEnabled = !updateBusy;
        UpdateButton.ToolTip = "Restart to update";
    }

    private async void UpdateClick(object sender, RoutedEventArgs e)
    {
        if (updateBusy || LocalBuild) return;
        if (updateHash != null) await ApplyUpdate();
        else await CheckForUpdates();
    }

    private async Task CheckForUpdates()
    {
        if (updateBusy || LocalBuild || App.SmokeTest || quitting) return;
        updateBusy = true; updateStatus = "Checking…"; RefreshUpdateUi();
        try
        {
            using var checkTimeout = CancellationTokenSource.CreateLinkedTokenSource(updateLifetime.Token);
            checkTimeout.CancelAfter(TimeSpan.FromSeconds(30));
            var client = new ReleaseUpdates(updateHttp);
            pendingUpdate = await client.CheckAsync(Version.Parse(App.DisplayVersion), InstalledBuild(), checkTimeout.Token);
            if (pendingUpdate == null) { updateStatus = "Up to date"; return; }
            string updatesRoot = Path.Combine(App.DataPath, "Updates");
            string cachePath = Path.Combine(updatesRoot, "ready.json");
            if (File.Exists(cachePath))
            {
                try
                {
                    var cache = JsonSerializer.Deserialize<CachedUpdate>(await File.ReadAllTextAsync(cachePath));
                    if (cache != null && cache.Version == pendingUpdate.Version.ToString() &&
                        Path.GetDirectoryName(Path.GetFullPath(cache.Stage)) == Path.GetFullPath(updatesRoot) &&
                        Regex.IsMatch(Path.GetFileName(cache.Stage), @"^[a-f0-9]{32}$"))
                    {
                        string cachedPackage = Path.Combine(cache.Stage, pendingUpdate.FileName);
                        if (File.Exists(cachedPackage) && new FileInfo(cachedPackage).Length == pendingUpdate.Size)
                        {
                            await using var cached = File.OpenRead(cachedPackage);
                            string digest = Convert.ToHexString(await SHA256.HashDataAsync(cached, updateLifetime.Token));
                            if (digest.Equals(cache.Hash, StringComparison.OrdinalIgnoreCase))
                            {
                                updateStage = cache.Stage; updateHash = digest; updateStatus = "Restart to update"; return;
                            }
                        }
                    }
                }
                catch (Exception ex) when (ex is IOException or JsonException or ArgumentException) { Log(ex); }
            }
            updateStage = Path.Combine(updatesRoot, Guid.NewGuid().ToString("N"));
            updateStatus = "Downloading…"; RefreshUpdateUi();
            using var downloadTimeout = CancellationTokenSource.CreateLinkedTokenSource(updateLifetime.Token);
            downloadTimeout.CancelAfter(TimeSpan.FromMinutes(20));
            updateHash = await client.DownloadAsync(pendingUpdate, updateStage, new Progress<int>(percent =>
            {
                if (updateHash == null) { updateStatus = $"Updating · {percent}%"; RefreshUpdateUi(); }
            }), downloadTimeout.Token);
            await File.WriteAllTextAsync(cachePath, JsonSerializer.Serialize(new CachedUpdate(pendingUpdate.Version.ToString(), updateStage, updateHash)), updateLifetime.Token);
            updateStatus = "Restart to update";
        }
        catch (Exception ex)
        {
            if (!quitting) { Log(ex); updateStatus = "Retry update"; }
        }
        finally { updateBusy = false; RefreshUpdateUi(); }
    }

    private async Task ApplyUpdate()
    {
        if (pendingUpdate == null || updateStage == null || updateHash == null) return;
        updateBusy = true; updateStatus = "Preparing…"; RefreshUpdateUi();
        try
        {
            File.Delete(Path.Combine(updateStage, "ready"));
            string helper = Path.Combine(updateStage, "Apply-Update.ps1");
            File.Copy(Path.Combine(AppContext.BaseDirectory, "Apply-Update.ps1"), helper, true);
            using var current = Process.GetCurrentProcess();
            string job = Path.Combine(updateStage, "job.json");
            await File.WriteAllTextAsync(job, JsonSerializer.Serialize(new
            {
                Directory = AppContext.BaseDirectory, Executable = Path.Combine(AppContext.BaseDirectory, "Relay.exe"),
                UpdatesRoot = Path.Combine(App.DataPath, "Updates"), Package = Path.Combine(updateStage, pendingUpdate.FileName),
                Hash = updateHash, Version = pendingUpdate.Version.ToString(), Kind = InstalledBuild() ? "installed" : "portable",
                ProcessId = current.Id, Started = current.StartTime.ToUniversalTime().Ticks, SkipRelaunch = false
            }));
            var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
            foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper, "-Job", job })
                start.ArgumentList.Add(arg);
            using var helperProcess = Process.Start(start) ?? throw new IOException("Could not start updater.");
            var deadline = DateTime.UtcNow.AddMinutes(2);
            while (!File.Exists(Path.Combine(updateStage, "ready")))
            {
                if (helperProcess.HasExited) throw new IOException("Update preparation failed.");
                if (DateTime.UtcNow > deadline) { helperProcess.Kill(); throw new IOException("Update preparation timed out."); }
                await Task.Delay(200, updateLifetime.Token);
            }
            // The user's click authorizes this one restart, after verification and staging have succeeded.
            quitting = true; Close();
        }
        catch (Exception ex) { if (!quitting) { Log(ex); updateStatus = "Retry restart"; } }
        finally { updateBusy = false; RefreshUpdateUi(); }
    }
}
