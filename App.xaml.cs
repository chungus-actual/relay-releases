using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;

namespace Relay;

public partial class App : Application
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    private Mutex? instance;
    internal static string DisplayVersion => typeof(App).Assembly.GetName().Version?.ToString(3) ?? "dev";
    internal static bool SmokeTest;
    internal static bool SoakTest;
    internal static int SoakSeconds = 600;
    private static RollingLog? errorLog;
    internal static void Log(Exception ex) => errorLog?.Write(ex.ToString());
    internal static string DataPath = "";

    protected override void OnStartup(StartupEventArgs e)
    {
        SetCurrentProcessExplicitAppUserModelID("Relay.Personal");
        base.OnStartup(e);
        SoakTest = e.Args.Contains("--soak-test");
        SmokeTest = SoakTest || e.Args.Contains("--smoke-test");
        int durationIndex = Array.IndexOf(e.Args, "--soak-seconds");
        if (SoakTest && durationIndex >= 0 && durationIndex + 1 < e.Args.Length && int.TryParse(e.Args[durationIndex + 1], out int duration)) SoakSeconds = Math.Clamp(duration, 60, 86400);
        DataPath = SmokeTest
            ? Path.Combine(Environment.CurrentDirectory, ".test-data", Guid.NewGuid().ToString("N"))
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Relay");
        Directory.CreateDirectory(DataPath);
        errorLog = new RollingLog(Path.Combine(DataPath, "errors.log"));
        instance = new Mutex(true, SmokeTest ? "Relay-Smoke-" + Guid.NewGuid() : "Local\\Relay.Personal", out bool first);
        if (!first) { MessageBox.Show("Relay is already running. Open it from the system tray.", "Relay"); Shutdown(); return; }
        DispatcherUnhandledException += (_, args) =>
        {
            Log(args.Exception);
            if (SmokeTest) { Directory.CreateDirectory("artifacts"); File.WriteAllText(Path.Combine("artifacts", "smoke-test.txt"), "FAIL: " + args.Exception); Shutdown(1); return; }
            MessageBox.Show(args.Exception.Message, "Relay", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
        var window = new MainWindow { ShowActivated = !SmokeTest };
        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e) { instance?.Dispose(); base.OnExit(e); }
}
