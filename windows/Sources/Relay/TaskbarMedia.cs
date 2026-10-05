using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Shell;
using Microsoft.Win32;

namespace Relay;

public partial class MainWindow
{
    private readonly ThumbButtonInfo taskbarPrevious = new() { Description = "Previous track", DismissWhenClicked = false };
    private readonly ThumbButtonInfo taskbarPlay = new() { Description = "Play", DismissWhenClicked = false };
    private readonly ThumbButtonInfo taskbarNext = new() { Description = "Next track", DismissWhenClicked = false };
    private bool taskbarMediaBusy;
    private Color? taskbarIconColor;
    private ImageSource? taskbarPlayImage, taskbarPauseImage;

    private void InitializeTaskbarMedia()
    {
        TaskbarItemInfo = new TaskbarItemInfo();
        foreach (var button in new[] { taskbarPrevious, taskbarPlay, taskbarNext })
        {
            button.Visibility = Visibility.Collapsed;
            TaskbarItemInfo.ThumbButtonInfos.Add(button);
        }
        taskbarPrevious.Click += async (_, _) => await TaskbarMediaAction("previoustrack");
        taskbarPlay.Click += async (_, _) => await TaskbarMediaAction(mediaPlaying ? "pause" : "play");
        taskbarNext.Click += async (_, _) => await TaskbarMediaAction("nexttrack");
        RefreshTaskbarMedia();
    }

    private void RefreshTaskbarMedia()
    {
        if (TaskbarItemInfo == null) return;
        // The thumbnail belongs to Windows' shell theme, which may differ from Relay's.
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        bool light = key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        var color = SystemParameters.HighContrast ? SystemColors.WindowTextColor : light ? Colors.Black : Colors.White;
        if (taskbarIconColor != color)
        {
            taskbarIconColor = color;
            ImageSource Icon(string path)
            {
                var brush = new SolidColorBrush(color); brush.Freeze();
                var image = new DrawingImage(new GeometryDrawing(brush, null, Geometry.Parse(path))); image.Freeze(); return image;
            }
            taskbarPrevious.ImageSource = Icon("M2,2 L4,2 4,14 2,14 Z M14,2 L14,14 5,8 Z");
            taskbarNext.ImageSource = Icon("M12,2 L14,2 14,14 12,14 Z M2,2 L11,8 2,14 Z");
            taskbarPlayImage = Icon("M3,2 L14,8 3,14 Z");
            taskbarPauseImage = Icon("M3,2 L6,2 6,14 3,14 Z M10,2 L13,2 13,14 10,14 Z");
        }
        bool available = !quitting && mediaCore != null && mediaService?.Options.Enabled == true && MediaControls.Visibility == Visibility.Visible;
        foreach (var button in new[] { taskbarPrevious, taskbarPlay, taskbarNext }) button.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        taskbarPrevious.IsEnabled = available && !taskbarMediaBusy && MediaPreviousButton.IsEnabled;
        taskbarNext.IsEnabled = available && !taskbarMediaBusy && MediaNextButton.IsEnabled;
        taskbarPlay.IsEnabled = available && !taskbarMediaBusy;
        taskbarPlay.Description = mediaPlaying ? "Pause" : "Play";
        taskbarPlay.ImageSource = mediaPlaying ? taskbarPauseImage : taskbarPlayImage;
        TaskbarItemInfo.Description = available ? mediaService!.Definition.Name + " · " + MediaTitle.Text : "Relay";
    }

    private async System.Threading.Tasks.Task TaskbarMediaAction(string action)
    {
        if (taskbarMediaBusy || mediaCore == null || mediaService == null || !mediaService.Options.Enabled ||
            MediaControls.Visibility != Visibility.Visible || (action == "previoustrack" && !MediaPreviousButton.IsEnabled) ||
            (action == "nexttrack" && !MediaNextButton.IsEnabled)) return;
        taskbarMediaBusy = true; RefreshTaskbarMedia();
        try { await MediaAction(action); }
        finally { taskbarMediaBusy = false; RefreshTaskbarMedia(); }
    }
}
