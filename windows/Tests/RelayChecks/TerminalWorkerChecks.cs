using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckTerminalWorkerIsolation(CoreWebView2 terminalCore)
    {
        // Use real loopback responses: another WebResourceRequested handler could
        // overwrite Terminal's erroneous 403 and conceal the original regression.
        using var server = new WorkerFixtureServer();
        using var view = new WebView2 { Width = 2, Height = 2 };
        WebHost.Children.Add(view);
        try
        {
            var env = await environment!;
            var options = env.CreateCoreWebView2ControllerOptions();
            options.ProfileName = "worker-isolation";
            await view.EnsureCoreWebView2Async(env, options);
            var core = view.CoreWebView2;
            core.Navigate(server.Address);
            await WaitScript(core, "location.pathname === '/' && document.readyState === 'complete' && location.port === '" + server.Port + "'");
            await core.ExecuteScriptAsync("""
                window.workerResults = {};
                window.sharedFixture = new SharedWorker('/shared.js');
                sharedFixture.port.onmessage = e => workerResults.shared = e.data;
                sharedFixture.onerror = () => workerResults.shared = {ok:false};
                sharedFixture.port.start();
                sharedFixture.port.postMessage(1);
                navigator.serviceWorker.register('/service.js')
                  .then(() => navigator.serviceWorker.ready).then(registration => {
                    window.serviceFixture = registration.active;
                    window.serviceChannel = new MessageChannel();
                    serviceChannel.port1.onmessage = e => workerResults.service = e.data;
                    serviceFixture.postMessage(1, [serviceChannel.port2]);
                  }).catch(() => workerResults.service = {ok:false});
                """);
            await WaitScript(core, "!!workerResults.shared && !!workerResults.service");
            Check(await core.ExecuteScriptAsync("workerResults.shared.ok && workerResults.service.ok") == "true",
                "Other account shared/service workers can import scripts and fetch while two Terminal accounts are loaded");

            // The terminal still has no permission to start workers or fetch remote data.
            var policyFixture = File.ReadAllText(Path.Combine(Environment.CurrentDirectory, "Assets", "Fixtures", "terminal-policy-checks.js"));
            var policyResult = await terminalCore.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new { expression = policyFixture, awaitPromise = true, returnByValue = true }));
            using (var json = JsonDocument.Parse(policyResult))
                Check(!json.RootElement.TryGetProperty("exceptionDetails", out _) && json.RootElement.GetProperty("result").GetProperty("value").GetBoolean(),
                    "Terminal retains its worker and network restrictions");

            await core.ExecuteScriptAsync("workerResults.shared = null; sharedFixture.port.postMessage(2)");
            await WaitScript(core, "!!workerResults.shared");
            Check(await core.ExecuteScriptAsync("workerResults.shared.ok && workerResults.shared.round === 2") == "true",
                "A retained shared-worker connection continues after Terminal rejects its own network requests");
            await core.ExecuteScriptAsync("sharedFixture.port.close(); navigator.serviceWorker.getRegistrations().then(all => Promise.all(all.map(r => r.unregister())))");
        }
        finally { WebHost.Children.Remove(view); }
    }

    private sealed class WorkerFixtureServer : IDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource lifetime = new();
        private readonly Task serving;
        public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
        public string Address => "http://127.0.0.1:" + Port + "/";
        public WorkerFixtureServer() { listener.Start(); serving = Serve(); }
        private async Task Serve()
        {
            try
            {
                while (true) _ = Respond(await listener.AcceptTcpClientAsync(lifetime.Token), lifetime.Token);
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException or OperationCanceledException) { }
        }
        private static async Task Respond(TcpClient client, CancellationToken cancellation)
        {
            using (client)
            try
            {
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
                var request = await reader.ReadLineAsync(cancellation);
                if (request == null) return;
                while (await reader.ReadLineAsync(cancellation) is { Length: > 0 }) { }
                string path = request.Split(' ')[1];
                string content = path switch
                {
                    "/shared.js" => "importScripts('/dependency.js'); onconnect=e=>{const p=e.ports[0];p.onmessage=async e=>{try{const r=await fetch('/payload');p.postMessage({ok:r.ok&&await r.text()==='worker-ok'&&self.dependency,round:e.data});}catch{p.postMessage({ok:false});}};p.start();};",
                    "/service.js" => "importScripts('/dependency.js');addEventListener('install',e=>e.waitUntil(skipWaiting()));addEventListener('activate',e=>e.waitUntil(clients.claim()));addEventListener('message',e=>e.waitUntil((async()=>{try{const r=await fetch('/payload');e.ports[0].postMessage({ok:r.ok&&await r.text()==='worker-ok'&&self.dependency});}catch{e.ports[0].postMessage({ok:false});}})()));",
                    "/dependency.js" => "self.dependency = true;",
                    "/payload" => "worker-ok",
                    _ => "<!doctype html><title>Worker isolation fixture</title>"
                };
                byte[] body = Encoding.UTF8.GetBytes(content);
                string type = path.EndsWith(".js", StringComparison.Ordinal) ? "application/javascript" : path == "/payload" ? "text/plain" : "text/html";
                byte[] header = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(header); await stream.WriteAsync(body);
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException or IOException or OperationCanceledException) { }
        }
        public void Dispose() { lifetime.Cancel(); listener.Stop(); lifetime.Dispose(); }
    }
}
