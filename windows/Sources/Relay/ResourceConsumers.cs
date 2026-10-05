using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Relay;

public partial class MainWindow
{
    private static readonly ResourceLimits UsageLimits = ResourceLimits.ForMemory(NativeMemory.TotalPhysical);
    private static int UsageLevel(ResourceUsage usage) => Math.Max(ResourceLimits.CpuLevel(usage.CpuPercent), UsageLimits.MemoryLevel(usage.WorkingSet));

    private static string ProcessLabel(CoreWebView2ProcessKind kind) => kind switch
    {
        CoreWebView2ProcessKind.Browser => "Shared browser",
        CoreWebView2ProcessKind.Gpu => "Shared GPU",
        CoreWebView2ProcessKind.Renderer => "Unassigned renderer",
        _ => "Browser helpers"
    };

    private async Task AttributeResourceConsumers(Dictionary<int, string> labels)
    {
        if (environment is not { IsCompletedSuccessfully: true }) return;
        try
        {
            var processes = await environment.Result.GetProcessExtendedInfosAsync();
            var owners = new Dictionary<uint, string>();
            void AddOwner(CoreWebView2? core, string name)
            {
                try { if (core != null) owners[core.FrameId] = name; }
                catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
            }
            foreach (var service in services) AddOwner(service.Core, service.Definition.Name);
            foreach (var popup in popups)
                if (popup.Tag is ServiceState service && popup.Content is Border { Child: Grid layout })
                    foreach (var view in layout.Children.OfType<WebView2>()) AddOwner(ServiceState.TryCore(view), service.Definition.Name);
            foreach (var process in processes)
            {
                int id = process.ProcessInfo.ProcessId;
                if (!labels.ContainsKey(id)) continue;
                var names = new HashSet<string>();
                bool unassigned = false;
                foreach (var frame in process.AssociatedFrameInfos)
                {
                    var root = frame;
                    for (int depth = 0; depth < 64 && root.ParentFrameInfo is { } parent; depth++) root = parent;
                    if (owners.TryGetValue(root.FrameId, out var owner)) names.Add(owner);
                    else unassigned = true;
                }
                if (names.Count == 1 && !unassigned) labels[id] = names.Single();
                else if (names.Count > 0) labels[id] = "Shared services";
            }
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or NotImplementedException)
        {
            // Keep honest process-role labels if frame attribution is unavailable.
        }
    }

    private static string MemoryReading(long bytes) => bytes >= 1024L * 1024 * 1024
        ? (bytes / (1024d * 1024 * 1024)).ToString("0.00") + " GB"
        : (bytes / (1024d * 1024)).ToString("0") + " MB";

    private static string LeadingConsumer(ResourceUsage usage, IReadOnlyDictionary<int, string> labels, bool cpu)
    {
        var groups = usage.Processes.GroupBy(p => labels.TryGetValue(p.Id, out var label) ? label : "Unassigned process")
            .Select(group => new { Name = group.Key, Cpu = group.Sum(p => p.CpuPercent ?? 0), Memory = group.Sum(p => p.WorkingSet) });
        var top = cpu ? groups.OrderByDescending(g => g.Cpu).ThenBy(g => g.Name).FirstOrDefault()
            : groups.OrderByDescending(g => g.Memory).ThenBy(g => g.Name).FirstOrDefault();
        if (top == null) return "Unavailable";
        return top.Name + " · " + (usage.Partial ? "≈ " : "") + (cpu ? top.Cpu.ToString("0.0") + "%" : MemoryReading(top.Memory));
    }

    private void ShowResourceConsumers(ResourceUsage? usage, IReadOnlyDictionary<int, string>? labels = null)
    {
        TopCpuText.Visibility = TopMemoryText.Visibility = Visibility.Collapsed;
        if (usage == null || labels == null || !resourceTimer.IsEnabled) return;
        if (usage.CpuPercent >= ResourceLimits.CpuWarning)
        {
            TopCpuText.Text = "Top CPU: " + LeadingConsumer(usage, labels, true);
            TopCpuText.Visibility = Visibility.Visible;
        }
        if (usage.WorkingSet >= UsageLimits.MemoryWarning)
        {
            TopMemoryText.Text = "Top memory: " + LeadingConsumer(usage, labels, false);
            TopMemoryText.Visibility = Visibility.Visible;
        }
    }
}
