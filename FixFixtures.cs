using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private static void ConfigureFixFixtures(CoreWebView2 core, ServiceState state)
    {
        if (!App.SmokeTest) return;
        core.AddWebResourceRequestedFilter("https://external.relay.test/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            if (new System.Uri(e.Request.Uri).Host != "external.relay.test") return;
            e.Response = core.Environment.CreateWebResourceResponse(new System.IO.MemoryStream(System.Text.Encoding.UTF8.GetBytes("<!doctype html><title>External link fixture</title>")), 200, "OK", "Content-Type: text/html");
        };
        if (state.Definition.IconId == "messenger")
        {
            foreach (var host in new[] { "cdn.fbsbx.com", "scontent.xx.fbcdn.net" })
                core.AddWebResourceRequestedFilter("https://" + host + "/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, e) =>
            {
                if (new System.Uri(e.Request.Uri).Host is not ("cdn.fbsbx.com" or "scontent.xx.fbcdn.net")) return;
                var bytes = System.Text.Encoding.UTF8.GetBytes("Relay attachment fixture");
                e.Response = core.Environment.CreateWebResourceResponse(new System.IO.MemoryStream(bytes), 200, "OK",
                    "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=relay-cdn.txt");
            };
        }
        if (state.Definition.IconId is "gmail" or "calendar" or "googlekeep")
        {
            foreach (var host in new[] { "accounts.google.com", "accounts.youtube.com", "mail.google.com", "calendar.google.com", "keep.google.com", "workspace.google.com" })
                core.AddWebResourceRequestedFilter("https://" + host + "/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, e) =>
            {
                var uri = new System.Uri(e.Request.Uri);
                var host = uri.Host;
                if (host is not ("accounts.google.com" or "accounts.youtube.com" or "mail.google.com" or "calendar.google.com" or "keep.google.com" or "workspace.google.com")) return;
                // Exercise real NavigationStarting redirects through Google's cross-domain session hop.
                var redirect = (host, uri.AbsolutePath) switch
                {
                    ("accounts.google.com", "/relay-session-handoff") => "https://accounts.youtube.com/accounts/SetSID?relay-fixture=1",
                    ("accounts.youtube.com", "/accounts/SetSID") => "https://mail.google.com/mail/u/0/#inbox",
                    _ => null
                };
                if (redirect != null)
                {
                    e.Response = core.Environment.CreateWebResourceResponse(null, 302, "Found", "Location: " + redirect + "\r\nCache-Control: no-store");
                    return;
                }
                var html = "<!doctype html><title>Gmail fixture</title><body>Sign-in fixture</body>";
                e.Response = core.Environment.CreateWebResourceResponse(new System.IO.MemoryStream(System.Text.Encoding.UTF8.GetBytes(html)), 200, "OK", "Content-Type: text/html");
            };
        }
    }

    private const string FragmentedMessengerFixture = """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="style-src 'nonce-fixture'">
        <style nonce="fixture">
        body{margin:0}
        [role=banner]{height:0}
        .piece{position:fixed;top:0;height:60px;background:red;width:25%}
        .piece:nth-child(2){left:25%;width:50%}.piece:nth-child(3){right:0}
        [role=main]{position:fixed;top:60px;bottom:0;width:100%;height:calc(100vh - 60px);background:#161719;color:white}
        </style>
        <div role="banner"><div class="piece">Search</div><div class="piece">Facebook navigation</div><div class="piece">Account</div></div>
        <main role="main"><header id="chat-header">Chat controls</header>Messages</main>
        """;

    private const string NestedMessengerFixture = """
        <!doctype html><style>
        *{box-sizing:border-box}body{margin:0;padding-top:56px;background:#111}
        [role=banner]{position:fixed;top:0;height:56px;width:100%;background:red}
        .layout{display:flex;height:calc(100vh - 56px)}
        [role=navigation]{width:30%;height:calc(100vh - 56px);background:#242526}
        [role=main]{flex:1;height:calc(100vh - 56px)}
        .thread{margin:16px;height:calc(100vh - 88px);border-radius:10px;background:#003244;display:flex;flex-direction:column}
        .cached .thread{margin-top:40px;height:calc(100vh - 112px)}
        #chat-controls{height:64px}#messages{flex:1;overflow:auto}
        #composer{height:48px;flex-shrink:0;background:#004455}
        </style><div role="banner">Facebook</div><div class="layout"><nav role="navigation">Chats</nav>
        <main role="main"><div class="thread"><header id="chat-controls">Chat controls</header><div id="messages">Messages</div><footer id="composer">Composer</footer></div></main></div>
        """;
}
