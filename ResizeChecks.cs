using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ResizePoint { public int X, Y; }
    [DllImport("user32.dll")]
    private static extern IntPtr ChildWindowFromPointEx(IntPtr parent, ResizePoint point, uint flags);
    [DllImport("user32.dll")]
    private static extern bool ScreenToClient(IntPtr window, ref ResizePoint point);

    private static int ResizeHit(Window window, Point point)
    {
        var screen = window.PointToScreen(point);
        int packed = ((int)screen.Y << 16) | ((int)screen.X & 0xffff);
        return (int)SendMessage(new WindowInteropHelper(window).Handle, 0x0084, IntPtr.Zero, new IntPtr(packed));
    }

    private static bool NativeChildAt(Window window, Point point)
    {
        var handle = new WindowInteropHelper(window).Handle;
        var screen = window.PointToScreen(point);
        var client = new ResizePoint { X = (int)screen.X, Y = (int)screen.Y };
        Check(ScreenToClient(handle, ref client), "Resize probe converts screen coordinates");
        var target = ChildWindowFromPointEx(handle, client, 1); // Skip hidden webviews.
        return target != IntPtr.Zero && target != handle;
    }

    private static void CheckResizeEdges(Window window, string name)
    {
        double w = window.ActualWidth, h = window.ActualHeight;
        foreach (double inset in new[] { 3d, 4d, 5d })
        {
            foreach (var corner in new[] { (new Point(inset, inset), 13), (new Point(w - inset, inset), 14),
                (new Point(inset, h - inset), 16), (new Point(w - inset, h - inset), 17) })
            {
                Check(ResizeHit(window, corner.Item1) == corner.Item2, name + " native diagonal resize at " + corner.Item2 + " / " + inset);
                Check(!NativeChildAt(window, corner.Item1), name + " browser does not cover a resize corner");
            }
        }
        foreach (var edge in new[] { (new Point(3, h / 2), 10), (new Point(w - 3, h / 2), 11),
            (new Point(w / 2, 3), 12), (new Point(w / 2, h - 3), 15) })
        {
            Check(ResizeHit(window, edge.Item1) == edge.Item2 && !NativeChildAt(window, edge.Item1), name + " native edge remains available");
        }
    }

    private async Task CheckNativeResize()
    {
        var state = services[0];
        await SelectService(state);
        await Until(() => state.Status == "Live");
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(NativeChildAt(this, new Point(ActualWidth / 2, ActualHeight / 2)), "Resize regression runs with a real embedded browser");
        CheckResizeEdges(this, "Main window");
        var closeCenter = CloseButton.TransformToAncestor(this).Transform(new Point(CloseButton.ActualWidth / 2, CloseButton.ActualHeight / 2));
        Check(ResizeHit(this, closeCenter) == 1, "Close button remains clickable inside the resize border");
        await state.Core!.ExecuteScriptAsync("window.open('https://relay.test/resize')");
        await Until(() => AccountViews(state).Count(v => ServiceState.TryCore(v)?.Source.Contains("/resize") == true) == 1);
        var popup = popups.Single(p => p.Tag == state);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(NativeChildAt(popup, new Point(popup.ActualWidth / 2, popup.ActualHeight / 2)), "Popup regression runs over native browser content");
        CheckResizeEdges(popup, "Popup");
        popup.WindowState = WindowState.Maximized;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(ResizeHit(popup, new Point(popup.ActualWidth - 4, popup.ActualHeight - 4)) is not (>= 10 and <= 17), "Maximized popup does not offer resize");
        popup.WindowState = WindowState.Normal;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CheckResizeEdges(popup, "Restored popup");
        popup.Close();
        WindowState = WindowState.Maximized;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(WindowFrame.Padding == new Thickness(0) && ResizeHit(this, new Point(ActualWidth - 4, ActualHeight - 4)) is not (>= 10 and <= 17), "Maximized main window reclaims the resize gutter");
        WindowState = WindowState.Normal;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CheckResizeEdges(this, "Restored main window");
    }
}
