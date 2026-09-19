using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Relay;

public partial class MainWindow
{
    private Slider CreateZoomSlider(ServiceState state)
    {
        var slider = new Slider { Minimum = 50, Maximum = 200, Value = state.Options.Zoom * 100, TickFrequency = 5,
            IsSnapToTickEnabled = true, Width = 180, Margin = new Thickness(4, 12, 4, 8), ToolTip = "Zoom" };
        slider.Style = (Style)FindResource("ZoomSlider");
        System.Windows.Automation.AutomationProperties.SetName(slider, "Service zoom");
        slider.ValueChanged += (_, _) =>
        {
            state.Options.Zoom = Math.Round(slider.Value / 100, 2);
            if (state.View != null) state.View.ZoomFactor = state.Options.Zoom;
        };
        return slider;
    }

    private MenuItem CreateZoomMenu(ServiceState state)
    {
        var menu = new MenuItem { Header = "Zoom" };
        menu.SubmenuOpened += (_, _) =>
        {
            menu.Items.Clear();
            var slider = CreateZoomSlider(state);
            var content = new StackPanel();
            var heading = new DockPanel();
            var percent = Label($"{state.Options.Zoom:P0}", 12, true);
            var reset = new Button { Content = "Reset", FontSize = 11, Padding = new Thickness(7, 3, 7, 3), ToolTip = "Ctrl+0" };
            reset.Click += (_, _) => slider.Value = 100;
            DockPanel.SetDock(reset, Dock.Right); heading.Children.Add(reset); heading.Children.Add(percent);
            content.Children.Add(heading); content.Children.Add(slider);
            slider.ValueChanged += (_, _) => percent.Text = $"{state.Options.Zoom:P0}";
            menu.Items.Add(new MenuItem { Header = content, StaysOpenOnClick = true, Focusable = false });
        };
        // A placeholder makes this a submenu before its first opening.
        menu.Items.Add(new MenuItem());
        menu.SubmenuClosed += (_, _) => settings.Save();
        return menu;
    }

    private bool HandleZoomKey(Key key, ModifierKeys modifiers)
    {
        if (selected == null || (modifiers != ModifierKeys.Control && modifiers != (ModifierKeys.Control | ModifierKeys.Shift))) return false;
        if (key is Key.OemPlus or Key.Add) ChangeZoom(0.1);
        else if (key is Key.OemMinus or Key.Subtract) ChangeZoom(-0.1);
        else if (key is Key.D0 or Key.NumPad0) ChangeZoom(0, true);
        else return false;
        return true;
    }
}
