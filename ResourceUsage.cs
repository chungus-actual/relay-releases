using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;

namespace Relay;

internal sealed record ProcessUsage(int Id, long Started, long CpuTicks, long WorkingSet);
internal sealed record UsageSnapshot(long Timestamp, IReadOnlyDictionary<int, ProcessUsage> Processes, bool Partial);
internal sealed record ProcessResourceUsage(int Id, double? CpuPercent, long WorkingSet);
internal sealed record ResourceUsage(double? CpuPercent, long WorkingSet, int ProcessCount, bool Partial)
{
    internal IReadOnlyList<ProcessResourceUsage> Processes { get; init; } = [];
}

internal sealed class ResourceUsageSampler
{
    private UsageSnapshot? previous;
    internal void Reset() => previous = null;

    internal ResourceUsage Sample(IEnumerable<int> processIds, bool partial)
    {
        long timestamp = Stopwatch.GetTimestamp();
        var readings = new Dictionary<int, ProcessUsage>();
        foreach (int id in processIds.Distinct())
        {
            try
            {
                using var process = Process.GetProcessById(id);
                long memory = NativeMemory.PrivateResident(process, out bool approximate);
                partial |= approximate;
                readings[id] = new(id, process.StartTime.ToUniversalTime().Ticks, process.TotalProcessorTime.Ticks, memory);
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception or NotSupportedException)
            {
                // Processes can exit between discovery and sampling. Do not invent zero readings.
                partial = true;
            }
        }
        var current = new UsageSnapshot(timestamp, readings, partial);
        var usage = Calculate(current, previous, Environment.ProcessorCount);
        previous = current;
        return usage;
    }

    internal static ResourceUsage Calculate(UsageSnapshot current, UsageSnapshot? previous, int processors)
    {
        bool hasBaseline = previous != null && current.Timestamp > previous.Timestamp;
        double elapsed = hasBaseline ? (current.Timestamp - previous!.Timestamp) / (double)Stopwatch.Frequency : 0;
        var readings = new List<ProcessResourceUsage>();
        foreach (var item in current.Processes.Values)
        {
            double? processCpu = null;
            if (hasBaseline && previous!.Processes.TryGetValue(item.Id, out var old) && item.Started == old.Started)
                processCpu = Math.Clamp(Math.Max(0, item.CpuTicks - old.CpuTicks) / (double)TimeSpan.TicksPerSecond / elapsed / Math.Max(1, processors) * 100, 0, 100);
            readings.Add(new(item.Id, processCpu, item.WorkingSet));
        }
        double? cpu = hasBaseline ? Math.Clamp(readings.Sum(p => p.CpuPercent ?? 0), 0, 100) : null;
        return new(cpu, readings.Sum(p => p.WorkingSet), readings.Count, current.Partial) { Processes = readings };
    }
}
