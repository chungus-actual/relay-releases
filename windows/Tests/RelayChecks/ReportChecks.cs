using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckBugReports(string output)
    {
        for (int i = 0; i < 240; i++) ReportEvents.Record("fixture", "event-" + i);
        string events = ReportEvents.Snapshot();
        Check(events.Split('\n').Length == 200 && !events.Contains("event-0\n") && events.Contains("event-239"), "Report events expire oldest entries at the 200-event limit");
        Check(BugReport.Endpoint("https://reports.example.test/reports") != null, "HTTPS report intake can be configured");
        foreach (string endpointAddress in new[] { "", "http://reports.example.test/", "https://user:secret@reports.example.test/", "https://reports.example.test/#fragment", "file:///tmp/report" })
            Check(BugReport.Endpoint(endpointAddress) == null, "Report configuration rejects insecure, credentialed, or fragmented URLs");
        var service = services[0];
        string title = service.PageTitle, address = service.LastAddress;
        try
        {
            service.PageTitle = "PRIVATE_CHAT_SENTINEL"; service.LastAddress = "https://secret.test/PRIVATE_PATH_SENTINEL";
            var report = CreateBugReport(service);
            report.Description = "Rendering regression fixture 界";
            string encoded = Encoding.UTF8.GetString(report.Encode());
            Check(!encoded.Contains("PRIVATE_CHAT_SENTINEL") && !encoded.Contains("PRIVATE_PATH_SENTINEL"), "Report diagnostics omit titles and URLs");
            Check(report.Screenshot == null, "Screenshot capture is opt-in");
            byte[] screenshot = await CaptureBugReportImage(service);
            report.Screenshot = Convert.ToBase64String(screenshot);
            Check(screenshot.Length > 100 && screenshot[0] == 137, "Reports can capture a real browser PNG");
            byte[] frozen = report.Encode();
            report.Description = "changed";
            Check(JsonDocument.Parse(frozen).RootElement.GetProperty("description").GetString() == "Rendering regression fixture 界", "A retry retains the exact submitted report payload");
            File.WriteAllBytes(Path.Combine(output, "bug-report-fixture.json"), frozen);
            report.Screenshot = null;
            using var cleared = JsonDocument.Parse(report.Encode());
            Check(cleared.RootElement.GetProperty("screenshot").ValueKind == JsonValueKind.Null, "Removing an attachment excludes it from the next export");
            foreach (string invalid in new[] { " ", new string('x', 8001) })
            {
                report.Description = invalid;
                bool rejected = false;
                try { report.Encode(); } catch (IOException) { rejected = true; }
                Check(rejected, "Empty or oversized reports cannot be exported for intake");
            }
            var visibility = service.View!.Visibility;
            service.View.Visibility = System.Windows.Visibility.Hidden;
            try
            {
                bool rejected = false;
                try { await CaptureBugReportImage(service); } catch (IOException) { rejected = true; }
                Check(rejected, "Hidden pages cannot contribute a stale screenshot");
            }
            finally { service.View.Visibility = visibility; }

            Exception? dialogFailure = null;
            var dialogChecked = new TaskCompletionSource();
            _ = Dispatcher.BeginInvoke(new Action(async () =>
            {
                try
                {
                    await Until(() => reportWindow?.IsVisible == true);
                    var window = reportWindow!;
                    var panel = (StackPanel)((ScrollViewer)window.Content).Content;
                    var buttons = panel.Children.OfType<StackPanel>().SelectMany(row => row.Children.OfType<Button>()).ToArray();
                    var capture = buttons.Single(button => Equals(button.Content, "Capture page"));
                    var save = buttons.Single(button => Equals(button.Content, "Save report…"));
                    var send = buttons.Single(button => Equals(button.Content, "Send report"));
                    var remove = buttons.Single(button => Equals(button.Content, "Remove image"));
                    var preview = panel.Children.OfType<Image>().Single();
                    panel.Children.OfType<TextBox>().First().Text = "Messenger rendering fixture";
                    if (BugReport.Configuration().Endpoint == null)
                        Check(send.Visibility == Visibility.Collapsed && !panel.Children.OfType<PasswordBox>().Any(), "Local-only reporting does not request an intake code");
                    capture.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                    Check(!save.IsEnabled && !send.IsEnabled, "Capture blocks export/submission until the preview is ready");
                    await Until(() => preview.Source != null && save.IsEnabled);
                    CaptureElement(window, Path.Combine(output, "bug-report-dialog.png"));
                    remove.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                    Check(preview.Source == null && !remove.IsEnabled, "Removing a report image clears its preview and action");
                }
                catch (Exception ex) { dialogFailure = ex; }
                finally { reportWindow?.Close(); dialogChecked.TrySetResult(); }
            }));
            ShowBugReport(service);
            await dialogChecked.Task;
            if (dialogFailure != null) throw dialogFailure;
            Check(reportWindow == null, "Closing the report discards its draft window");
        }
        finally { service.PageTitle = title; service.LastAddress = address; }
    }
}
