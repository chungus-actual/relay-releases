using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private Window? reportWindow;
    private static async Task<byte[]> CaptureBugReportImage(ServiceState state)
    {
        var core = state.Core;
        var view = state.View;
        if (core == null || view?.IsVisible != true) throw new IOException("That page is no longer visible.");
        using var stream = new MemoryStream();
        await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        if (state.Core != core || state.View != view || view.IsVisible != true) throw new IOException("That page is no longer visible.");
        return stream.ToArray();
    }
    private BugReport CreateBugReport(ServiceState? state) => new()
    {
        Diagnostics = new Dictionary<string, string>
        {
            ["appVersion"] = App.DisplayVersion,
            ["os"] = RuntimeInformation.OSDescription,
            ["architecture"] = RuntimeInformation.ProcessArchitecture.ToString(),
            ["engine"] = "WebView2",
            ["engineVersion"] = state?.Core?.Environment.BrowserVersionString ?? "not loaded",
            ["provider"] = state?.Definition.IconId ?? "shell",
            ["loaded"] = (state?.Core != null).ToString(),
            ["visible"] = (state?.View?.IsVisible == true).ToString(),
            ["suspended"] = (state?.Suspended == true).ToString(),
            ["zoom"] = (state?.Options.Zoom ?? 1).ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["window"] = $"{ActualWidth:0}x{ActualHeight:0}",
            ["loadedAccounts"] = services.Count(s => s.Core != null).ToString()
        },
        Events = ReportEvents.Snapshot()
    };

    private void ShowBugReport(ServiceState? state = null)
    {
        if (reportWindow != null) { reportWindow.Activate(); return; }
        var report = CreateBugReport(state ?? selected);
        state ??= selected;
        var core = state?.Core;
        var view = state?.View;
        var config = BugReport.Configuration();
        byte[]? pending = null;
        bool busy = false, sent = false;
        var panel = new StackPanel { Margin = new Thickness(22) };
        panel.Children.Add(Label("Report a problem", 20, true));
        var explanation = new TextBlock { Text = "Describe what happened, what you expected, and how to reproduce it. Reports include the diagnostics below. Screenshots are optional and may show private conversations.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 8) };
        panel.Children.Add(explanation);
        var description = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 105, MaxLength = 8000, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        panel.Children.Add(description);
        panel.Children.Add(new TextBlock { Text = "Diagnostics (no chat text, URLs, account names, cookies, or sign-in data)", Margin = new Thickness(0, 12, 0, 5), TextWrapping = TextWrapping.Wrap });
        var details = new TextBox { Text = string.Join('\n', report.Diagnostics.Select(pair => pair.Key + ": " + pair.Value)) + "\n\n" + report.Events, IsReadOnly = true, Height = 120, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(details);
        var preview = new Image { MaxHeight = 165, Margin = new Thickness(0, 8, 0, 8) };
        var imageButtons = new StackPanel { Orientation = Orientation.Horizontal };
        var capture = new Button { Content = "Capture page", IsEnabled = core != null && view?.IsVisible == true };
        var attach = new Button { Content = "Attach PNG…", Margin = new Thickness(8, 0, 0, 0) };
        var remove = new Button { Content = "Remove image", Margin = new Thickness(8, 0, 0, 0), IsEnabled = false };
        imageButtons.Children.Add(capture); imageButtons.Children.Add(attach); imageButtons.Children.Add(remove);
        panel.Children.Add(imageButtons); panel.Children.Add(preview);
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
        var save = new Button { Content = "Save report…" };
        var send = new Button { Content = "Send report", Margin = new Thickness(8, 0, 0, 0), Visibility = config.Endpoint == null ? Visibility.Collapsed : Visibility.Visible };
        var cancel = new Button { Content = "Close", Margin = new Thickness(8, 0, 0, 0) };
        var code = new PasswordBox();
        void UpdateActions()
        {
            description.IsReadOnly = pending != null;
            capture.IsEnabled = !busy && pending == null && core != null && state?.Core == core && view?.IsVisible == true;
            attach.IsEnabled = !busy && pending == null;
            remove.IsEnabled = !busy && pending == null && report.Screenshot != null;
            save.IsEnabled = cancel.IsEnabled = !busy;
            send.IsEnabled = !busy && !sent && config.Endpoint != null;
            code.IsEnabled = !busy && !sent;
        }
        void SetImage(byte[] bytes)
        {
            if (bytes.Length > 6 * 1024 * 1024 || bytes.Length < 8 || !bytes.Take(8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) throw new IOException("Choose a PNG smaller than 6 MB.");
            using var stream = new MemoryStream(bytes);
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.DecodePixelWidth = 1000; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
            preview.Source = bitmap; report.Screenshot = Convert.ToBase64String(bytes); remove.IsEnabled = true;
        }
        capture.Click += async (_, _) =>
        {
            if (busy || pending != null) return;
            busy = true; UpdateActions();
            try
            {
                if (state?.Core != core || view?.IsVisible != true) throw new IOException("That page is no longer visible. Attach an existing screenshot instead.");
                SetImage(await CaptureBugReportImage(state!)); status.Text = "Review the image before sending. A page capture may redraw a rendering glitch; you can attach an OS screenshot instead.";
            }
            catch (Exception) { status.Text = "Could not capture this page. You can attach a PNG screenshot instead."; }
            finally { busy = false; UpdateActions(); }
        };
        attach.Click += (_, _) =>
        {
            if (busy || pending != null) return;
            var picker = new Microsoft.Win32.OpenFileDialog { Filter = "PNG screenshot|*.png" };
            if (picker.ShowDialog(reportWindow) != true) return;
            try { if (new FileInfo(picker.FileName).Length > 6 * 1024 * 1024) throw new IOException(); SetImage(File.ReadAllBytes(picker.FileName)); status.Text = "Review the image before sending."; }
            catch { status.Text = "Choose a valid PNG smaller than 6 MB."; }
        };
        remove.Click += (_, _) => { report.Screenshot = null; preview.Source = null; remove.IsEnabled = false; };
        panel.Children.Add(new TextBlock { Text = "Destination: " + config.Destination, TextWrapping = TextWrapping.Wrap });
        if (config.Endpoint != null)
        {
            panel.Children.Add(new TextBlock { Text = "Intake code (provided by the Relay maintainer)", Margin = new Thickness(0, 8, 0, 4) });
            panel.Children.Add(code);
        }
        if (config.Endpoint == null) status.Text = "Online reporting is not configured in this build. Save the report and send it to the maintainer privately.";
        panel.Children.Add(status);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(save); actions.Children.Add(send); actions.Children.Add(cancel); panel.Children.Add(actions);
        save.Click += (_, _) =>
        {
            if (busy) return;
            byte[] payload;
            try { report.Description = description.Text.Trim(); payload = pending ?? report.Encode(); }
            catch (IOException ex) { status.Text = ex.Message; return; }
            var picker = new Microsoft.Win32.SaveFileDialog { Filter = "Relay report|*.json", FileName = "relay-report-" + report.Id + ".json" };
            if (picker.ShowDialog(reportWindow) != true) return;
            try { File.WriteAllBytes(picker.FileName, payload); status.Text = "Report saved. The file includes any image shown above."; }
            catch { status.Text = "Could not save the report. Choose another location."; }
        };
        send.Click += async (_, _) =>
        {
            if (busy || sent || config.Endpoint == null) return;
            if (string.IsNullOrWhiteSpace(description.Text) || string.IsNullOrWhiteSpace(code.Password)) { status.Text = "Enter a description and the intake code."; return; }
            report.Description = description.Text.Trim(); pending ??= report.Encode();
            // Retry exactly the same report after an uncertain network outcome.
            busy = true; UpdateActions();
            status.Text = "Sending…";
            try { await BugReport.Submit(pending, report.Id, config.Endpoint!, code.Password); sent = true; send.Content = "Report received"; status.Text = "Report received: " + report.Id; code.Clear(); }
            catch (Exception ex) { status.Text = ex is IOException ? ex.Message : "Could not confirm delivery. Save the report or retry; retries use the same report ID."; send.Content = "Retry send"; }
            finally { busy = false; UpdateActions(); }
        };
        var window = new Window { Title = "Report a problem", Owner = this, Width = 640, Height = 820, Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        window.SetResourceReference(BackgroundProperty, "Panel"); window.SetResourceReference(ForegroundProperty, "Ink");
        cancel.Click += (_, _) => window.Close(); window.Closed += (_, _) => reportWindow = null;
        window.Closing += (_, e) => e.Cancel = busy;
        UpdateActions();
        reportWindow = window; window.ShowDialog();
    }

    private async Task RefreshMessengerDisplay(ServiceState state)
    {
        if (state.Definition.IconId != "messenger" || state.Core == null || state.View?.IsVisible != true) return;
        ReportEvents.Record("messenger", "manual-display-refresh");
        try { await state.Core.ExecuteScriptAsync("window.__relayMessengerChrome?.activate()"); }
        catch (Exception ex) { Log(ex); }
    }
}
