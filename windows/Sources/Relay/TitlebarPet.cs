using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Relay;

public sealed class TitlebarPet : UserControl
{
    internal readonly PetMotion Motion = new();
    internal readonly Dictionary<string, Button> Actions = [];
    internal readonly Button PetButton;
    internal Popup? Playground;
    internal bool Animating => timer.IsEnabled;
    internal double AnimationInterval => timer.Interval.TotalSeconds;
    private readonly DispatcherTimer timer = new(DispatcherPriority.Background);
    private readonly PetDrawing drawing;
    private PetDrawing? room;
    private PetNookBackground? nookBackground;
    internal Func<DateTimeOffset> LocalNow { get; set; } = () => DateTimeOffset.Now;
    internal PetDaylight Daylight { get; private set; } = PetDaylight.At(DateTimeOffset.Now);
    private void RefreshDaylight()
    {
        if (!Motion.NookOpen) return;
        Daylight = PetDaylight.At(LocalNow());
        nookBackground?.SetDaylight(Daylight);
    }
    private Window? owner;
    private TextBlock? nookStatus;
    private Border? speechBubble;
    private TextBlock? speechText;
    private TextBlock? speechAuthor;
    private long lastFrame;
    private string lastAction = "";
    public TitlebarPet()
    {
        Height = 34; Width = 208;
        drawing = new PetDrawing(Motion); RenderOptions.SetEdgeMode(drawing, EdgeMode.Aliased);
        PetButton = new Button { Content = drawing, Width = double.NaN, Height = double.NaN, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, ToolTip = Motion.Name, Cursor = Cursors.Hand };
        PetButton.SetResourceReference(StyleProperty, "PetButton");
        System.Windows.Automation.AutomationProperties.SetName(PetButton, Motion.AccessibilityStatus);
        PetButton.Click += (_, _) => OpenPlayground(); Content = PetButton;
        PetButton.MouseEnter += (_, e) => Hover(true, (e.GetPosition(PetButton).X - 25) / Math.Max(1, PetButton.ActualWidth - 50));
        PetButton.MouseLeave += (_, _) => Hover(false);
        timer.Tick += (_, _) => { AdvanceToNow(); Draw(); };
        Loaded += (_, _) => Attach(); Unloaded += (_, _) => Detach();
        IsVisibleChanged += (_, _) => UpdateActivity();
    }
    private void Attach()
    {
        Detach(); owner = Window.GetWindow(this);
        if (owner != null) { owner.Activated += ActivityChanged; owner.Deactivated += ActivityChanged; owner.StateChanged += ActivityChanged; }
        UpdateActivity();
    }
    private void Detach()
    {
        timer.Stop(); Motion.SetHovered(false); ClosePlayground();
        if (owner != null) { owner.Activated -= ActivityChanged; owner.Deactivated -= ActivityChanged; owner.StateChanged -= ActivityChanged; owner = null; }
    }
    private void ActivityChanged(object? sender, EventArgs e) => UpdateActivity();
    private void UpdateActivity()
    {
        bool running = IsVisible && owner?.IsActive == true && owner.WindowState != WindowState.Minimized;
        if (!running) { timer.Stop(); Motion.SetHovered(false); ClosePlayground(); if (Visibility == Visibility.Collapsed) { Motion.Reset(); System.Windows.Automation.AutomationProperties.SetName(PetButton, Motion.AccessibilityStatus); } return; }
        SyncTimerInterval();
        if (!timer.IsEnabled) { lastFrame = Stopwatch.GetTimestamp(); timer.Start(); }
        Draw();
    }
    private void SyncTimerInterval()
    {
        var interval = TimeSpan.FromSeconds(Motion.UpdateInterval(!SystemParameters.ClientAreaAnimation));
        if (timer.Interval != interval) timer.Interval = interval;
    }
    private void Draw()
    {
        RefreshDaylight();
        if (timer.IsEnabled) SyncTimerInterval();
        string state = Motion.AccessibilityStatus;
        if (lastAction != state)
        {
            lastAction = state;
            PetButton.ToolTip = Motion.Name;
            System.Windows.Automation.AutomationProperties.SetName(PetButton, state);
        }
        if (Actions.TryGetValue("dress", out var dress))
        {
            dress.ToolTip = "Outfit: " + Motion.OutfitName + ". Click to cycle; right-click to choose.";
            System.Windows.Automation.AutomationProperties.SetName(dress, "Change " + Motion.Name + " outfit, currently " + Motion.OutfitName);
        }
        if (nookStatus != null && nookStatus.Text != Motion.NookStatus) nookStatus.Text = Motion.NookStatus;
        foreach (var (action, button) in Actions)
        {
            bool selected = Motion.Action == action;
            if (!Equals(button.Tag, selected)) { button.Tag = selected; button.SetResourceReference(Control.BackgroundProperty, selected ? "AccentSoft" : "Panel"); }
        }
        if (speechBubble != null && speechText != null)
        {
            speechBubble.Visibility = Motion.Musing == null ? Visibility.Collapsed : Visibility.Visible;
            string saying = Motion.Musing == null ? "" : "“" + Motion.Musing + "”";
            if (speechText.Text != saying)
            {
                speechText.Text = saying;
                if (speechAuthor != null) speechAuthor.Text = "— " + Motion.MusingAuthor;
                System.Windows.Automation.AutomationProperties.SetName(speechBubble, Motion.Musing == null ? "" : Motion.Name + " says: " + Motion.Musing + ", by " + Motion.MusingAuthor);
            }
        }
        drawing.InvalidateVisual(); room?.InvalidateVisual();
    }
    private void AdvanceToNow()
    {
        if (!timer.IsEnabled) return;
        long now = Stopwatch.GetTimestamp();
        Motion.Advance(Stopwatch.GetElapsedTime(lastFrame, now).TotalSeconds, !SystemParameters.ClientAreaAnimation); lastFrame = now;
    }
    internal void SetCompanion(string kind)
    {
        if (Motion.Kind == PetMotion.NormalizedKind(kind)) return;
        bool open = Playground?.IsOpen == true;
        if (open) ClosePlayground();
        AdvanceToNow(); Motion.SelectKind(kind); Draw();
        if (open) OpenPlayground();
    }
    internal void SetMusicPlaying(bool playing)
    {
        playing = IsVisible && playing;
        if (Motion.MusicPlaying == playing) return;
        AdvanceToNow(); Motion.SetMusicPlaying(playing); Draw();
    }
    private void Hover(bool hovered, double toward = 0.5)
    {
        if (Motion.Hovered == hovered) return;
        AdvanceToNow(); Motion.SetHovered(hovered, toward); Draw();
    }
    internal void Interact(string action, double? target = null)
    {
        if (!IsVisible) return;
        AdvanceToNow(); Motion.Act(action, target); Draw();
    }
    internal void ChooseOutfit(int outfit)
    {
        if (!IsVisible || Motion.Outfit == outfit) return;
        AdvanceToNow(); Motion.SetOutfit(outfit); Draw();
    }
    internal void ClosePlayground() { Motion.SetNookOpen(false); if (Playground != null) Playground.IsOpen = false; room = null; nookBackground = null; speechBubble = null; speechText = null; speechAuthor = null; }
    internal void OpenPlayground()
    {
        if (!IsVisible) return;
        if (Playground?.IsOpen == true) { ClosePlayground(); return; }
        Actions.Clear();
        var stack = new StackPanel { Width = 312 };
        var header = new StackPanel { Height = 40, Margin = new Thickness(0, 0, 0, 12) };
        var heading = new TextBlock { Text = Motion.NookTitle, FontFamily = new FontFamily("Georgia"), FontSize = 20 };
        heading.SetResourceReference(TextBlock.ForegroundProperty, "Ink"); header.Children.Add(heading);
        nookStatus = new TextBlock { Text = Motion.NookStatus, FontSize = 11, Margin = new Thickness(0, 2, 0, 0) };
        nookStatus.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); header.Children.Add(nookStatus); stack.Children.Add(header);
        var scene = new Grid { Width = 312, Height = 140, Clip = new RectangleGeometry(new Rect(0, 0, 312, 140), 16, 16) };
        nookBackground = new PetNookBackground(Daylight); scene.Children.Add(nookBackground);
        room = new PetDrawing(Motion) { Width = 312, Height = 140, Large = true, Cursor = Cursors.Hand };
        RenderOptions.SetEdgeMode(room, EdgeMode.Aliased);
        room.MouseEnter += (_, e) => Hover(true, (e.GetPosition(room).X - 50) / 212);
        room.MouseLeave += (_, _) => Hover(false);
        room.MouseLeftButtonDown += (_, e) =>
        {
            var point = e.GetPosition(room); double catX = 50 + Motion.Position * 212;
            if (Math.Abs(point.X - catX) < 44 && point.Y > 54) Interact("pet");
            else Interact("play", (point.X - 50) / 212);
            e.Handled = true;
        };
        scene.Children.Add(room);
        var speech = new StackPanel();
        speechText = new TextBlock { FontFamily = new FontFamily("Georgia"), FontSize = 11, TextWrapping = TextWrapping.Wrap };
        speechText.SetResourceReference(TextBlock.ForegroundProperty, "Ink"); speech.Children.Add(speechText);
        speechAuthor = new TextBlock { Text = "— " + Motion.Name, FontSize = 9, Margin = new Thickness(0, 2, 0, 0) };
        speechAuthor.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); speech.Children.Add(speechAuthor);
        speechBubble = new Border { Child = speech, Width = 178, Padding = new Thickness(8), Margin = new Thickness(8),
            CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        speechBubble.SetResourceReference(Border.BackgroundProperty, "Panel"); speechBubble.SetResourceReference(Border.BorderBrushProperty, "Line");
        scene.Children.Add(speechBubble); stack.Children.Add(scene);
        var invitation = new TextBlock { Text = "things to do", FontSize = 10, Height = 24, TextAlignment = TextAlignment.Center, Padding = new Thickness(0, 6, 0, 0) };
        invitation.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); stack.Children.Add(invitation);
        var buttons = new UniformGrid { Columns = 3, Height = 168 };
        foreach (string action in Motion.ToyActions)
        {
            string label = Motion.ToyLabel(action), art = Motion.ToyArtwork(action), accessible = label + ", " + Motion.Name;
            var content = new StackPanel();
            content.Children.Add(new PetObjectArtwork(art) { Width = 33, Height = 24, HorizontalAlignment = HorizontalAlignment.Center });
            content.Children.Add(new TextBlock { Text = label, FontSize = 11, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 2, 0, 0) });
            var button = new Button { Content = content, Height = 54, ToolTip = accessible };
            button.SetResourceReference(StyleProperty, "PetToyButton");
            System.Windows.Automation.AutomationProperties.SetName(button, accessible);
            System.Windows.Automation.AutomationProperties.SetAutomationId(button, "puke-" + action);
            if (action == "dress")
            {
                var menu = new ContextMenu();
                for (int index = 0; index < Motion.OutfitNames.Length; index++)
                {
                    int choice = index;
                    var item = new MenuItem { Header = Motion.OutfitNames[index], IsCheckable = true };
                    item.Click += (_, _) => ChooseOutfit(choice);
                    menu.Opened += (_, _) => item.IsChecked = Motion.Outfit == choice;
                    menu.Items.Add(item);
                }
                button.ContextMenu = menu;
            }
            button.Click += (_, _) => Interact(action); Actions[action] = button; buttons.Children.Add(button);
        }
        stack.Children.Add(buttons);
        var surface = new Border { Child = stack, Padding = new Thickness(14), CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1) };
        surface.SetResourceReference(Border.BackgroundProperty, "Panel"); surface.SetResourceReference(Border.BorderBrushProperty, "Line");
        var popup = new Popup { Child = surface, PlacementTarget = this, Placement = PlacementMode.Bottom, VerticalOffset = 4,
            StaysOpen = false, AllowsTransparency = true, PopupAnimation = SystemParameters.ClientAreaAnimation ? PopupAnimation.Fade : PopupAnimation.None };
        Playground = popup;
        popup.Closed += (_, _) =>
        {
            // An old popup can finish fading after a newly selected companion opens.
            if (!ReferenceEquals(Playground, popup)) return;
            Hover(false); Motion.SetNookOpen(false); room = null; nookBackground = null; nookStatus = null; speechBubble = null; speechText = null; speechAuthor = null;
        };
        surface.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { ClosePlayground(); PetButton.Focus(); e.Handled = true; } };
        KeyboardNavigation.SetTabNavigation(surface, KeyboardNavigationMode.Cycle);
        Playground.IsOpen = true; Motion.SetNookOpen(true); Draw(); Actions["pet"].Focus();
    }
}

internal sealed class PetObjectArtwork(string name) : FrameworkElement
{
    internal static void Draw(DrawingContext dc, FrameworkElement owner, string name, Rect rect)
    {
        dc.PushTransform(new TranslateTransform(rect.X, rect.Y));
        dc.PushTransform(new ScaleTransform(rect.Width / 44, rect.Height / 32));
        foreach (var pixel in PetArtwork.Layers[name])
        {
            string color = PetArtwork.Palette[pixel.Color];
            var brush = color == "accent" ? owner.TryFindResource("Accent") as Brush ?? Brushes.Coral : Palette[pixel.Color];
            dc.DrawRectangle(brush, null, new Rect(pixel.X, pixel.Y, pixel.Width, 1));
        }
        dc.Pop(); dc.Pop();
    }
    private static readonly Brush[] Palette = Array.ConvertAll(PetArtwork.Palette, value =>
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value == "accent" ? "#DB8A7A" : "#" + value));
        brush.Freeze(); return (Brush)brush;
    });
    protected override void OnRender(DrawingContext dc) => Draw(dc, this, name, new Rect(0, 0, ActualWidth, ActualHeight));
}

internal sealed class PetNookBackground(PetDaylight daylight) : FrameworkElement
{
    private PetDaylight lighting = daylight;
    internal void SetDaylight(PetDaylight next)
    {
        if (lighting == next) return;
        lighting = next; InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc)
    {
        var glow = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#" + lighting.GlowHex));
        dc.DrawRectangle(TryFindResource("Card") as Brush, null, new Rect(0, 0, 312, 140));
        dc.PushOpacity(lighting.WallOpacity); dc.DrawRectangle(glow, null, new Rect(0, 0, 312, 140)); dc.Pop();
        dc.DrawRectangle(TryFindResource("AccentSoft") as Brush, null, new Rect(0, 102, 312, 38));
        dc.PushOpacity(lighting.FloorOpacity); dc.DrawRectangle(glow, null, new Rect(0, 102, 312, 38)); dc.Pop();
        dc.PushOpacity(lighting.BeamOpacity);
        dc.DrawGeometry(glow, null, Geometry.Parse("M38,66 L91,66 L170,140 L73,140 Z")); dc.Pop();
        PetObjectArtwork.Draw(dc, this, lighting.WindowArtwork, new Rect(20, 10, 88, 64));
        PetObjectArtwork.Draw(dc, this, "nookPlant", new Rect(258, 70, 44, 32));
        var pink = new SolidColorBrush(Color.FromRgb(219, 138, 122));
        dc.PushOpacity(0.2); dc.DrawEllipse(pink, null, new Point(156, 121), 80, 11); dc.Pop();
        dc.PushOpacity(0.35);
        dc.DrawEllipse(null, new Pen(pink, 1) { DashStyle = new DashStyle(new double[] { 3, 3 }, 0) }, new Point(156, 121), 73, 7);
        dc.Pop();
    }
}

internal sealed class PetDrawing(PetMotion motion, bool? reducedMotion = null) : FrameworkElement
{
    public bool Large { get; set; }
    private static SolidColorBrush Color(string value) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value)); brush.Freeze(); return brush; }
    private static readonly Brush Cream = Color("#FFF0CE"), Pink = Color("#DB8A7A"), Ink = Color("#49313D"), Shadow = Color("#303740");
    private static readonly Brush?[] SpriteBrushes = Array.ConvertAll(PetArtwork.Palette, value => value == "accent" ? null : Color("#" + value));
    private static readonly Geometry Heart = Geometry.Parse("M0,3 C-7,-2 -4,-7 0,-4 C4,-7 7,-2 0,3 Z");
    private static readonly Geometry Fish = Geometry.Parse("M-7,0 Q0,-8 7,0 Q0,8 -7,0 M7,0 L12,-5 L12,5 Z");
    private void Layer(DrawingContext dc, string name, int dx = 0, int dy = 0)
    {
        var accent = TryFindResource("Accent") as Brush ?? Pink;
        foreach (var pixel in PetArtwork.Layers[motion.ArtworkLayer(name)])
            dc.DrawRectangle(SpriteBrushes[pixel.Color] ?? accent, null, new Rect(pixel.X + dx, pixel.Y + dy, pixel.Width, 1));
    }
    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight; if (w <= 0 || h <= 0) return;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));
        bool reduced = motion.IsRock || (reducedMotion ?? !SystemParameters.ClientAreaAnimation), sleeping = motion.Sleeping;
        bool resting = sleeping || motion.Transition == "settle";
        bool stretching = motion.Transition == "stretch" && !reduced;
        bool yawning = motion.Transition == "yawn" && !reduced;
        double scale = Large ? 2 : 1, x = Math.Round(25 * scale + motion.Position * Math.Max(0, w - 50 * scale)), floor = Large ? h - 23 : h - 1;
        var line = TryFindResource("Line") as Brush ?? Shadow;
        dc.PushOpacity(0.2); dc.DrawEllipse(Shadow, null, new Point(x, floor), 15 * scale, 2 * scale); dc.Pop();
        var accent = TryFindResource("Accent") as Brush ?? Pink;
        bool hiding = motion.AtBox || reduced && motion.Action == "hide";
        double boxProgress = reduced && hiding ? 1 : motion.BoxProgress;
        double boxX = Math.Round(25 * scale + (reduced ? motion.Position : motion.Target) * Math.Max(0, w - 50 * scale));
        void BoxLayer(string name)
        {
            dc.PushOpacity(reduced ? 1 : motion.BoxOpacity);
            PetObjectArtwork.Draw(dc, this, name, new Rect(boxX - 22 * scale, floor - 32 * scale, 44 * scale, 32 * scale));
            dc.Pop();
        }
        if (motion.Action == "hide") BoxLayer("boxBack");
        bool littering = motion.Kind == "puke" && motion.Action == "litter" && (reduced || Math.Abs(motion.Position - motion.Target) < 0.04);
        bool sitting = motion.Sitting || hiding;
        bool dancing = motion.EnjoyingMusic && sitting && !reduced;
        bool waving = dancing && motion.DanceMove == 0;
        bool raisingPaw = motion.Action == "highfive" || waving;
        int gaitFrame = !reduced && motion.Walking ? 1 + motion.GaitFrame(w / scale - 50) : 0;
        var feet = PetArtwork.Gait[gaitFrame];
        int dig = reduced ? 0 : motion.DigPawOffset;
        int gesture = !reduced && (motion.Action == "highfive" || littering) && Math.Sin(motion.Time * 8) > 0 ? 1 : 0;
        int bob = !reduced && (motion.Action == "play") && Math.Sin(motion.Time * 7) > 0 ? 1 : 0;
        int breath = sleeping && !reduced && Math.Sin(motion.SleepTime * 0.7) > 0 ? 1 : 0;
        int groom = reduced ? 0 : motion.GroomFrame;
        int shake = motion.Action == "groom" && motion.Kind == "roof" && !reduced ? (groom == 0 ? -1 : 1) : 0;
        int crouch = motion.IsRock ? 0 : hiding ? (int)Math.Round(6 * boxProgress, MidpointRounding.AwayFromZero) : littering ? 2 : 0;
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, w, floor + (hiding ? 0 : 2 * scale))));
        dc.PushTransform(new TranslateTransform(x, floor + (crouch - bob) * scale));
        dc.PushTransform(new ScaleTransform(scale * motion.Facing, scale));
        dc.PushTransform(new TranslateTransform(-22, -32));
        if (motion.Digging) Layer(dc, "digPatch");
        if (motion.IsRock)
        {
            Layer(dc, "rockBody"); Layer(dc, "rockEyes");
            if (motion.Outfit == 1) Layer(dc, "rockBandana");
            if (motion.Outfit == 2) Layer(dc, "rockHoodie");
            if (motion.Outfit == 3) Layer(dc, "rockShades");
            if (motion.Action == "groom") Layer(dc, "groomSparkle");
            if (motion.Action == "game") Layer(dc, "gameConsole");
        }
        else
        {
            double progress = sleeping || reduced ? 1 : motion.SettleProgress;
            bool startingToSettle = resting && progress < 0.5;
            string wardrobePose = resting ? startingToSettle ? "sitting" : new[] { "curl", "chin", "loaf", "perch" }[motion.SleepStyle] :
                stretching ? "stretching" : sitting ? "sitting" : "standing";
            string? clothing = motion.ClothingLayer(wardrobePose);
            void Coat() { if (motion.Outfit == 2 && clothing != null) Layer(dc, clothing, 0, resting ? -breath : 0); }
            if (resting)
            {
                string body = startingToSettle ? "sitBody" : motion.SleepStyle == 2 ? "loafBody" : motion.SleepStyle == 3 ? "sitBody" : "sleepBody";
                Layer(dc, body, 0, -breath);
                Coat();
            }
            else if (stretching)
            {
                Layer(dc, "tail"); Layer(dc, "hind"); Layer(dc, "stretchBody");
                Coat();
                Layer(dc, "stretchFront");
            }
            else if (sitting)
            {
                Layer(dc, hiding ? "tuckedTail" : "sitTail"); Layer(dc, "sitBody");
                Coat();
                if (!waving && motion.Action != "groom") Layer(dc, "sitFront");
            }
            else
            {
                int tailFlick = !reduced && (motion.Walking ? Math.Sin(motion.Time * 2) > 0 : motion.Time % 24 > 23.5) ? 1 : 0;
                Layer(dc, "tail", tailFlick - shake);
                Layer(dc, "backHind", feet[0].X, feet[0].Y); Layer(dc, "backFront", feet[1].X + dig, feet[1].Y - Math.Max(0, dig));
                Layer(dc, "body");
                Coat();
                Layer(dc, "hind", feet[2].X, feet[2].Y);
                if (!raisingPaw) Layer(dc, "front", feet[3].X - dig, feet[3].Y + Math.Min(0, dig));
            }
            int restHeadX = new[] { -5, -2, -3, -4 }[motion.SleepStyle];
            int restHeadY = new[] { 8, 9, 5, 3 }[motion.SleepStyle];
            int glance = motion.Glancing && !reduced ? motion.LookDirection * motion.Facing : 0;
            int headX = (resting ? (int)Math.Round(-4 + (restHeadX + 4) * progress, MidpointRounding.AwayFromZero) : sitting ? -4 : 0) + glance + shake;
            int headY = (resting ? (int)Math.Round(restHeadY * progress, MidpointRounding.AwayFromZero) : hiding ? -(int)Math.Round(4 * boxProgress, MidpointRounding.AwayFromZero) : motion.Digging ? 3 : motion.Action == "game" ? 1 : stretching ? 5 : dancing ? motion.DanceHeadOffset : motion.Action == "feed" && !reduced ? 1 + (Math.Sin(motion.Time * 12) > 0 ? 1 : 0) : 0) - (glance == 0 ? 0 : 1);
            Layer(dc, motion.EarTwitch && !reduced ? "headTwitch" : "head", headX, headY);
            bool closed = yawning || motion.Action is "pet" or "groom" || (!reduced && motion.Time % 8 > 7.8);
            Layer(dc, resting && !motion.Glancing ? "sleepEyes" : closed ? "closed" : "eyes", headX, headY);
            Layer(dc, "nose", headX, headY); Layer(dc, "whiskers", headX, headY);
            if (yawning) Layer(dc, "yawnMouth", headX, headY);
            if (motion.Outfit == 3 || motion.WearingShades && !resting) Layer(dc, "shades", headX, headY);
            if (motion.Outfit == 1 && clothing != null) Layer(dc, clothing, 0, resting ? -breath : hiding ? -(int)Math.Round(4 * boxProgress, MidpointRounding.AwayFromZero) : 0);
            if (motion.Action == "groom")
            {
                if (motion.Kind == "puke")
                {
                    Layer(dc, "groomPaw", 1, -groom * 4);
                    if (groom == 0) Layer(dc, "groomTongue");
                }
                else Layer(dc, "shakeMarks", shake);
            }
            if (!resting && raisingPaw)
            {
                int pawX = sitting ? -4 + motion.DancePawOffset : 0;
                Layer(dc, "raisedFront", pawX, -gesture); Layer(dc, "paw", pawX + 2, -2 - gesture);
            }
            if (motion.Digging) Layer(dc, "digDirt", dig, -Math.Abs(dig));
            if (motion.Action == "game")
            {
                Layer(dc, "gameConsole"); Layer(dc, "gamePaws", 0, reduced ? 0 : motion.GamePawOffset);
            }
            if (resting)
            {
                Layer(dc, startingToSettle ? "sitTail" : motion.SleepStyle >= 2 ? "tuckedTail" : "sleepTail");
                if (motion.SleepStyle == 1) Layer(dc, "chinPaws");
            }
        }
        dc.Pop(); dc.Pop(); dc.Pop(); dc.Pop();
        if (motion.Action == "litter" && motion.Kind == "puke")
        {
            double trayX = 25 * scale + (reduced ? motion.Position : 0.84) * Math.Max(0, w - 50 * scale);
            dc.DrawRoundedRectangle(TryFindResource("Card") as Brush ?? Shadow, new Pen(line, 1), new Rect(trayX - 16 * scale, floor - 7 * scale, 32 * scale, 11 * scale), 3, 3);
            dc.DrawRoundedRectangle(Color("#B8AA92"), null, new Rect(trayX - 13 * scale, floor - 6 * scale, 26 * scale, 5 * scale), 2, 2);
            dc.PushOpacity(0.5);
            for (int grain = 0; grain < 9; grain++) dc.DrawEllipse(Ink, null, new Point(trayX + (grain * 2.5 - 10) * scale, floor - (grain % 2 == 0 ? 4 : 2.5) * scale), 0.45 * scale, 0.45 * scale);
            dc.Pop();
            if (littering && motion.Remaining < 1.2)
            {
                dc.DrawLine(new Pen(accent, 1.2), new Point(trayX + 18 * scale, floor - 15 * scale), new Point(trayX + 18 * scale, floor - 9 * scale));
                dc.DrawLine(new Pen(accent, 1.2), new Point(trayX + 15 * scale, floor - 12 * scale), new Point(trayX + 21 * scale, floor - 12 * scale));
            }
        }
        if (motion.Action == "hide") BoxLayer("boxFront");
        if (motion.Action == "highfive")
        {
            double starX = x + motion.Facing * 22 * scale;
            dc.DrawLine(new Pen(accent, 1.2), new Point(starX, floor - 18 * scale), new Point(starX, floor - 12 * scale));
            dc.DrawLine(new Pen(accent, 1.2), new Point(starX - 3 * scale, floor - 15 * scale), new Point(starX + 3 * scale, floor - 15 * scale));
        }
        if (motion.Action == "pet")
        {
            double lift = reduced ? 0 : (1 - motion.Remaining / 2.4) * (Large ? 24 : 5);
            dc.PushTransform(new TranslateTransform(x + 24 * scale, floor - 23 * scale - lift)); dc.PushTransform(new ScaleTransform(scale * 0.65, scale * 0.65)); dc.DrawGeometry(Pink, null, Heart); dc.Pop(); dc.Pop();
        }
        if (motion.Action == "litter" && motion.IsRock)
            for (int drop = 0; drop < 3; drop++) dc.DrawEllipse(accent, null, new Point(x + (drop * 6 - 6) * scale, floor - 21 * scale), scale, 2 * scale);
        if (motion.Kind != "puke" && motion.Action is "feed" or "play")
        {
            double propX = motion.Action == "feed" || motion.IsRock ? x + motion.Facing * 24 * scale : 25 * scale + motion.Target * Math.Max(0, w - 50 * scale);
            PetObjectArtwork.Draw(dc, this, motion.ToyArtwork(motion.Action), new Rect(propX - 11 * scale, floor - 14 * scale, 22 * scale, 16 * scale));
        }
        if (motion.Action == "feed" && motion.Kind == "puke")
        {
            dc.PushTransform(new TranslateTransform(x + motion.Facing * 25 * scale, floor - 3 * scale)); dc.PushTransform(new ScaleTransform(scale * 0.6, scale * 0.6)); dc.DrawGeometry(TryFindResource("Accent") as Brush ?? Pink, null, Fish); dc.Pop(); dc.Pop();
        }
        if (motion.Action == "play" && motion.Kind == "puke")
        {
            double ballX = 25 * scale + motion.Target * Math.Max(0, w - 50 * scale);
            dc.DrawEllipse(accent, null, new Point(ballX, floor - 4 * scale), 4 * scale, 4 * scale);
            dc.DrawEllipse(null, new Pen(Cream, 0.6), new Point(ballX, floor - 4 * scale), 2 * scale, 3.5 * scale);
            dc.DrawLine(new Pen(accent, 0.8), new Point(ballX, floor), new Point(ballX + 10 * scale, floor));
        }
        if (motion.EnjoyingMusic)
        {
            double lift = 0;
            var note = new FormattedText("♪", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Large ? 17 : 10, TryFindResource("Accent") as Brush ?? Pink, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(note, new Point(x - motion.Facing * 6 * scale, floor - 30 * scale + lift));
        }
        if (sleeping && Large)
        {
            var text = new FormattedText("z z", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, TryFindResource("Muted") as Brush ?? Ink, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(text, new Point(x + 27, floor - 45 - breath));
        }
    }
}

public partial class MainWindow
{
    internal void SetPetCompanion(string kind)
    {
        string previous = settings.TitlebarCompanion;
        settings.TitlebarCompanion = PetMotion.NormalizedKind(kind);
        try { settings.Save(); }
        catch { settings.TitlebarCompanion = previous; throw; }
        CaptionPet.SetCompanion(settings.TitlebarCompanion);
    }
    private void SetPetEnabled(bool enabled)
    {
        bool previous = settings.TitlebarPetEnabled;
        settings.TitlebarPetEnabled = enabled;
        try { settings.Save(); }
        catch { settings.TitlebarPetEnabled = previous; throw; }
        RefreshCaptionLayout();
    }
}
