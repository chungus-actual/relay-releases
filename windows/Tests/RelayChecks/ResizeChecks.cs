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

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

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

    private static void CheckMaximizedContent(Window window, FrameworkElement browser, string name)
    {
        var work = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle).WorkingArea;
        System.IO.File.AppendAllText("artifacts/maximize-bounds.txt",
            $"{name}: work={work}, DPI={System.Windows.Media.VisualTreeHelper.GetDpi(window).PixelsPerInchX}, window={window.ActualWidth}x{window.ActualHeight}\n");
        foreach (var element in new[] { (FrameworkElement)window.Content, browser })
        {
            var topLeft = element.PointToScreen(new Point(0, 0));
            var bottomRight = element.PointToScreen(new Point(element.ActualWidth, element.ActualHeight));
            Check(topLeft.X >= work.Left - 1 && topLeft.Y >= work.Top - 1
                && bottomRight.X <= work.Right + 1 && bottomRight.Y <= work.Bottom + 1,
                $"{name} maximized {element.GetType().Name} stays inside work area: {topLeft} to {bottomRight}, work {work}");
        }
    }
    private async Task CheckNativeResize()
    {
        System.IO.File.WriteAllText("artifacts/maximize-bounds.txt", "");
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
        CheckMaximizedContent(popup, AccountViews(state).Single(v => v != state.View), "Popup");
        Check(ResizeHit(popup, new Point(popup.ActualWidth - 4, popup.ActualHeight - 4)) is not (>= 10 and <= 17), "Maximized popup does not offer resize");
        popup.WindowState = WindowState.Normal;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CheckResizeEdges(popup, "Restored popup");
        foreach (var monitor in System.Windows.Forms.Screen.AllScreens)
        {
            var work = monitor.WorkingArea;
            Check(SetWindowPos(new WindowInteropHelper(popup).Handle, IntPtr.Zero, work.Left + 20, work.Top + 20, 0, 0, 0x0015),
                "Move popup to the next monitor without changing its normal size");
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            for (int cycle = 0; cycle < 2; cycle++)
            {
                popup.WindowState = WindowState.Maximized;
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                CheckMaximizedContent(popup, AccountViews(state).Single(v => v != state.View), "Repeated popup " + monitor.DeviceName);
                popup.WindowState = WindowState.Normal;
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                CheckResizeEdges(popup, "Restored monitor popup");
            }
        }
        popup.Close();
        WindowState = WindowState.Maximized;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CheckMaximizedContent(this, state.View!, "Main window");
        Check(WindowFrame.Padding == new Thickness(0) && ResizeHit(this, new Point(ActualWidth - 4, ActualHeight - 4)) is not (>= 10 and <= 17), "Maximized main window reclaims the resize gutter");
        WindowState = WindowState.Normal;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CheckResizeEdges(this, "Restored main window");
    }
}
