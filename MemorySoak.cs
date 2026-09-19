using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private sealed record SoakReading(double Seconds, string Phase, int Cycle, long ManagedBytes, long HostPrivateBytes, long HostWorkingBytes, long BrowserPrivateBytes, long BrowserWorkingBytes, int HostHandles, int BrowserProcesses, int Views, int Popups, int Gen2Collections, int UnavailableProcesses);

    private async Task MemorySoak()
    {
        string output = Path.Combine(Environment.CurrentDirectory, "artifacts", "memory-soak", DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(output);
        File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "artifacts", "latest-memory-soak.txt"), output);
        var rows = new List<SoakReading>();
        var retiredViews = new List<WeakReference>();
        var retiredPopups = new List<WeakReference>();
        var clock = Stopwatch.StartNew();
        int cycles = 0;
        async Task<SoakReading> Record(string phase)
        {
            var row = await ReadSoakUsage(clock.Elapsed.TotalSeconds, phase, cycles);
            rows.Add(row);
            File.AppendAllText(Path.Combine(output, "samples.jsonl"), JsonSerializer.Serialize(row) + Environment.NewLine);
            File.WriteAllText(Path.Combine(output, "progress.json"), JsonSerializer.Serialize(row));
            return row;
        }
        try
        {
            CheckRollingLog();
            foreach (var state in services)
            {
                state.Options.KeepLive = true;
                await SelectService(state);
                await Until(() => state.Unread == 3);
            }
            ShowActivity();
            clock.Restart();
            while (clock.Elapsed.TotalSeconds < App.SoakSeconds * 0.2)
            {
                await Record("warmup");
                await Task.Delay(5000);
            }
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            CollectForSoak();
            var baseline = await Record("baseline-collected");
            while (clock.Elapsed.TotalSeconds < App.SoakSeconds * 0.8)
            {
                await SoakCycle(cycles, retiredViews, retiredPopups);
                cycles++;
                Check(WebHost.Children.Count == services.Count && popups.Count == 0 && starts.Count == 0, "Soak lifecycle remains bounded after cycle " + cycles);
                await Record("churn");
                await Task.Delay(4000);
            }
            ShowActivity();
            while (clock.Elapsed.TotalSeconds < App.SoakSeconds)
            {
                await Record("recovery");
                await Task.Delay(5000);
            }
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            CollectForSoak();
            var final = await Record("recovery-collected");
            foreach (var state in services) retiredViews.Add(RetireForSoak(state));
            ShowActivity();
            await Task.Delay(3000);
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            CollectForSoak();
            var disconnected = await Record("disconnected-collected");
            int viewsAlive = retiredViews.Count(reference => reference.IsAlive);
            int popupsAlive = retiredPopups.Count(reference => reference.IsAlive);
            var summary = new { DurationSeconds = clock.Elapsed.TotalSeconds, Cycles = cycles, Baseline = baseline, Final = final, Disconnected = disconnected, RetiredViews = retiredViews.Count, RetiredViewsAlive = viewsAlive, RetiredPopups = retiredPopups.Count, RetiredPopupsAlive = popupsAlive, DataPath = App.DataPath };
            File.WriteAllText(Path.Combine(output, "summary.json"), JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true }));
            Check(WebHost.Children.Count == 0 && popups.Count == 0 && starts.Count == 0, "Soak teardown releases all browser controls");
            Check(viewsAlive == 0 && popupsAlive == 0, "Disposed browser controls and popups are collectible: " + viewsAlive + " views, " + popupsAlive + " popups retained");
            Check(!File.Exists(Path.Combine(App.DataPath, "errors.log")), "No runtime errors during soak");
            File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: lifecycle bounds, disposed-control collectibility, and no runtime errors. Synthetic workload; memory trends require interpretation and do not establish signed-in site behavior.\n");
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(output, "result.txt"), "FAIL: " + ex);
            Environment.ExitCode = 1;
        }
        finally { quitting = true; Close(); }
    }

    private async Task SoakCycle(int cycle, List<WeakReference> retiredViews, List<WeakReference> retiredPopups)
    {
        var state = services[cycle % services.Count];
        await SelectService(state);
        if (cycle % 3 == 0)
        {
            ShowSettings();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            ShowActivity();
            SidebarToggleClick(this, new RoutedEventArgs());
            SidebarToggleClick(this, new RoutedEventArgs());
            await SelectService(state);
        }
        if (cycle % 4 == 0)
        {
            await state.View!.CoreWebView2.ExecuteScriptAsync("window.soakPopup = window.open('https://relay.test/popup', 'relay-soak')");
            await Until(() => popups.Count == 1);
            await Task.Delay(250);
            RetirePopupForSoak(retiredPopups);
            Check(popups.Count == 0, "Soak popup closes");
        }
        retiredViews.Add(RetireForSoak(state));
        await SelectService(state);
        await Until(() => state.Unread == 3);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private WeakReference RetireForSoak(ServiceState state)
    {
        var reference = new WeakReference(state.View!);
        DisconnectService(state);
        return reference;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private void RetirePopupForSoak(List<WeakReference> retired)
    {
        var popup = popups.Single();
        retired.Add(new WeakReference(popup));
        popup.Close();
    }

    private static void CollectForSoak()
    {
        // Explicit collection is diagnostic only. Normal Relay operation never forces GC.
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
    }

    private async Task<SoakReading> ReadSoakUsage(double seconds, string phase, int cycle)
    {
        int[] browserIds = [];
        if (environment is { IsCompletedSuccessfully: true })
        {
            try { browserIds = environment.Result.GetProcessInfos().Select(p => p.ProcessId).Where(id => id != Environment.ProcessId).Distinct().ToArray(); }
            catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        }
        int views = WebHost.Children.Count, popupCount = popups.Count;
        return await Task.Run(() =>
        {
            using var host = Process.GetCurrentProcess();
            long browserPrivate = 0, browserWorking = 0;
            int count = 0, unavailable = 0;
            foreach (int id in browserIds)
            {
                try
                {
                    using var process = Process.GetProcessById(id);
                    browserPrivate += process.PrivateMemorySize64;
                    browserWorking += process.WorkingSet64;
                    count++;
                }
                catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { unavailable++; }
            }
            return new SoakReading(seconds, phase, cycle, GC.GetTotalMemory(false), host.PrivateMemorySize64, host.WorkingSet64, browserPrivate, browserWorking, host.HandleCount, count, views, popupCount, GC.CollectionCount(2), unavailable);
        });
    }
}
