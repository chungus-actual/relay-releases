using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private void InitializeWindowThemes()
    {
        EventManager.RegisterClassHandler(typeof(Window), LoadedEvent, new RoutedEventHandler((sender, _) => {
            if (sender is Window window) ApplyWindowTheme(window);
        }));
    }
    private void ApplyWindowTheme(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero || window.WindowStyle == WindowStyle.None) return;
        int dark = darkTheme ? 1 : 0;
        DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
        int ColorValue(string resource) { var color = ((SolidColorBrush)Brush(resource)).Color; return color.R | color.G << 8 | color.B << 16; }
        int caption = ColorValue("Panel"), text = ColorValue("Ink"), border = ColorValue("Line");
        // Windows 11 supports these palette colors; older Windows keeps its native border.
        DwmSetWindowAttribute(handle, 35, ref caption, sizeof(int));
        DwmSetWindowAttribute(handle, 36, ref text, sizeof(int));
        DwmSetWindowAttribute(handle, 34, ref border, sizeof(int));
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);
}
