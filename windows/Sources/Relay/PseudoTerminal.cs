using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Relay;

// One ConPTY and shell per Relay account. No TCP listener or service-page host objects.
internal sealed class PseudoTerminal : IDisposable
{
    private IntPtr console;
    private readonly object gate = new();
    private FileStream? input, output;
    private Process? process;
    private SafeFileHandle? job;
    private int disposed;
    private readonly Channel<(string? Input, short Columns, short Rows)> writes = Channel.CreateBounded<(string? Input, short Columns, short Rows)>(new BoundedChannelOptions(128) { SingleReader = true, SingleWriter = false });
    internal int ProcessId => process?.Id ?? 0;
    internal bool Exited => process == null || process.HasExited;

    internal PseudoTerminal(short columns, short rows, Func<string, Task> receive, Action exited)
    {
        IntPtr inputRead = IntPtr.Zero, inputWrite = IntPtr.Zero, outputRead = IntPtr.Zero, outputWrite = IntPtr.Zero, attributes = IntPtr.Zero;
        try {
            Win32(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0));
            Win32(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0));
            Marshal.ThrowExceptionForHR(CreatePseudoConsole(new Coord(columns, rows), inputRead, outputWrite, 0, out console));
            CloseHandle(inputRead); inputRead = IntPtr.Zero; CloseHandle(outputWrite); outputWrite = IntPtr.Zero;
            nuint bytes = 0; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
            attributes = Marshal.AllocHGlobal(checked((int)bytes));
            Win32(InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes));
            Win32(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));
            var startup = new StartupInfoEx { StartupInfo = new StartupInfo { cb = Marshal.SizeOf<StartupInfoEx>() }, AttributeList = attributes };
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            Win32(CreateProcess(shell, new StringBuilder("\"" + shell + "\" -NoLogo -NoProfile"), IntPtr.Zero, IntPtr.Zero, false, 0x00080004,
                IntPtr.Zero, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ref startup, out var info));
            try {
                job = new SafeFileHandle(CreateJobObject(IntPtr.Zero, null), true);
                Win32(!job.IsInvalid);
                var limits = new JobLimits { Basic = new BasicJobLimits { Flags = 0x2000 } };
                Win32(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>()));
                Win32(AssignProcessToJobObject(job, info.Process));
                if (ResumeThread(info.Thread) == uint.MaxValue) Win32(false);
                process = Process.GetProcessById(info.ProcessId);
            } catch { TerminateProcess(info.Process, 1); throw; }
            finally { CloseHandle(info.Thread); CloseHandle(info.Process); }
            input = new FileStream(new SafeFileHandle(inputWrite, true), FileAccess.Write, 4096, false); inputWrite = IntPtr.Zero;
            output = new FileStream(new SafeFileHandle(outputRead, true), FileAccess.Read, 4096, false); outputRead = IntPtr.Zero;
            var outputStream = output;
            _ = Task.Run(async () => {
                try {
                    using var reader = new StreamReader(outputStream, new UTF8Encoding(false), false, 4096, leaveOpen: true);
                    var buffer = new char[4096]; int count;
                    while ((count = await reader.ReadAsync(buffer.AsMemory())) > 0) await receive(new string(buffer, 0, count));
                } catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException) { }
                finally { if (Volatile.Read(ref disposed) == 0) exited(); }
            });
            _ = Task.Run(async () => {
                try {
                    await foreach (var command in writes.Reader.ReadAllAsync()) {
                        lock (gate) {
                            if (disposed != 0) return;
                            if (command.Input is { } text) { var data = Encoding.UTF8.GetBytes(text); input?.Write(data); input?.Flush(); }
                            else if (console != IntPtr.Zero) Marshal.ThrowExceptionForHR(ResizePseudoConsole(console, new Coord(command.Columns, command.Rows)));
                        }
                    }
                } catch (Exception ex) when (ex is IOException or ObjectDisposedException or COMException) { }
            });
            var child = process;
            _ = Task.Run(async () => {
                try { await child.WaitForExitAsync(); if (Volatile.Read(ref disposed) == 0) { exited(); Dispose(); } }
                catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException or Win32Exception) { }
            });
        } catch { Dispose(); throw; }
        finally {
            if (attributes != IntPtr.Zero) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
            foreach (var handle in new[] { inputRead, inputWrite, outputRead, outputWrite }) if (handle != IntPtr.Zero) CloseHandle(handle);
        }
    }
    internal bool Write(string text) => disposed == 0 && text.Length <= 65536 && writes.Writer.TryWrite((text, 0, 0));
    internal void Resize(short columns, short rows) {
        if (disposed == 0) writes.Writer.TryWrite((null, columns, rows));
    }
    public void Dispose() {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        writes.Writer.TryComplete();
        job?.Dispose(); job = null; // Closing the job kills only this session, including descendants, even during app shutdown.
        var child = process; process = null;
        // ClosePseudoConsole may wait for output to drain; never block the UI/read loop.
        _ = Task.Run(() => {
            try { if (child is { HasExited: false }) child.Kill(entireProcessTree: true); } catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { }
            lock (gate) {
                input?.Dispose(); input = null;
                if (console != IntPtr.Zero) { ClosePseudoConsole(console); console = IntPtr.Zero; }
            }
            output?.Dispose(); output = null; child?.Dispose();
        });
    }
    [StructLayout(LayoutKind.Sequential)] private struct BasicJobLimits {
        public long ProcessTime, JobTime; public uint Flags; public nuint MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses; public nuint Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] private struct JobLimits {
        public BasicJobLimits Basic; public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref JobLimits limits, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
    private static void Win32(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    [StructLayout(LayoutKind.Sequential)] private readonly struct Coord(short x, short y) { public readonly short X = x, Y = y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo {
        public int cb; public string? Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XChars, YChars, FillAttribute, Flags;
        public short ShowWindow, ReservedSize; public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr AttributeList; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr attributes, uint size);
    [DllImport("kernel32.dll")] private static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] private static extern int ResizePseudoConsole(IntPtr console, Coord size);
    [DllImport("kernel32.dll")] private static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
