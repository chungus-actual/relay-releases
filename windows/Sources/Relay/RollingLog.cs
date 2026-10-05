using System;
using System.IO;
using System.Text;

namespace Relay;

internal sealed class RollingLog
{
    private readonly object gate = new();
    private readonly string path;
    private readonly int limit;
    private readonly int archives;
    internal RollingLog(string path, int limit = 1024 * 1024, int archives = 3)
    {
        if (limit < 256 || archives < 1 || archives > 20) throw new ArgumentOutOfRangeException(nameof(limit));
        this.path = path; this.limit = limit; this.archives = archives;
    }

    internal bool Write(string message)
    {
        lock (gate)
        {
            try
            {
                // Bound a single exception as well as the complete file (including multibyte text).
                int maxChars = Math.Min(16000, (limit - 128) / 4);
                if (message.Length > maxChars) message = message[..maxChars] + " [truncated]";
                byte[] entry = Encoding.UTF8.GetBytes(DateTimeOffset.Now.ToString("O") + " " + message + Environment.NewLine);
                if (File.Exists(path) && new FileInfo(path).Length + entry.Length > limit)
                {
                    File.Delete(path + "." + archives);
                    for (int i = archives - 1; i >= 1; i--)
                        if (File.Exists(path + "." + i)) MoveBounded(path + "." + i, path + "." + (i + 1));
                    MoveBounded(path, path + ".1");
                }
                using var output = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                output.Write(entry);
                return true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                // Logging failure must not recursively crash the exception handler.
                return false;
            }
        }
    }

    private void MoveBounded(string source, string destination)
    {
        // Older versions allowed unbounded logs. Retain only their newest bounded tail.
        using (var file = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
            if (file.Length > limit)
            {
                var tail = new byte[limit];
                file.Position = file.Length - limit;
                file.ReadExactly(tail);
                int start = Array.IndexOf(tail, (byte)'\n');
                start = start >= 0 && start < tail.Length - 1 ? start + 1 : 0;
                while (start < tail.Length && (tail[start] & 0xC0) == 0x80) start++;
                file.Position = 0;
                file.Write(tail, start, tail.Length - start);
                file.SetLength(tail.Length - start);
            }
        }
        File.Move(source, destination, true);
    }
}
