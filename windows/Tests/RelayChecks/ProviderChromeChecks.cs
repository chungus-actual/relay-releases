using System.Linq;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckWhatsAppChrome()
    {
        var whatsapp = services.Single(s => s.Definition.Id == "whatsapp");
        await SelectService(whatsapp);
        var core = whatsapp.Core!;
        core.Navigate("https://web.whatsapp.com/");
        await Until(() => core.Source == "https://web.whatsapp.com/" && whatsapp.Status == "Live");
        var previous = core.Profile.PreferredColorScheme;
        try
        {
            foreach (var dark in new[] { true, false, true })
            {
                core.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Light : CoreWebView2PreferredColorScheme.Dark;
                var scheme = dark ? "dark" : "light";
                await core.ExecuteScriptAsync("document.body.className='" + scheme + "';document.querySelector('nav').scrollTop=300");
                await Task.Delay(250);
                Check(await core.ExecuteScriptAsync("getComputedStyle(document.documentElement).colorScheme==='" + scheme + "' && getComputedStyle(document.querySelector('nav')).colorScheme==='" + scheme + "' && document.querySelector('nav').scrollTop===300 && document.getElementById('draft').value==='Unsent'") == "true", "WhatsApp native scrollbars follow the site's " + scheme + " theme under strict style CSP, retaining scroll and draft");
            }
            await core.ExecuteScriptAsync(WhatsAppChromeScript);
            await core.ExecuteScriptAsync(WhatsAppChromeScript);
            await Task.Delay(250);
            Check(await core.ExecuteScriptAsync("getComputedStyle(document.documentElement).colorScheme==='dark' && document.querySelector('nav').scrollTop===300") == "true", "Duplicate WhatsApp theme installation preserves styling and scroll");
            core.Navigate("https://relay.test/");
            await Until(() => core.Source == "https://relay.test/" && whatsapp.Status == "Live");
            Check(await core.ExecuteScriptAsync("document.documentElement.style.colorScheme==='' && !window.__relayWhatsAppChrome") == "true", "WhatsApp theme integration does not affect other origins");
        }
        finally { core.Profile.PreferredColorScheme = previous; }
    }
}
