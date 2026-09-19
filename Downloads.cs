using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace Relay;

internal sealed class DownloadEntry
{
    internal required string AccountId;
    internal required string AccountName;
    internal required string FilePath;
    internal CoreWebView2? Owner;
    internal CoreWebView2DownloadOperation? Operation;
    internal long Received;
    internal long Total;
    internal bool Complete;
    internal bool Paused;
    internal string Status = "Downloading";
    internal EventHandler<object>? ProgressHandler;
    internal EventHandler<object>? StateHandler;
    internal bool Active;
    internal bool Resumable;
    internal void Release()
    {
        if (Operation is { } operation)
        {
            try
            {
                if (ProgressHandler != null) operation.BytesReceivedChanged -= ProgressHandler;
                if (StateHandler != null) operation.StateChanged -= StateHandler;
            }
            catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
        }
        Operation = null; Owner = null; ProgressHandler = null; StateHandler = null; Active = false; Resumable = false;
    }
}

public partial class MainWindow
{
    private readonly List<DownloadEntry> downloads = [];
    private readonly DispatcherTimer downloadTimer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(500) };
    private bool downloadsDirty;

    private void InitializeDownloads()
    {
        downloadTimer.Tick += (_, _) => { if (downloadsDirty) RenderDownloads(); };
        IsVisibleChanged += (_, _) => UpdateDownloadsTimer();
    }
    private void UpdateDownloadsTimer()
    {
        if (IsVisible && DownloadsPanel.Visibility == Visibility.Visible && !quitting) downloadTimer.Start();
        else downloadTimer.Stop();
    }
    private void DownloadsClick(object sender, RoutedEventArgs e)
    {
        bool open = DownloadsPanel.Visibility != Visibility.Visible;
        DownloadsPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        DownloadsColumn.Width = new GridLength(open ? 300 : 0);
        DownloadsButton.SetResourceReference(Button.BackgroundProperty, open ? "AccentSoft" : "Panel");
        DownloadsButton.SetResourceReference(Button.ForegroundProperty, open ? "Accent" : "Muted");
        if (open) RenderDownloads();
        UpdateDownloadsTimer();
    }
    private void ClearDownloadsClick(object sender, RoutedEventArgs e)
    {
        foreach (var item in downloads.Where(d => d.Operation == null).ToArray()) downloads.Remove(item);
        RenderDownloads();
    }
    private bool HasActiveDownloads(ServiceState state) => downloads.Any(d => d.AccountId == state.Definition.Id && d.Active);

    private void ConfigureDownloads(CoreWebView2 core, ServiceState state)
    {
        core.DownloadStarting += (_, e) =>
        {
            e.Handled = true;
            using var deferral = e.GetDeferral();
            if (quitting || !state.Options.Enabled) { e.Cancel = true; return; }
            try
            {
                if (App.SmokeTest)
                {
                    var folder = Path.Combine(App.DataPath, "Downloads", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
                    e.ResultFilePath = Path.Combine(folder, "fixture.txt");
                }
                else
                {
                    var save = new SaveFileDialog { FileName = Path.GetFileName(e.ResultFilePath), InitialDirectory = core.Profile.DefaultDownloadFolderPath, OverwritePrompt = true, Title = "Save download" };
                    if (save.ShowDialog(this) != true) { e.Cancel = true; return; }
                    e.ResultFilePath = save.FileName;
                }
                TrackDownload(state, core, e.DownloadOperation, e.ResultFilePath);
            }
            catch (Exception ex) { e.Cancel = true; Log(ex); }
        };
    }

    private void TrackDownload(ServiceState state, CoreWebView2 core, CoreWebView2DownloadOperation operation, string path)
    {
        var item = new DownloadEntry { AccountId = state.Definition.Id, AccountName = state.Definition.Name, Owner = core, Operation = operation, FilePath = path };
        item.ProgressHandler = (_, _) => ReadDownload(item);
        item.StateHandler = (_, _) => ReadDownload(item);
        operation.BytesReceivedChanged += item.ProgressHandler;
        operation.StateChanged += item.StateHandler;
        downloads.Insert(0, item);
        ReadDownload(item);
        PruneDownloads();
    }
    private void ReadDownload(DownloadEntry item)
    {
        if (item.Operation is not { } operation) return;
        try
        {
            item.Received = operation.BytesReceived;
            item.Total = operation.TotalBytesToReceive is { } total ? (long)Math.Min(total, (ulong)long.MaxValue) : 0;
            item.Complete = operation.State == CoreWebView2DownloadState.Completed;
            item.Active = operation.State == CoreWebView2DownloadState.InProgress;
            item.Resumable = operation.CanResume;
            item.Status = item.Complete ? "Complete" : operation.State == CoreWebView2DownloadState.InProgress ? "Downloading"
                : item.Paused ? "Paused" : operation.InterruptReason == CoreWebView2DownloadInterruptReason.UserCanceled ? "Canceled" : "Interrupted";
            if (item.Complete || operation.State == CoreWebView2DownloadState.Interrupted && !operation.CanResume) item.Release();
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException) { item.Status = "Interrupted"; item.Release(); }
        downloadsDirty = true; PruneDownloads(); CloseFinishedDownloadPopups();
    }
    private void PruneDownloads()
    {
        var finished = downloads.Where(d => d.Operation == null).ToArray();
        foreach (var item in finished.Skip(50)) downloads.Remove(item);
    }
    private void StopViewDownloads(CoreWebView2? core)
    {
        foreach (var item in downloads.Where(d => d.Owner == core && d.Operation != null).ToArray()) StopDownload(item);
    }
    private void StopAccountDownloads(ServiceState state)
    {
        foreach (var item in downloads.Where(d => d.AccountId == state.Definition.Id && d.Operation != null).ToArray()) StopDownload(item);
    }
    private void StopDownload(DownloadEntry item)
    {
        try { item.Operation?.Cancel(); } catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
        item.Status = "Interrupted"; item.Release(); downloadsDirty = true; CloseFinishedDownloadPopups();
    }
    private static string DownloadBytes(long bytes) => bytes < 1024 ? Math.Max(0, bytes) + " B" : bytes < 1024 * 1024 ? Math.Max(0, bytes / 1024d).ToString("0") + " KB" : MemoryReading(bytes);

    private static ProcessStartInfo DownloadFolderTarget(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (directory == null || !Directory.Exists(directory)) throw new DirectoryNotFoundException("Folder unavailable.");
        return File.Exists(path)
            ? new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = true }
            : new ProcessStartInfo(directory) { UseShellExecute = true };
    }

    private void RenderDownloads()
    {
        downloadsDirty = false; PruneDownloads(); DownloadItems.Children.Clear();
        if (downloads.Count == 0) { DownloadItems.Children.Add(Muted("No downloads", 12)); return; }
        foreach (var item in downloads)
        {
            var row = new StackPanel();
            var heading = new DockPanel();
            var folder = new Button { Style = (Style)FindResource("IconButton"), Content = "\uE8B7", ToolTip = "Open folder",
                Width = 28, Height = 28, Margin = new Thickness(8, -4, 0, 0),
                IsEnabled = Directory.Exists(Path.GetDirectoryName(item.FilePath)) };
            System.Windows.Automation.AutomationProperties.SetName(folder, "Open folder: " + Path.GetFileName(item.FilePath));
            folder.Click += (_, _) =>
            {
                try { Process.Start(DownloadFolderTarget(item.FilePath)); }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "Download", MessageBoxButton.OK, MessageBoxImage.Information); }
            };
            DockPanel.SetDock(folder, Dock.Right); heading.Children.Add(folder);
            heading.Children.Add(Label(Path.GetFileName(item.FilePath), 12, true));
            row.Children.Add(heading);
            var account = Muted(item.AccountName, 10); account.Margin = new Thickness(0, 4, 0, 5); row.Children.Add(account);
            row.Children.Add(Muted(item.Status + " · " + DownloadBytes(item.Received) + (item.Total > 0 && !item.Complete ? " / " + DownloadBytes(item.Total) : ""), 10));
            if (item.Active)
            {
                var progress = new ProgressBar { Height = 3, Margin = new Thickness(0, 8, 0, 0), Minimum = 0, Maximum = Math.Max(1, item.Total), Value = item.Received, IsIndeterminate = item.Total <= 0 };
                progress.SetResourceReference(Control.ForegroundProperty, "Accent"); progress.SetResourceReference(Control.BackgroundProperty, "Line"); row.Children.Add(progress);
            }
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            void Action(string label, Action action)
            {
                var button = new Button { Content = label, FontSize = 10, Padding = new Thickness(7, 4, 7, 4), Margin = new Thickness(0, 0, 4, 0) };
                button.Click += (_, _) => { try { action(); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Download", MessageBoxButton.OK, MessageBoxImage.Information); } };
                actions.Children.Add(button);
            }
            if (item.Complete && File.Exists(item.FilePath))
            {
                Action("Open", () => Process.Start(new ProcessStartInfo(item.FilePath) { UseShellExecute = true }));
            }
            else if (item.Operation is { } operation)
            {
                if (!item.Active && item.Resumable) Action("Resume", () => { item.Paused = false; operation.Resume(); ReadDownload(item); RenderDownloads(); });
                Action("Cancel", () => { operation.Cancel(); item.Status = "Canceled"; item.Release(); CloseFinishedDownloadPopups(); RenderDownloads(); });
            }
            row.Children.Add(actions);
            var card = Card(row, new Thickness(12)); card.Margin = new Thickness(0, 0, 0, 8); DownloadItems.Children.Add(card);
        }
    }
}
