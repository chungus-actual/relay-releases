using System;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;

namespace Relay;

public partial class MainWindow
{
    private bool darkTheme;
    private void SystemThemeChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (quitting || settings.Appearance != "System") return;
        Dispatcher.BeginInvoke(new Action(() => { if (!quitting) { ApplyTheme(); if (localPage == "settings") RebuildSettings(); } }));
    }
    private bool ResolveDarkTheme()
    {
        if (settings.Appearance == "Light") return false;
        if (settings.Appearance != "System") return true;
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is not int value || value == 0;
    }
    private CoreWebView2PreferredColorScheme WebsiteScheme => settings.Appearance == "System"
        ? CoreWebView2PreferredColorScheme.Auto : darkTheme ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
    private void ApplyTheme()
    {
        if (settings.Appearance is not ("Dark" or "Light" or "System")) settings.Appearance = settings.Dark ? "Dark" : "Light";
        if (settings.Palette is not ("Graphite" or "Ocean" or "Dune")) settings.Palette = "Graphite";
        if (settings.AccentName is not ("Mint" or "Sky" or "Iris" or "Rose" or "Amber")) settings.AccentName = "Mint";
        darkTheme = ResolveDarkTheme();
        settings.Dark = darkTheme;
        string[] colors = (settings.Palette, darkTheme) switch
        {
            ("Ocean", true) => ["#131C28", "#0F1722", "#1A2635", "#26374A", "#EEF4FA", "#99ABBF", "#2B3D50"],
            ("Ocean", false) => ["#F0F5FA", "#E7EEF6", "#FCFDFF", "#DEE8F2", "#1B3046", "#536B82", "#D2DEE9"],
            ("Dune", true) => ["#211E1B", "#191715", "#2A2622", "#3A342E", "#F5F0E8", "#B2A69A", "#413A33"],
            ("Dune", false) => ["#F7F3EC", "#EEE8DD", "#FFFCF6", "#EAE2D6", "#352E26", "#786B5C", "#DED5C8"],
            (_, false) => ["#F5F6F8", "#EBEEF1", "#FFFFFF", "#E5E9ED", "#202830", "#65717D", "#D9DFE5"],
            _ => ["#17191D", "#121418", "#1E2126", "#2B3038", "#F1F3F5", "#9BA4AF", "#30363F"]
        };
        var keys = new[] { "Base", "Panel", "Card", "Hover", "Ink", "Muted", "Line" };
        for (int i = 0; i < keys.Length; i++) Application.Current.Resources[keys[i]] = ColorBrush(colors[i]);
        var accent = AccentColor(settings.AccentName, darkTheme);
        Application.Current.Resources["Accent"] = ColorBrush(accent);
        Application.Current.Resources["AccentInk"] = ColorBrush(darkTheme ? "#13251F" : "#FFFFFF");
        var tint = (Color)ColorConverter.ConvertFromString(accent);
        tint.A = darkTheme ? (byte)28 : (byte)22;
        var soft = new SolidColorBrush(tint); soft.Freeze();
        Application.Current.Resources["AccentSoft"] = soft;
        foreach (var state in services)
            if (state.Core is { } core)
            {
                core.Profile.PreferredColorScheme = WebsiteScheme;
                state.View!.DefaultBackgroundColor = System.Drawing.ColorTranslator.FromHtml(colors[0]);
            }
        RefreshUsageIndicator();
        ApplyTrayTheme();
        if (railButtons.Count > 0) Refresh();
    }
    private static string AccentColor(string name, bool dark) => (name, dark) switch
    {
        ("Sky", true) => "#8ABBFF", ("Sky", false) => "#235DB7",
        ("Iris", true) => "#BAA4FF", ("Iris", false) => "#7250BA",
        ("Rose", true) => "#F3A4B9", ("Rose", false) => "#B33E68",
        ("Amber", true) => "#EDC37F", ("Amber", false) => "#95601A",
        (_, false) => "#13795F", _ => "#85DFC3"
    };
    private void RebuildSettings()
    {
        var offset = LocalPage.VerticalOffset;
        ShowSettings();
        LocalPage.ScrollToVerticalOffset(offset);
    }
    private void MinimizeClick(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);
    private void MaximizeClick(object sender, RoutedEventArgs e)
    {
        if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this);
        else SystemCommands.MaximizeWindow(this);
    }
    private void CloseClick(object sender, RoutedEventArgs e) => Close();
}
