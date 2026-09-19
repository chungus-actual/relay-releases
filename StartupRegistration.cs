using System;
using System.IO;
using Microsoft.Win32;

namespace Relay;

internal static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Relay";
    internal static string BuildCommand(string executable, string assembly)
    {
        if (!Path.IsPathFullyQualified(executable) || executable.Contains('"') || assembly.Contains('"'))
            throw new InvalidOperationException("Relay needs an absolute executable path for startup.");
        var command = "\"" + executable + "\"";
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            command += " \"" + assembly + "\"";
        command += " --startup";
        if (command.Length > 260) throw new InvalidOperationException("Move Relay to a shorter folder path before enabling launch at login.");
        return command;
    }
    internal static string Command => BuildCommand(Environment.ProcessPath ?? throw new InvalidOperationException("Could not locate Relay."), typeof(App).Assembly.Location);
    internal static string? ReadCommand()
    {
        // Smoke runs use an isolated file, never the user's real startup registration.
        if (App.SmokeTest) { var path = Path.Combine(App.DataPath, "startup-test.txt"); return File.Exists(path) ? File.ReadAllText(path) : null; }
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(ValueName) as string;
    }
    internal static bool IsEnabled => string.Equals(ReadCommand(), Command, StringComparison.OrdinalIgnoreCase);
    internal static void SetEnabled(bool enabled)
    {
        if (App.SmokeTest)
        {
            var path = Path.Combine(App.DataPath, "startup-test.txt");
            if (enabled) File.WriteAllText(path, Command); else if (File.Exists(path)) File.Delete(path);
            return;
        }
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (enabled) key.SetValue(ValueName, Command, RegistryValueKind.String);
        else key.DeleteValue(ValueName, false);
    }
}
