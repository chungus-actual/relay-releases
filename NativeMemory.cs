using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Relay;

internal static class NativeMemory
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Counters
    {
        public uint Size, PageFaultCount;
        public nuint PeakWorkingSet, WorkingSet, QuotaPeakPagedPool, QuotaPagedPool, QuotaPeakNonPagedPool, QuotaNonPagedPool, PageFile, PeakPageFile, PrivateUsage, PrivateWorkingSet;
        public ulong SharedCommit;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool K32GetProcessMemoryInfo(SafeProcessHandle process, ref Counters counters, uint size);

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

    internal static long TotalPhysical
    {
        get
        {
            var status = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            return GlobalMemoryStatusEx(ref status) ? (long)status.TotalPhysical : 0;
        }
    }

    internal static long PrivateResident(Process process, out bool approximate)
    {
        var counters = new Counters { Size = (uint)Marshal.SizeOf<Counters>() };
        if (K32GetProcessMemoryInfo(process.SafeHandle, ref counters, counters.Size))
        {
            approximate = false;
            return (long)counters.PrivateWorkingSet;
        }
        // Older Windows builds do not expose the EX2 structure.
        approximate = true;
        return process.WorkingSet64;
    }
}

internal sealed record ResourceLimits(long MemoryWarning, long MemoryCritical)
{
    internal const double CpuWarning = 20, CpuCritical = 50;
    internal static ResourceLimits ForMemory(long total)
    {
        const long gib = 1024L * 1024 * 1024;
        return total > 0 ? new(Math.Min(2 * gib, Math.Max(gib / 2, total / 10)), Math.Min(4 * gib, Math.Max(gib, total / 5)))
            : new(2 * gib, 4 * gib);
    }
    internal int MemoryLevel(long bytes) => bytes >= MemoryCritical ? 2 : bytes >= MemoryWarning ? 1 : 0;
    internal static int CpuLevel(double? percent) => percent >= CpuCritical ? 2 : percent >= CpuWarning ? 1 : 0;
}

internal sealed class ResourcePressure
{
    private int candidate, samples;
    internal int CpuLevel { get; private set; }
    internal void Reset() { candidate = samples = CpuLevel = 0; }
    internal void Observe(double? cpu)
    {
        int level = ResourceLimits.CpuLevel(cpu);
        if (level <= CpuLevel) { CpuLevel = level; candidate = level; samples = 0; return; }
        if (candidate != level) { candidate = level; samples = 0; }
        if (++samples >= 3) { CpuLevel = level; samples = 0; }
    }
}
