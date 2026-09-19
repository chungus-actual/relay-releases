using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Relay;

public partial class MainWindow
{
    private static void CheckRollingLog()
    {
        string directory = Path.Combine(App.DataPath, "log-checks");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "errors.log");
        var log = new RollingLog(path, 512, 3);
        for (int i = 0; i < 80; i++) Check(log.Write("entry-" + i + " " + new string('x', 80)), "Log write succeeds");
        Check(Directory.GetFiles(directory).Length == 4 && Directory.GetFiles(directory).All(p => new FileInfo(p).Length <= 512), "Log retention caps current plus three archives");
        Check(File.ReadAllText(path).Contains("entry-79") && !Directory.GetFiles(directory).Any(p => File.ReadAllText(p).Contains("entry-0 ")), "Rotation retains newest entries and expires old ones");
        File.WriteAllText(path, new string('a', 4096) + "\nlegacy-tail\n");
        Check(log.Write("after-upgrade") && new FileInfo(path + ".1").Length <= 512 && File.ReadAllText(path + ".1").Contains("legacy-tail"), "Oversized legacy log is bounded while retaining its tail");
        Check(log.Write(new string('界', 5000)) && File.ReadAllText(path).Contains("[truncated]") && new FileInfo(path).Length <= 512, "Oversized Unicode entries are bounded");
        Parallel.For(0, 50, i => Check(log.Write("parallel-" + i), "Concurrent log write"));
        Check(Directory.GetFiles(directory).All(p => new FileInfo(p).Length <= 512), "Concurrent rotation respects limits");
        using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            Check(!log.Write("blocked"), "Locked log does not throw inside error handling");
        Check(log.Write("recovered"), "Logging recovers after a transient lock");
    }
}
