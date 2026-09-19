using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Input;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private readonly DispatcherTimer resourceTimer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(2) };
    private readonly ResourceUsageSampler resourceSampler = new();
    private readonly ResourcePressure resourcePressure = new();
    private bool resourceSampling;
    private bool resourceBaselineNeeded = true;
    private int resourceGeneration;
    private ResourceUsage? lastResourceUsage;

    private void InitializeResourceMonitoring()
    {
        resourceTimer.Tick += async (_, _) => await SampleResourceUsage();
        IsVisibleChanged += (_, _) => UpdateResourceMonitoring();
    }

    private void UpdateResourceMonitoring()
    {
        if (quitting || !IsVisible || WindowState == WindowState.Minimized)
        {
            resourceTimer.Stop();
            resourceBaselineNeeded = true;
            resourcePressure.Reset();
            resourceGeneration++;
            SetResourceDisplay("…", "…");
            ShowResourceConsumers(null);
            UsageDetails.IsOpen = false;
            return;
        }
        if (resourceTimer.IsEnabled) return;
        resourceTimer.Start();
        _ = SampleResourceUsage();
    }

    private async Task SampleResourceUsage()
    {
        if (resourceSampling || quitting || !IsVisible || WindowState == WindowState.Minimized) return;
        resourceSampling = true;
        int generation = resourceGeneration;
        bool reset = resourceBaselineNeeded;
        resourceBaselineNeeded = false;
        try
        {
            var ids = new HashSet<int> { Environment.ProcessId };
            var labels = new Dictionary<int, string> { [Environment.ProcessId] = "Relay" };
            bool partial = false;
            void AddEnvironment(CoreWebView2Environment browser)
            {
                try { foreach (var process in browser.GetProcessInfos()) { ids.Add(process.ProcessId); labels[process.ProcessId] = ProcessLabel(process.Kind); } }
                catch (Exception ex) when (ex is COMException or InvalidOperationException) { partial = true; }
            }
            // WebView2 owns its process list. Never count unrelated Edge/WebView2 applications.
            if (environment is { IsCompletedSuccessfully: true }) AddEnvironment(environment.Result);
            foreach (var service in services)
            {
                try
                {
                    if (service.Core is { } core && !ids.Contains((int)core.BrowserProcessId)) AddEnvironment(core.Environment);
                }
                catch (Exception ex) when (ex is COMException or InvalidOperationException) { partial = true; }
            }
            var usage = await Task.Run(() =>
            {
                if (reset) resourceSampler.Reset();
                return resourceSampler.Sample(ids, partial);
            });
            if (quitting || generation != resourceGeneration) return;
            if (UsageLevel(usage) > 0) await AttributeResourceConsumers(labels);
            if (quitting || generation != resourceGeneration) return;
            lastResourceUsage = usage;
            resourcePressure.Observe(usage.CpuPercent);
            ShowResourceConsumers(usage, labels);
            var cpu = usage.ProcessCount == 0 ? "—" : usage.CpuPercent is { } percent ? percent.ToString("0.0") + "%" : "…";
            var ram = usage.ProcessCount == 0 ? "—" : MemoryReading(usage.WorkingSet);
            SetResourceDisplay((usage.Partial ? "≈ " : "") + cpu, (usage.Partial ? "≈ " : "") + ram);
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            resourceBaselineNeeded = true;
            lastResourceUsage = null;
            ShowResourceConsumers(null);
            SetResourceDisplay("—", "—");
        }
        finally { resourceSampling = false; }
    }

    private void SetResourceDisplay(string cpu, string ram)
    {
        CpuUsageDetail.Text = cpu;
        RamUsageDetail.Text = ram;
        RefreshUsageIndicator();
        System.Windows.Automation.AutomationProperties.SetName(UsageHover, "CPU " + cpu + ", memory " + ram);
    }

    private void RefreshUsageIndicator()
    {
        if (!resourceTimer.IsEnabled || lastResourceUsage is not { ProcessCount: > 0 } usage)
        {
            UsageIndicator.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "Muted");
            return;
        }
        int level = Math.Max(resourcePressure.CpuLevel, UsageLimits.MemoryLevel(usage.WorkingSet));
        string color = (level, darkTheme) switch
        {
            (2, true) => "#F08D95", (2, false) => "#B93244",
            (1, true) => "#E7C56A", (1, false) => "#946610",
            (_, true) => "#85DFC3", _ => "#217A59"
        };
        UsageIndicator.Stroke = ColorBrush(color);
    }

    private async Task CheckResourceSidebar(string output)
    {
        var before = new UsageSnapshot(0, new Dictionary<int, ProcessUsage> { [1] = new(1, 10, 0, 100), [2] = new(2, 20, TimeSpan.TicksPerSecond, 200) }, false);
        var after = new UsageSnapshot(2 * Stopwatch.Frequency, new Dictionary<int, ProcessUsage> { [1] = new(1, 10, TimeSpan.TicksPerSecond, 120), [2] = new(2, 20, 2 * TimeSpan.TicksPerSecond, 240), [3] = new(3, 30, 99 * TimeSpan.TicksPerSecond, 300) }, false);
        var measured = ResourceUsageSampler.Calculate(after, before, 2);
        Check(measured.CpuPercent == 50 && measured.WorkingSet == 660 && measured.ProcessCount == 3, "CPU normalizes across processors; new process lifetime CPU is excluded");
        Check(ResourceUsageSampler.Calculate(after, null, 2).CpuPercent == null, "First CPU sample waits for a baseline");
        var recycled = new UsageSnapshot(2 * Stopwatch.Frequency, new Dictionary<int, ProcessUsage> { [1] = new(1, 99, 90 * TimeSpan.TicksPerSecond, 100) }, false);
        Check(ResourceUsageSampler.Calculate(recycled, before, 2).CpuPercent == 0, "Exited and reused process IDs do not create CPU spikes");
        Check(measured.Processes.Single(p => p.Id == 3).CpuPercent == null, "New process lifetime CPU cannot win the top-consumer ranking");
        var ranked = new ResourceUsage(60, 2200L * 1024 * 1024, 3, false)
        {
            Processes = [new(1, 20, 400L * 1024 * 1024), new(2, 25, 500L * 1024 * 1024), new(3, 15, 1300L * 1024 * 1024)]
        };
        var rankedLabels = new Dictionary<int, string> { [1] = "Messenger", [2] = "Messenger", [3] = "Shared GPU" };
        Check(LeadingConsumer(ranked, rankedLabels, true) == "Messenger · 45.0%", "Top CPU groups a service's processes without duplication");
        Check(LeadingConsumer(ranked, rankedLabels, false).StartsWith("Shared GPU · "), "Memory ranking independently identifies shared browser work");
        Check(UsageLevel(new(null, UsageLimits.MemoryCritical, 1, false)) == 2, "Memory overrun is visible before the CPU baseline is ready");
        var probe = await Task.Run(() => new ResourceUsageSampler().Sample(new[] { Environment.ProcessId, Environment.ProcessId, int.MaxValue }, false));
        Check(probe.ProcessCount == 1 && probe.WorkingSet > 0 && probe.Partial, "Process sampling deduplicates IDs and tolerates process exit");
        await Until(() => !resourceSampling);
        await SampleResourceUsage();
        await Task.Delay(120);
        await Until(() => !resourceSampling);
        await SampleResourceUsage();
        Check(lastResourceUsage is { ProcessCount: > 1, WorkingSet: > 0, CpuPercent: >= 0 and <= 100 }, "Live usage includes the Relay host and its WebView2 processes");
        var attributed = environment!.Result.GetProcessInfos().ToDictionary(p => p.ProcessId, p => ProcessLabel(p.Kind));
        await AttributeResourceConsumers(attributed);
        Check(attributed.ContainsValue("Messenger") && attributed.ContainsValue("WhatsApp"), "Frame IDs identify separate services even on the same synthetic origin");
        var priorService = selected!;
        ShowActivity();
        Check(CpuUsageDetail.Text.EndsWith("%") && RamUsageDetail.Text.Length > 0, "Resource hover shows live CPU and memory");
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "resource-sidebar.png"));
        Width = 720; Height = 540;
        SidebarToggleClick(this, new RoutedEventArgs());
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(SidebarToggle.TransformToAncestor(this).Transform(new Point(0, SidebarToggle.ActualHeight)).Y <= SidebarUtilityItems.TransformToAncestor(this).Transform(new Point()).Y, "Collapse chevron stays above the extensible utility group");
        UsageHover.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left) { RoutedEvent = Mouse.MouseDownEvent });
        Check(!UsageHover.Focusable && !UsageDetails.IsOpen, "Resource icon is not focusable or click-activated");
        Check(UsageHover.ActualWidth <= 30 && ServiceRailScroll.ViewportHeight > 100, "Stats stay compact while the service list can scroll");
        await SelectService(priorService);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(WebHost.TransformToAncestor(WindowFrame).Transform(new Point(0, WebHost.ActualHeight)).Y >= WindowFrame.ActualHeight - WindowFrame.Padding.Bottom - 2, "Service content reaches the native resize edge without a footer");
        var mutePeer = new ToggleButtonAutomationPeer(QuietButton);
        var muteProvider = (IToggleProvider)mutePeer.GetPattern(PatternInterface.Toggle);
        Check(muteProvider.ToggleState == System.Windows.Automation.ToggleState.Off, "Mute starts off");
        muteProvider.Toggle();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(settings.Quiet && Settings.Load().Quiet && muteProvider.ToggleState == System.Windows.Automation.ToggleState.On, "Mute click persists state and exposes an accessible toggle");
        Check(((FrameworkElement)QuietButton.Template.FindName("Slash", QuietButton)).Visibility == Visibility.Visible, "Muted bell has a visible slash");
        Capture(Path.Combine(output, "sidebar-muted-dark.png"));
        UsageDetails.PlacementTarget = UsageHover; UsageDetails.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(UsageDetails.IsOpen && CpuUsageDetail.Text.Contains("%") && ((Grid)UsageDetails.Content).Children.Count == 6, "Resource hover contains only CPU and memory labels/readings");
        CaptureElement(UsageDetails, Path.Combine(output, "resource-details-dark.png"));
        var liveUsage = lastResourceUsage;
        lastResourceUsage = ranked;
        SetResourceDisplay("60.0%", "2.15 GB");
        ShowResourceConsumers(ranked, rankedLabels);
        Check(TopCpuText.Visibility == Visibility.Visible && TopMemoryText.Visibility == Visibility.Visible, "Overrun shows the top consumer for each exceeded metric");
        CaptureElement(UsageDetails, Path.Combine(output, "resource-overrun.png"));
        lastResourceUsage = liveUsage;
        ShowResourceConsumers(new ResourceUsage(1, 100, 1, false), rankedLabels);
        Check(TopCpuText.Visibility == Visibility.Collapsed && TopMemoryText.Visibility == Visibility.Collapsed, "Top-consumer rows disappear after recovery");
        await SampleResourceUsage();
        UsageDetails.IsOpen = false;
        settings.Appearance = "Light"; ApplyTheme();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Capture(Path.Combine(output, "sidebar-muted-light.png"));
        UsageDetails.PlacementTarget = UsageHover; UsageDetails.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CaptureElement(UsageDetails, Path.Combine(output, "resource-details-light.png"));
        UsageDetails.IsOpen = false;
        muteProvider.Toggle();
        Check(!settings.Quiet && !Settings.Load().Quiet && QuietButton.IsChecked == false, "Second mute click restores notifications and clears the toggle");
        Check(((FrameworkElement)QuietButton.Template.FindName("Slash", QuietButton)).Visibility == Visibility.Collapsed, "Unmuted bell clears its slash");
        settings.Appearance = "Dark"; ApplyTheme();
        SidebarToggleClick(this, new RoutedEventArgs());
        Hide();
        Check(!resourceTimer.IsEnabled && resourceBaselineNeeded, "Usage sampler pauses when hidden");
        ShowWindow();
        Check(resourceTimer.IsEnabled, "Usage sampler resumes when shown");
        Width = 1280; Height = 820;
        await SelectService(priorService);
    }
}
