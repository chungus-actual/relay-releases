using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace Relay;

public partial class MainWindow
{
    private void CheckPetWardrobeAndGrooming()
    {
        foreach (string kind in PetMotion.Kinds)
        {
            var pet = new PetMotion(() => 0.69, kind);
            foreach (int outfit in new[] { 0, 1, 2, 3 }) { pet.SetOutfit(outfit); Check(pet.ToyLabel("dress") == "Outfit", "Clothing category remains Outfit for every selection and companion"); }
            pet.SetOutfit(2); pet.SetNookOpen(true); pet.Act("groom");
            pet.Advance(0.25);
            double remaining = pet.Remaining, position = pet.Position;
            pet.SetOutfit(2); pet.SetOutfit(-1); pet.SetOutfit(4);
            Check(pet.Outfit == 2 && pet.Remaining == remaining && pet.Action == "groom", "Duplicate and invalid outfit choices preserve the current reaction");
            var frames = new HashSet<int>();
            for (int i = 0; i < 10; i++)
            {
                pet.Advance(0.25); frames.Add(pet.GroomFrame);
                Check(pet.Position == position && !pet.Walking && pet.Velocity == 0 && pet.Outfit == 2, "Grooming stays in place and keeps the chosen outfit");
            }
            Check(frames.SetEquals(new[] { 0, 1 }) && pet.UpdateInterval() == (kind == "rock" ? 0.5 : 0.125), "Grooming reaches both gestures on the existing gentle timer");
            pet.Advance(1);
            Check(pet.Action == "idle" && pet.GroomFrame == 0, "Grooming expires without leaving a paw, shake, or sparkle behind");
            pet.Act("groom"); pet.Advance(0.4); pet.Act("feed");
            Check(pet.Action == "feed" && pet.GroomFrame == 0, "A new action immediately clears grooming presentation");
            pet.Act("groom");
            for (int i = 0; i < 4; i++) pet.Advance(1, true);
            Check(pet.Action == "idle" && pet.Position == position && !pet.Walking && pet.UpdateInterval(true) == 0.5, "Reduced motion keeps grooming still and still expires");
            bool groomed = false;
            for (int i = 0; i < 600; i++)
            {
                pet.Advance(1); groomed |= pet.Action == "groom";
                Check(pet.Outfit == 2, "Autonomous activities never change the user's clothing choice");
            }
            Check(kind == "rock" ? !groomed : groomed, "Only the animals groom autonomously; Rock stays still");
            foreach (string pose in PetArtwork.Wardrobe.Keys)
                Check(PetArtwork.Layers.ContainsKey(pet.ArtworkLayer(pet.ClothingLayer(pose)!)), "Every resting and active pose has fitted clothing for each animal");
        }
        var wardrobe = new PetMotion(() => 0.9);
        wardrobe.SetMusicPlaying(true); wardrobe.SetNookOpen(true); wardrobe.SetOutfit(2);
        wardrobe.SelectKind("roof"); wardrobe.SetOutfit(1);
        wardrobe.SelectKind("rock"); wardrobe.SetOutfit(3);
        wardrobe.SelectKind("puke");
        Check(wardrobe.Outfit == 2 && wardrobe.MusicPlaying && wardrobe.NookOpen, "Returning to Puke restores his outfit while preserving music and the room");
        wardrobe.SelectKind("roof"); Check(wardrobe.Outfit == 1, "Roof remembers his own outfit");
        wardrobe.SelectKind("rock"); Check(wardrobe.Outfit == 3, "Rock remembers his own outfit");
        wardrobe.Reset(); wardrobe.SelectKind("puke");
        Check(wardrobe.Outfit == 0 && wardrobe.GroomFrame == 0, "Disabling clears the session wardrobe and grooming state");
    }

    private void CapturePetWardrobes(string output)
    {
        string[] poses = ["Standing", "Seated", "Feeding", "High five", "Groom 1", "Groom 2", "Stretch", "Curled nap", "Chin nap", "Loaf nap", "Perched nap", "Box / dig", "Groom reduced", "Litter reduced"];
        string appearance = settings.Appearance;
        try
        {
            foreach (string mode in new[] { "Dark", "Light" })
            {
                settings.Appearance = mode; ApplyTheme();
                foreach (string kind in PetMotion.Kinds)
                {
                    var gallery = new UniformGrid { Columns = 4 };
                    foreach (string pose in poses)
                    for (int outfit = 0; outfit < 4; outfit++)
                    {
                        int style = pose == "Chin nap" ? 1 : pose == "Loaf nap" ? 2 : pose == "Perched nap" ? 3 : 0;
                        var sample = new PetMotion(() => style / 4.0 + 0.01, kind);
                        sample.SetOutfit(outfit);
                        if (pose.EndsWith("nap")) for (int i = 0; i < (kind == "roof" ? 45 : 6); i++) sample.Advance(1);
                        else if (pose == "Seated") sample.Advance(1);
                        else if (pose == "Stretch") sample.SetMusicPlaying(true);
                        else if (pose == "Feeding") { sample.Act("feed"); sample.Advance(0.2); }
                        else if (pose == "High five") sample.Act("highfive");
                        else if (pose.StartsWith("Groom")) { sample.Act("groom"); sample.Advance(pose == "Groom 1" ? 0.1 : 0.4, pose.EndsWith("reduced")); }
                        else if (pose == "Box / dig") { sample.Act("hide"); for (int i = 0; i < 20; i++) sample.Advance(0.1); }
                        else if (pose == "Litter reduced") { sample.Act("litter"); sample.Advance(1, true); }
                        var preview = new PetDrawing(sample, pose.EndsWith("reduced") ? true : null) { Width = 64, Height = 34 };
                        RenderOptions.SetEdgeMode(preview, EdgeMode.Aliased);
                        var tile = new StackPanel { Width = 128 };
                        tile.Children.Add(new Viewbox { Child = preview, Width = 128, Height = 68, Stretch = Stretch.Uniform });
                        tile.Children.Add(new TextBlock { Text = sample.OutfitName + " · " + pose, FontSize = 9, Foreground = Brush("Ink"), TextAlignment = TextAlignment.Center });
                        gallery.Children.Add(tile);
                    }
                    var sheet = new Border { Child = gallery, Background = Brush("Panel"), Padding = new Thickness(8) };
                    sheet.Measure(new Size(528, double.PositiveInfinity)); sheet.Arrange(new Rect(0, 0, 528, sheet.DesiredSize.Height));
                    CaptureElement(sheet, Path.Combine(output, kind + "-wardrobe-" + mode.ToLowerInvariant() + ".png"));
                }
            }
        }
        finally { settings.Appearance = appearance; ApplyTheme(); }
    }
}
