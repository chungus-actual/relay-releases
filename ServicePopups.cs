using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private readonly System.Collections.Generic.Dictionary<Window, CoreWebView2> downloadPopups = [];

    private void CloseFinishedDownloadPopups()
    {
        foreach (var entry in downloadPopups.ToArray())
        {
            if (downloads.Any(d => d.Owner == entry.Value && d.Operation != null)) continue;
            downloadPopups.Remove(entry.Key);
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (!popups.Contains(entry.Key)) return;
                if (downloads.Any(d => d.Owner == entry.Value && d.Operation != null))
                    downloadPopups[entry.Key] = entry.Value;
                else entry.Key.Close();
            }));
        }
    }

    private static bool IsGmailInbox(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host.Equals("mail.google.com", StringComparison.OrdinalIgnoreCase)
        && uri.AbsolutePath.StartsWith("/mail/", StringComparison.Ordinal);

    private static bool IsGoogleSignIn(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        // Google can establish its YouTube session before returning to the requested app.
        && uri.Scheme == "https" && uri.Host is "accounts.google.com" or "accounts.youtube.com";

    private static string? GoogleAppHome(string provider) => provider switch
    {
        "gmail" => "https://mail.google.com/mail/",
        "calendar" => "https://calendar.google.com/calendar/",
        "googlemessages" => "https://messages.google.com/web/",
        "googlekeep" => "https://keep.google.com/",
        _ => null
    };

    private static bool IsGoogleApp(string provider, string address)
    {
        var home = GoogleAppHome(provider);
        if (home == null || !Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https") return false;
        var app = new Uri(home);
        return uri.Host == app.Host && (uri.AbsolutePath == app.AbsolutePath.TrimEnd('/') || uri.AbsolutePath.StartsWith(app.AbsolutePath, StringComparison.Ordinal));
    }

    private static bool IsGoogleLanding(string provider, string address)
    {
        var home = GoogleAppHome(provider);
        if (home == null || !Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https") return false;
        return IsGoogleSignIn(address)
            || (uri.Host == new Uri(home).Host && !IsGoogleApp(provider, address))
            || ((uri.Host is "workspace.google.com" or "www.google.com" or "google.com")
                && uri.AbsolutePath.Contains("/" + (provider == "googlemessages" ? "messages" : provider), StringComparison.Ordinal));
    }

    private static string ServiceStartAddress(ServiceState state)
    {
        if (GoogleAppHome(state.Definition.IconId) is { } home && IsGoogleLanding(state.Definition.IconId, state.LastAddress)) return home;
        return Uri.TryCreate(state.LastAddress, UriKind.Absolute, out var address) && address.Scheme == "https" ? state.LastAddress : state.Definition.Url;
    }

    private async Task OpenServicePopup(CoreWebView2 opener, ServiceState state, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true;
        if (RouteExternalLink(state, e.Uri)) return;
        if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || (uri.Scheme is not ("https" or "http") && e.Uri != "about:blank")) return;
        using var deferral = e.GetDeferral();
        Window? popup = null;
        try
        {
            // Use the requesting view's actual environment/profile, including nested popups.
            var env = opener.Environment;
            var options = env.CreateCoreWebView2ControllerOptions();
            options.ProfileName = opener.Profile.ProfileName;
            options.IsInPrivateModeEnabled = opener.Profile.IsInPrivateModeEnabled;
            var mainView = state.View;
            var mainAddress = state.Core?.Source ?? "";
            var popupView = new WebView2();
            popup = CreatePopup(state, popupView);
            popup.ShowActivated = !App.SmokeTest;
            popups.Add(popup);
            popup.Closing += (_, args) =>
            {
                // WPF handles WindowCloseRequested before our core handler. Keep an
                // attachment's owner alive when either the page or user closes it.
                var downloadCore = ServiceState.TryCore(popupView);
                if (quitting || !state.Options.Enabled || downloadCore == null
                    || !downloads.Any(d => d.Owner == downloadCore && d.Operation != null)) return;
                args.Cancel = true;
                downloadPopups[popup] = downloadCore;
                popup.Hide();
            };
            popup.Closed += (_, _) => { popups.Remove(popup); downloadPopups.Remove(popup); StopViewDownloads(ServiceState.TryCore(popupView)); popupView.Dispose(); };
            popup.Show();
            await popupView.EnsureCoreWebView2Async(env, options);
            if (quitting || !popups.Contains(popup) || !state.Options.Enabled) return;
            var popupCore = popupView.CoreWebView2;
            if (popupCore.Profile.ProfileName != opener.Profile.ProfileName)
                throw new InvalidOperationException("Popup profile mismatch.");
            await ConfigureCore(popupCore, state, popupView);
            if (quitting || !popups.Contains(popup) || !state.Options.Enabled) return;
            bool sawSignIn = IsGoogleSignIn(e.Uri), returning = false;
            popupCore.NavigationStarting += (_, args) => sawSignIn |= IsGoogleSignIn(args.Uri);
            popupCore.SourceChanged += (_, _) =>
            {
                if (!popups.Contains(popup)) return;
                popup.Title = "Relay - " + (Uri.TryCreate(popupCore.Source, UriKind.Absolute, out var address) ? address.Host : state.Definition.Name);
            };
            popupCore.NavigationCompleted += (_, args) =>
            {
                if (!args.IsSuccess || returning || quitting || !popups.Contains(popup) || !state.Options.Enabled
                    || state.View != mainView || !IsGoogleApp(state.Definition.IconId, popupCore.Source)) return;
                var mainCore = state.Core;
                if (mainCore == null || mainCore.Source != mainAddress || (!sawSignIn && !IsGoogleLanding(state.Definition.IconId, mainAddress))) return;
                // Google login may finish in its app while the opener is still a public landing page.
                // Navigate to the completed app route, preserving the shared profile's cookies.
                returning = true;
                var destination = popupCore.Source;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (quitting || !state.Options.Enabled || state.View != mainView || !popups.Contains(popup)) return;
                    var current = state.Core;
                    if (current == null || current.Source != mainAddress) return;
                    try
                    {
                        current.Navigate(destination);
                        popup.Close();
                    }
                    catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { Log(ex); }
                }));
            };
            popupCore.WindowCloseRequested += (_, _) => popup.Close();
            e.NewWindow = popupCore;
        }
        catch (Exception ex)
        {
            if (popup != null && popups.Contains(popup)) popup.Close();
            if (!quitting) Log(ex);
        }
    }
}
