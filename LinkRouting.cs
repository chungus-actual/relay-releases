using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Relay;

public partial class MainWindow
{
    private readonly List<string> smokeExternalLinks = [];

    private static Uri? WebLink(string address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")) return null;
        // Chat services wrap outgoing links in first-party redirect URLs.
        bool wrapper = (uri.Host is "l.facebook.com" or "lm.facebook.com" or "www.facebook.com" && uri.AbsolutePath == "/l.php")
            || (uri.Host is "google.com" or "www.google.com" && uri.AbsolutePath == "/url")
            || (uri.Host is "www.youtube.com" or "youtube.com" && uri.AbsolutePath == "/redirect");
        if (wrapper)
        {
            foreach (var pair in uri.Query.TrimStart('?').Split('&'))
            {
                var parts = pair.Split('=', 2);
                if (parts.Length != 2 || parts[0] is not ("u" or "q" or "url")) continue;
                var target = Uri.UnescapeDataString(parts[1].Replace("+", " "));
                if (Uri.TryCreate(target, UriKind.Absolute, out var destination) && destination.Scheme is "https" or "http") return destination;
            }
        }
        return uri;
    }

    private static bool ProviderAttachment(ServiceState state, Uri uri) =>
        state.Definition.IconId == "messenger" && uri.Scheme == "https"
        && (uri.Host is "fbcdn.net" or "fbsbx.com"
            || uri.Host.EndsWith(".fbcdn.net", StringComparison.Ordinal)
            || uri.Host.EndsWith(".fbsbx.com", StringComparison.Ordinal));

    private static bool ServiceLink(ServiceState state, Uri uri)
    {
        if (uri.Scheme != "https") return false;
        if (App.SmokeTest && uri.Host == "relay.test") return true;
        // These identity-provider windows must retain the account's WebView profile.
        if (IsGoogleSignIn(uri.AbsoluteUri) || uri.Host is "login.microsoftonline.com" or "login.live.com" or "appleid.apple.com") return true;
        if (state.Definition.IconId is "gmail" or "calendar" or "googlemessages" or "googlekeep")
            return uri.Host is "mail.google.com" or "calendar.google.com" or "messages.google.com" or "keep.google.com"
                || IsGoogleLanding(state.Definition.IconId, uri.AbsoluteUri);
        if (state.Definition.IconId == "youtubemusic") return uri.Host == "music.youtube.com";
        return state.Definition.Owns(uri.AbsoluteUri);
    }

    private bool RouteExternalLink(ServiceState state, string address)
    {
        if (settings.CaptureLinks || WebLink(address) is not { } uri || ServiceLink(state, uri) || ProviderAttachment(state, uri)) return false;
        try
        {
            if (App.SmokeTest) smokeExternalLinks.Add(uri.AbsoluteUri);
            else Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception ex) { Log(ex); }
        return true;
    }
}
