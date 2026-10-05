using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private async Task CheckTitlebarPet(string output)
    {
        CheckPetWardrobeAndGrooming();
        foreach (var (hour, phase) in new[] { (0, "night"), (5, "night"), (6, "dawn"), (7, "dawn"), (8, "day"), (17, "day"), (18, "dusk"), (19, "dusk"), (20, "night"), (23, "night") })
        {
            var light = new PetDaylight(hour);
            Check(light.Phase == phase && PetArtwork.Layers.ContainsKey(light.WindowArtwork), "Local hours select a complete shared window scene");
        }
        var instant = new DateTimeOffset(2026, 9, 20, 12, 0, 0, TimeSpan.Zero);
        var west = TimeZoneInfo.CreateCustomTimeZone("West", TimeSpan.FromHours(-7), "West", "West");
        var east = TimeZoneInfo.CreateCustomTimeZone("East", TimeSpan.FromHours(7), "East", "East");
        Check(PetDaylight.At(instant, TimeZoneInfo.Utc).Phase == "day" && PetDaylight.At(instant, west).Phase == "night" && PetDaylight.At(instant, east).Phase == "dusk", "The room follows local time rather than UTC or the appearance setting");
        Check(PetDaylight.At(instant.AddHours(-7), TimeZoneInfo.Utc).Phase == "night", "Clock changes recompute the phase without advancing animation time");
        var bowlDog = new PetMotion(kind: "roof");
        Check(bowlDog.ToyArtwork("feed") == "toyBowl" && bowlDog.ToyArtwork("play") == "toyBone", "Roof eats from a bowl and keeps the bone for play");
        foreach (string kind in PetMotion.Kinds)
        {
            var actor = new PetMotion(() => 0.9, kind);
            actor.SetNookOpen(true);
            for (int i = 0; i < 29; i++) actor.Advance(1, true);
            Check(actor.Musing != null && (kind == "puke" ? actor.MusingAuthor == "Marcus Aurelius" : actor.MusingAuthor == actor.Name), "Each companion uses its own sayings or an attributed philosopher");
            string? saying = actor.Musing; double left = actor.MusingRemaining;
            actor.SelectKind(kind.ToUpperInvariant());
            Check(actor.Musing == saying && actor.MusingRemaining == left, "Duplicate companion selection preserves speech and its expiry");
            actor.Act("game"); actor.SetMusicPlaying(true); actor.SelectKind(kind == "rock" ? "roof" : "rock");
            Check(actor.Action == "idle" && actor.Musing == null && actor.MusicPlaying && actor.NookOpen && actor.Outfit == 0, "Switching replaces transient state while keeping playback and the open nook");
        }
        var stone = new PetMotion(() => 0, "rock");
        stone.SetMusicPlaying(true); stone.SetHovered(true, 0);
        Check(!stone.Glancing && !stone.EnjoyingMusic && stone.Transition == "", "Rock ignores movement cues");
        foreach (string action in stone.ToyActions)
        {
            stone.Act(action, 0.9);
            for (int i = 0; i < 24; i++) { stone.Advance(0.25); Check(stone.Position == 0.5 && !stone.Walking && stone.Velocity == 0 && stone.UpdateInterval() == 0.5, "Every Rock activity stays still on the quiet timer"); }
            Check(stone.Action == "idle", "Rock props expire, including the static box");
        }
        stone.SetMusicPlaying(false);
        int rockOutfit = stone.Outfit;
        for (int i = 0; i < 600; i++) stone.Advance(1);
        Check(stone.Action == "idle" && stone.Outfit == rockOutfit && !stone.Sleeping && stone.Position == 0.5, "Ten idle minutes cannot make Rock wander or choose autonomous activities");
        var dog = new PetMotion(() => 0, "roof");
        dog.Act("play", 0.8); dog.Advance(0.5);
        Check(dog.Walking && dog.Position > 0.5 && dog.ArtworkLayer("head") == "roofHead" && dog.ToyArtwork("play") == "toyBone", "Roof fetches using dog artwork");
        dog.Act("pet"); for (int i = 0; i < 10; i++) dog.Advance(1);
        Check(!dog.Sleeping && dog.Sitting && !dog.Walking && dog.ToyLabel("pet") == "Pet" && dog.ToyLabel("litter") == "Walk", "Roof stays awake after an interaction and uses plain action labels");
        dog.SelectKind("unknown");
        Check(dog.Kind == "puke" && dog.Action == "idle", "Unknown companion values safely select Puke");
        Check(!Array.Exists(new PetMotion(kind: "roof").ToyActions, a => a == "hide") && Array.Exists(new PetMotion(kind: "roof").ToyActions, a => a == "dig"), "Roof offers Dig instead of Box");
        var digger = new PetMotion(() => 0.25, "roof");
        digger.Act("play", 0.9); digger.Advance(0.5); digger.Act("dig");
        double digPosition = digger.Position;
        var strokes = new System.Collections.Generic.HashSet<int>();
        for (int i = 0; i < 32; i++)
        {
            digger.Advance(0.125); strokes.Add(digger.DigPawOffset);
            Check(digger.Digging && !digger.Walking && digger.Position == digPosition && digger.UpdateInterval() == 0.125 && digger.BoxOpacity == 0, "Digging stays planted and uses small strokes without a box");
        }
        Check(strokes.SetEquals(new[] { -1, 1 }), "Digging alternates its forepaws");
        digger.Advance(1);
        Check(!digger.Digging && digger.DigPawOffset == 0 && digger.Action == "idle", "Digging expires without leaving dirt or gestures");
        digger.Act("hide"); digger.Advance(0.5, true);
        Check(digger.Digging && digger.Position == digPosition && digger.UpdateInterval(true) == 0.5, "Old dog box requests become stationary digging, including reduced motion");
        digger.Act("feed");
        Check(!digger.Digging && digger.DigPawOffset == 0, "A replacement activity clears digging immediately");
        digger = new PetMotion(() => 0.25, "roof");
        for (int i = 0; i < 105; i++) digger.Advance(1);
        Check(digger.Digging && digger.BoxOpacity == 0, "Roof's spontaneous activities choose digging instead of hiding");
        foreach (bool reduced in new[] { false, true })
        {
            var roof = new PetMotion(() => 0.25, "roof"); var cat = new PetMotion(() => 0.25);
            int roofNaps = 0, catNaps = 0;
            for (int i = 0; i < 2400; i++)
            {
                roof.Advance(0.25, reduced); cat.Advance(0.25, reduced);
                if (roof.Sleeping) roofNaps++; if (cat.Sleeping) catNaps++;
                Check(roof.Action != "hide", "Roof cannot choose a cat box activity");
            }
            Check(roofNaps > 360 && roofNaps < 1200 && catNaps > 2040, "Ten minutes leave Roof mostly awake and Puke mostly asleep, with or without reduced motion");
        }
        var shortNap = new PetMotion(() => 0, "roof");
        for (int i = 0; i < 41; i++) shortNap.Advance(1);
        Check(!shortNap.Sleeping && shortNap.Transition == "" && shortNap.UpdateInterval() == 0.5, "Roof watches quietly before getting sleepy");
        shortNap.Advance(1);
        Check(shortNap.Transition == "yawn", "Roof yawns just before its later nap");
        shortNap.Advance(1); shortNap.Advance(0.5);
        Check(shortNap.Transition == "settle" && shortNap.SettleProgress == 0, "Roof's settling animation uses its own sleep timing");
        shortNap.Advance(1); shortNap.Advance(0.5);
        Check(shortNap.Sleeping, "Roof starts a nap after forty-five quiet seconds");
        for (int i = 0; i < 6; i++) shortNap.Advance(1); shortNap.SetNookOpen(true);
        for (int i = 0; i < 23; i++) shortNap.Advance(1);
        string? napSaying = shortNap.Musing;
        Check(shortNap.Sleeping && napSaying != null, "A quiet nap may still include a musing");
        shortNap.Advance(1);
        Check(!shortNap.Sleeping && shortNap.Transition == "stretch" && shortNap.Position == 0.5 && shortNap.Musing == napSaying, "Roof wakes from a thirty-second nap without moving or clearing speech");
        var musicDog = new PetMotion(() => 0.3, "roof");
        for (int i = 0; i < 45; i++) musicDog.Advance(1); musicDog.SetMusicPlaying(true);
        Check(musicDog.EnjoyingMusic && !musicDog.Sleeping, "Roof is more likely than Puke to wake when music starts");
        musicDog.SetMusicPlaying(true);
        Check(musicDog.WakeRemaining == 1.2, "Duplicate music readings do not restart the dog wake transition");
        var gamer = new PetMotion(() => 0);
        gamer.Act("game");
        double gamePosition = gamer.Position;
        var taps = new System.Collections.Generic.HashSet<int>();
        for (int i = 0; i < 40; i++) { gamer.Advance(0.125); taps.Add(gamer.GamePawOffset); Check(gamer.Sitting && !gamer.Walking && gamer.Position == gamePosition, "Gaming stays seated without travel"); }
        Check(taps.SetEquals(new[] { 0, 1 }) && gamer.UpdateInterval() == 0.125, "Gaming uses small paw taps at the gentle timer rate");
        gamer.Advance(1);
        Check(gamer.Action == "idle" && gamer.GamePawOffset == 0, "The console activity ends without a stale gesture");
        gamer.Act("game"); gamer.Advance(1, true); gamer.Act("feed");
        Check(gamer.Action == "feed" && gamer.Position == gamePosition && gamer.GamePawOffset == 0, "Reduced motion and replacement keep gaming stationary and clear the console");
        var box = new PetMotion(() => 0);
        box.Act("litter"); for (int i = 0; i < 16; i++) { box.Advance(0.25); }
        box.Act("hide");
        for (int i = 0; i < 60; i++) { box.Advance(1.0 / 60); }
        Check(box.Position > 0.32 && box.Remaining == 4.8 && box.BoxProgress == 0, "Travel does not consume the time in the box or start sinking early");
        for (int i = 0; i < 360; i++) { if (box.AtBox) { break; } box.Advance(1.0 / 60); }
        Check(box.AtBox && box.Remaining == 4.8 && !box.Walking, "Box entry waits for a complete stop at the destination");
        double boxPosition = box.Position;
        box.Advance(0.3);
        Check(box.BoxProgress > 0 && box.BoxProgress < 1, "Puke lowers into the box gradually");
        box.Advance(0.3);
        Check(Math.Abs(box.BoxProgress - 1) < 0.00001, "Puke reaches his tucked box pose");
        for (int i = 0; i < 3; i++) { box.Advance(1); }
        Check(box.BoxProgress == 1 && box.Position == boxPosition, "Box time is spent sitting still");
        box.Advance(0.6);
        Check(box.BoxProgress > 0 && box.BoxProgress < 1, "Puke rises before the box disappears");
        box.Advance(0.4);
        Check(box.BoxProgress == 0 && box.BoxOpacity > 0 && box.BoxOpacity < 1, "The empty box clears only after Puke has risen");
        box.Advance(0.25);
        Check(box.Action == "idle" && box.BoxProgress == 0 && box.BoxOpacity == 0, "Box completion clears all presentation state");
        box.Act("hide"); box.Advance(0.5); box.Act("feed");
        Check(box.Action == "feed" && box.BoxProgress == 0 && box.BoxOpacity == 0 && box.Position == boxPosition, "A new action clears the box without teleporting or stale entry");
        box.Act("litter"); for (int i = 0; i < 16; i++) { box.Advance(0.25); }
        double reducedBoxPosition = box.Position;
        box.Act("hide"); for (int i = 0; i < 5; i++) { box.Advance(1, true); }
        Check(box.Action == "idle" && box.Position == reducedBoxPosition && box.BoxOpacity == 0, "Reduced motion shows a static local box and still expires");
        var philosopher = new PetMotion(() => 0);
        for (int i = 0; i < 120; i++) { philosopher.Advance(1, true); }
        Check(philosopher.Musing == null, "Closed nooks never announce or queue quotes");
        philosopher.SetNookOpen(true);
        for (int i = 0; i < 17; i++) { philosopher.Advance(1, true); }
        Check(philosopher.Musing == null, "Opening the nook leaves a quiet interval first");
        philosopher.SetNookOpen(false);
        for (int i = 0; i < 120; i++) { philosopher.Advance(1, true); }
        philosopher.SetNookOpen(true); philosopher.Advance(1, true);
        Check(philosopher.Musing != null && philosopher.MusingAuthor == "Puke" && philosopher.Sleeping && philosopher.UpdateInterval(true) == 0.5, "A musing uses visible nook time without waking Puke or adding faster updates");
        string? firstMusing = philosopher.Musing; double firstDuration = philosopher.MusingRemaining;
        philosopher.SetNookOpen(true);
        Check(philosopher.Musing == firstMusing && philosopher.MusingRemaining == firstDuration, "Duplicate open events do not restart a quote");
        for (int i = 0; i < 10; i++) { philosopher.Advance(1, true); }
        Check(philosopher.Musing == null && philosopher.MusingAuthor == "", "Quote and attribution clear after ten seconds");
        for (int i = 0; i < 79; i++) { philosopher.Advance(1, true); Check(philosopher.Musing == null, "Quotes have a long quiet gap"); }
        philosopher.Advance(1, true);
        Check(philosopher.Musing != null && philosopher.Musing != firstMusing, "Consecutive sayings never repeat");
        philosopher.Act("pet");
        Check(philosopher.Musing == null && philosopher.MusingAuthor == "", "Interactions immediately dismiss a musing");
        philosopher.SetNookOpen(false); philosopher.SetNookOpen(true);
        for (int i = 0; i < 12; i++) { philosopher.Advance(1, true); }
        Check(philosopher.Musing == null, "Reopening cannot bypass the quote cooldown");
        philosopher = new PetMotion(() => 0.9); philosopher.SetNookOpen(true);
        for (int i = 0; i < 30; i++) { philosopher.Advance(1, true); }
        Check(philosopher.Musing != null && philosopher.MusingAuthor != "Puke", "The collection also selects attributed philosophers");
        philosopher.SetNookOpen(false);
        Check(philosopher.Musing == null && philosopher.MusingAuthor == "", "Dismissal clears an active quote");
        philosopher.Reset();
        Check(!philosopher.NookOpen && philosopher.Musing == null, "Disable clears the quote lifecycle");
        // Quiet states retain elapsed time at 2 Hz; gestures and travel opt into faster updates.
        var quiet = new PetMotion(() => 0);
        Check(quiet.UpdateInterval() == 0.5, "Quiet cat uses two updates per second");
        for (int i = 0; i < 6; i++) { quiet.Advance(0.5); }
        Check(quiet.Time == 3 && quiet.Transition == "yawn" && quiet.UpdateInterval() == 0.125, "Slow idle timer reaches the yawn on time");
        for (int i = 0; i < 3; i++) { quiet.Advance(0.5); }
        Check(quiet.Transition == "settle" && quiet.SettleProgress == 0, "Yawn leads into settling");
        quiet.Advance(0.5);
        Check(quiet.SettleProgress > 0 && quiet.SettleProgress < 1, "Settling progresses before sleep");
        quiet.Advance(1);
        Check(quiet.Sleeping && quiet.Transition == "" && quiet.UpdateInterval() == 0.5, "Settled nap returns to the slow timer");
        double napTime = quiet.SleepTime; int napStyle = quiet.SleepStyle;
        quiet.SetMusicPlaying(true);
        Check(quiet.Sleeping && quiet.SleepingThroughMusic && !quiet.EnjoyingMusic && quiet.SleepTime == napTime, "A sleepy cat can keep its nap when music starts");
        quiet.SetMusicPlaying(true);
        Check(quiet.SleepStyle == napStyle && quiet.SleepTime == napTime && quiet.UpdateInterval() == 0.5, "Duplicate playback preserves the quiet nap");
        int twitchTicks = 0;
        for (int i = 0; i < 64; i++) { quiet.Advance(0.5); if (quiet.EarTwitch) { twitchTicks++; } }
        Check(twitchTicks == 4 && quiet.SleepStyle == napStyle && quiet.Position == 0.5, "Music nap has one brief ear twitch every sixteen seconds without travel");
        double continuedNap = quiet.SleepTime;
        quiet.SetMusicPlaying(false);
        Check(quiet.Sleeping && !quiet.SleepingThroughMusic && quiet.SleepTime == continuedNap, "Stopping music preserves an ongoing nap");
        quiet.SetHovered(true, 0);
        Check(quiet.Glancing && quiet.LookDirection == -1 && quiet.Sleeping && quiet.UpdateInterval() == 0.125, "Hover briefly looks toward the pointer without waking or moving");
        quiet.Advance(0.5); double glanceLeft = quiet.GlanceRemaining;
        quiet.SetHovered(true, 1);
        Check(quiet.GlanceRemaining == glanceLeft && quiet.LookDirection == -1, "Pointer motion does not prolong or reverse the glance");
        quiet.Advance(1);
        Check(!quiet.Glancing && quiet.Sleeping && quiet.UpdateInterval() == 0.5, "Holding the pointer over Puke lets him return to resting");
        quiet.SetHovered(false); quiet.SetHovered(true);
        Check(!quiet.Glancing, "Repeated hover entry respects the cooldown");
        for (int i = 0; i < 7; i++) { quiet.Advance(1); }
        quiet.SetHovered(false); quiet.SetHovered(true, 1);
        Check(quiet.Glancing && quiet.LookDirection == 1, "A later hover can look the other way");
        quiet.SetHovered(false);
        Check(!quiet.Glancing, "Pointer exit clears the reaction immediately");
        quiet.SetMusicPlaying(true); quiet.Act("pet");
        Check(!quiet.Sleeping && !quiet.SleepingThroughMusic && quiet.Action == "pet" && quiet.WakeRemaining == 0, "A click immediately replaces a music nap");
        quiet.Advance(1); quiet.Advance(1); quiet.Advance(0.5);
        Check(quiet.EnjoyingMusic && quiet.Sitting, "After a click reaction Puke joins the music");
        quiet.Act("play");
        Check(quiet.UpdateInterval() == 1.0 / 30 && quiet.UpdateInterval(true) == 0.5, "Play stays smooth while reduced motion keeps a slow timer");
        quiet.SetHovered(false); quiet.SetHovered(true);
        Check(!quiet.Glancing, "Hover never interrupts play");
        quiet = new PetMotion(() => 0.9);
        for (int i = 0; i < 12; i++) { quiet.Advance(0.5); }
        quiet.SetMusicPlaying(true);
        Check(!quiet.Sleeping && quiet.Transition == "stretch" && quiet.UpdateInterval() == 0.125, "A waking cat stretches before joining music");
        quiet.Advance(1); quiet.Advance(0.25);
        Check(quiet.Transition == "" && quiet.Sitting, "Stretch ends in a seated music reaction");
        quiet.SetMusicPlaying(false); quiet.SetMusicPlaying(true); quiet.Act("feed");
        Check(quiet.Transition == "" && quiet.WakeRemaining == 0, "A new click clears a pending stretch");
        quiet.Reset();
        Check(!quiet.Hovered && !quiet.Glancing && !quiet.SleepingThroughMusic && quiet.WakeRemaining == 0, "Reset clears hover, nap preference and transitions");
        for (int style = 0; style < 4; style++) {
            var pose = new PetMotion(() => (double)style / 4 + 0.01);
            for (int i = 0; i < 12; i++) { pose.Advance(0.5); }
            Check(pose.SleepStyle == style && pose.Sleeping, "Every resting pose can be selected");
            for (int i = 0; i < 120; i++) { pose.Advance(0.5); Check(pose.SleepStyle == style && pose.Sleeping, "A resting pose lasts for the whole nap"); }
        }
        var resting = new PetMotion(() => 0);
        for (int i = 0; i < 356; i++)
        {
            resting.Advance(0.25);
            Check(resting.Position == 0.5 && resting.Action == "idle", "No autonomous travel or chores during the first 89 seconds");
        }
        Check(resting.Sleeping && resting.SleepTime > 80, "A nap lasts through most of the idle interval");
        int sleepTicks = 0;
        resting.Reset();
        for (int i = 0; i < 2400; i++) { resting.Advance(0.25); if (resting.Sleeping) sleepTicks++; }
        Check(sleepTicks > 2040, "Puke sleeps for over 85 percent of ten idle minutes");
        resting.Act("feed");
        Check(!resting.Sleeping && resting.Action == "feed", "Manual actions wake a sleeping cat immediately");
        for (int i = 0; i < 40; i++) resting.Advance(0.25);
        Check(resting.Sleeping && resting.Action == "idle", "Puke settles back to sleep after an interaction");
        resting.SetMusicPlaying(true);
        for (int i = 0; i < 160; i++) resting.Advance(0.25);
        resting.SetMusicPlaying(false);
        for (int i = 0; i < 280; i++) resting.Advance(0.25);
        Check(resting.Sleeping && resting.Action == "idle", "Stopping music starts a fresh rest interval without overdue activity");
        resting.Act("dress");
        Check(!resting.Sleeping && resting.SleepTime == 0 && resting.Outfit == 1, "Style wakes Puke to show the new outfit");
        var settling = new PetMotion(() => 0);
        settling.Act("litter");
        for (int i = 0; i < 4; i++) settling.Advance(0.25);
        settling.SetMusicPlaying(true);
        double movingPosition = settling.Position;
        Check(settling.Action == "litter" && settling.Position == movingPosition, "Playback cannot teleport or interrupt a manual walk");
        for (int i = 0; i < 24; i++) settling.Advance(0.25);
        double seatedPosition = settling.Position;
        for (int i = 0; i < 160; i++) settling.Advance(0.25);
        Check(settling.Sitting && Math.Abs(settling.Position - seatedPosition) < 0.000001, "Music settles after a manual walk and never starts another trip");
        var smooth = new PetMotion(() => 0);
        smooth.Act("litter");
        double previousPosition = smooth.Position, previousVelocity = smooth.Velocity;
        for (int i = 0; i < 210; i++)
        {
            smooth.Advance(1.0 / 60);
            Check(smooth.Target == 0.84 && smooth.Position >= previousPosition && smooth.Position <= 0.84, "A walk keeps one destination and never rebounds or overshoots");
            Check(Math.Abs(smooth.Velocity) <= 0.30001 && Math.Abs(smooth.Velocity - previousVelocity) <= 0.025, "Walk acceleration and braking stay bounded");
            previousPosition = smooth.Position; previousVelocity = smooth.Velocity;
        }
        Check(!smooth.Walking && smooth.Velocity == 0 && Math.Abs(smooth.Position - 0.84) < 0.001, "Puke settles at its destination");
        double stoppedDistance = smooth.TravelDistance; int stoppedFrame = smooth.GaitFrame(160);
        smooth.Advance(0.2);
        Check(smooth.TravelDistance == stoppedDistance && smooth.GaitFrame(160) == stoppedFrame, "Stationary paws do not keep cycling");
        var fastFrames = new PetMotion(() => 0); var slowFrames = new PetMotion(() => 0);
        fastFrames.Act("litter"); slowFrames.Act("litter");
        for (int i = 0; i < 120; i++) fastFrames.Advance(1.0 / 120);
        for (int i = 0; i < 30; i++) slowFrames.Advance(1.0 / 30);
        Check(Math.Abs(fastFrames.Position - slowFrames.Position) < 0.0001 && fastFrames.GaitFrame(160) == slowFrames.GaitFrame(160), "Movement and gait agree at different timer rates");
        double beforeDistance = fastFrames.TravelDistance;
        fastFrames.Advance(0.25, true);
        Check(fastFrames.TravelDistance == beforeDistance && fastFrames.Velocity == 0, "Reduced motion freezes travel and gait");
        smooth.Act("hide");
        for (int i = 0; i < 15; i++) smooth.Advance(1.0 / 60);
        double reversingPosition = smooth.Position;
        smooth.Act("litter");
        Check(smooth.Position == reversingPosition, "Retargeting never teleports Puke");
        for (int i = 0; i < 120; i++) { smooth.Advance(1.0 / 60); Check(smooth.Position >= 0.08 && smooth.Position <= 0.92, "Reversals remain bounded"); }
        smooth.Reset(); Check(smooth.Velocity == 0 && smooth.TravelDistance == 0, "Disable clears velocity and gait history");
        var model = new PetMotion();
        for (int i = 0; i < 1000; i++) { model.Advance(0.1); Check(model.Position >= 0.08 && model.Position <= 0.92, "Pet wandering stays in its runway"); }
        model.Act("feed"); model.Advance(0.25); model.Act("pet");
        Check(model.Action == "pet" && model.Remaining == 2.4, "The latest pet interaction replaces the previous reaction");
        for (int i = 0; i < 10; i++) model.Advance(0.25);
        Check(model.Action == "idle" && model.Remaining == 0, "Pet reactions finish without delayed callbacks restoring old actions");
        model.Act("play", 10); Check(model.Target == 0.92, "Play target is bounded");
        var position = model.Position;
        for (int i = 0; i < 10; i++) model.Advance(0.25, true);
        Check(model.Position == position && !model.Walking && model.Action == "idle", "Reduced motion keeps the pet still while reactions expire");
        model = new PetMotion(() => 0.9); Check(model.Action == "idle" && model.Position == 0.5 && model.Time == 0, "Disabling clears transient pet state");
        for (int i = 0; i < 49; i++) model.Advance(0.25);
        Check(model.Sleeping && model.SleepTime > 0 && model.SleepStyle is >= 0 and <= 3, "Idle Puke chooses a nap animation");
        int sleepStyle = model.SleepStyle; double sleepTime = model.SleepTime;
        model.SetMusicPlaying(false); model.Advance(0.25);
        Check(model.SleepStyle == sleepStyle && model.SleepTime > sleepTime, "Duplicate stopped playback does not restart the nap");
        model.SetMusicPlaying(true);
        Check(model.EnjoyingMusic && !model.Sleeping && model.SleepTime == 0, "Music wakes Puke and clears the nap");
        model.Advance(0.25); position = model.Position; double musicTime = model.MusicTime;
        model.SetMusicPlaying(true);
        Check(model.MusicTime == musicTime && model.Position == position, "Repeated music readings do not restart the dance");
        for (int i = 0; i < 5; i++) model.Advance(0.25);
        var moves = new System.Collections.Generic.HashSet<int>();
        var pawOffsets = new System.Collections.Generic.HashSet<int>(); var headOffsets = new System.Collections.Generic.HashSet<int>();
        double dancePosition = model.Position, danceDistance = model.TravelDistance;
        for (int i = 0; i < 52; i++)
        {
            model.Advance(0.25); moves.Add(model.DanceMove);
            pawOffsets.Add(model.DancePawOffset); headOffsets.Add(model.DanceHeadOffset);
            Check(model.Sitting && !model.Walking && model.Position == dancePosition && model.TravelDistance == danceDistance, "Seated dancing never paces or cycles walking feet");
            Check(model.Position >= 0.08 && model.Position <= 0.92 && model.Action == "idle", "Music stays bounded and excludes spontaneous chores");
        }
        Check(moves.SetEquals(new[] { 0, 1 }) && pawOffsets.SetEquals(new[] { -1, 0, 1 }) && headOffsets.SetEquals(new[] { 0, 1 }), "Seated dance alternates a small paw wave and head bob");
        model.Act("feed"); model.SetMusicPlaying(true);
        Check(!model.EnjoyingMusic && model.Action == "feed", "Music updates do not override an interaction");
        for (int i = 0; i < 13; i++) model.Advance(0.25);
        Check(model.EnjoyingMusic, "Puke resumes enjoying music after a snack");
        position = model.Position; musicTime = model.MusicTime; model.Advance(0.25, true);
        Check(model.EnjoyingMusic && model.Position == position && model.MusicTime == musicTime && !model.Walking, "Reduced motion retains static music feedback");
        model.SetMusicPlaying(false); model.SetMusicPlaying(false);
        Check(!model.EnjoyingMusic && !model.Sitting && model.DancePawOffset == 0 && model.DanceHeadOffset == 0, "Paused or cleared playback stops the music reaction");
        model.SetMusicPlaying(true); model.Act("pet"); model.Reset();
        Check(!model.MusicPlaying && !model.EnjoyingMusic && model.SleepTime == 0 && model.Action == "idle", "Reset clears music and nap state as well as interactions");
        foreach (var (choice, expected) in new[] { (0.0, "play"), (0.18, "hide"), (0.35, "litter"), (0.52, "highfive"), (0.69, "groom"), (0.86, "game") })
        {
            var curious = new PetMotion(() => choice);
            for (int i = 0; i < 640 && curious.Action == "idle" && curious.Outfit == 0; i++) curious.Advance(0.25);
            Check(curious.Action == expected && curious.Outfit == 0, "Idle Puke spontaneously chooses " + expected + " without changing clothes");
            curious.Act("feed"); curious.Advance(0.25);
            Check(curious.Action == "feed", "Manual interaction replaces autonomous behavior");
        }
        var still = new PetMotion(() => 0);
        for (int i = 0; i < 640; i++) still.Advance(0.25, true);
        Check(still.Action == "idle" && still.Position == 0.5 && still.Outfit == 0, "Reduced motion suppresses spontaneous actions");
        model.Reset(); model.Act("hide");
        for (int i = 0; i < 8; i++) model.Advance(0.25);
        Check(model.Action == "hide" && Math.Abs(model.Position - 0.32) < 0.01, "Puke reaches the cardboard box");
        model.Act("litter");
        for (int i = 0; i < 10; i++) model.Advance(0.25);
        Check(model.Action == "litter" && Math.Abs(model.Position - 0.84) < 0.01, "Puke reaches the litter tray");
        model.Act("highfive"); model.Act("dress");
        Check(model.Action == "highfive" && model.Outfit == 1, "Dress-up preserves a high-five");
        for (int i = 0; i < 3; i++) model.Act("dress");
        Check(model.Outfit == 0, "Outfit cycle returns to classic");
        model.Act("play", 0.5);
        for (int i = 0; i < 5; i++) model.Advance(0.25);
        Check(model.Fumbled && model.Target != 0.5, "Yarn escapes after the first pounce");
        double escaped = model.Target; model.Advance(0.25);
        Check(model.Target == escaped, "Yarn fumbles only once per interaction");
        model.Reset(); Check(model.Outfit == 0 && !model.Fumbled && model.MusicTime == 0, "Reset clears clothes, yarn and dancing");
        Check(!new Settings().TitlebarPetEnabled, "The title-bar pet is opt-in");
        var gallery = new UniformGrid { Columns = 4 };
        foreach (string pose in new[] { "Classic", "Walk", "Bandana", "Hoodie", "Shades", "Nap", "Chin on paws", "Loaf", "Tucked tail", "Yawn", "Settling", "Stretch", "Music nap", "Ear twitch", "Hover", "High five" })
        {
            var sample = new PetMotion(() => pose == "Chin on paws" ? 0.26 : pose == "Loaf" ? 0.51 : pose == "Tucked tail" ? 0.76 : 0);
            if (pose == "Walk") { sample.Act("litter"); sample.Advance(0.25); }
            for (int i = 0; i < (pose == "Bandana" ? 1 : pose == "Hoodie" ? 2 : pose == "Shades" ? 3 : 0); i++) sample.Act("dress");
            if (pose is "Nap" or "Chin on paws" or "Loaf" or "Tucked tail" or "Music nap" or "Ear twitch" or "Hover")
                for (int i = 0; i < 24; i++) sample.Advance(0.25);
            if (pose is "Yawn" or "Settling") for (int i = 0; i < (pose == "Yawn" ? 14 : 21); i++) sample.Advance(0.25);
            if (pose is "Stretch" or "Music nap" or "Ear twitch") sample.SetMusicPlaying(true);
            if (pose == "Ear twitch") for (int i = 0; i < 58; i++) sample.Advance(0.25);
            if (pose == "Hover") sample.SetHovered(true, 0);
            if (pose == "High five") sample.Act("highfive");
            var tile = new StackPanel { Width = 128 };
            var preview = new PetDrawing(sample) { Width = 64, Height = 34 };
            System.Windows.Media.RenderOptions.SetEdgeMode(preview, System.Windows.Media.EdgeMode.Aliased);
            tile.Children.Add(new Viewbox { Child = preview, Width = 128, Height = 90, Stretch = System.Windows.Media.Stretch.Uniform });
            tile.Children.Add(new TextBlock { Text = pose, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 10) });
            gallery.Children.Add(tile);
        }
        var sheet = new Border { Child = gallery, Background = Brush("Panel"), Padding = new Thickness(12) };
        sheet.Measure(new Size(536, 300)); sheet.Arrange(new Rect(0, 0, 536, sheet.DesiredSize.Height));
        CaptureElement(sheet, Path.Combine(output, "puke-pixel-poses.png"));
        CapturePetWardrobes(output);
        var gaitGallery = new UniformGrid { Columns = 4 };
        for (int frame = 0; frame < 4; frame++)
        {
            var sample = new PetMotion(() => 0); sample.Act("litter");
            for (int tick = 0; tick < 600; tick++)
            {
                sample.Advance(1.0 / 120);
                if (sample.Walking && sample.GaitFrame(38) == frame) break;
            }
            Check(sample.Walking && sample.GaitFrame(38) == frame, "All four gait phases are reachable during travel");
            var tile = new StackPanel { Width = 176 };
            var preview = new PetDrawing(sample) { Width = 88, Height = 34 };
            System.Windows.Media.RenderOptions.SetEdgeMode(preview, System.Windows.Media.EdgeMode.Aliased);
            tile.Children.Add(new Viewbox { Child = preview, Width = 176, Height = 80, Stretch = System.Windows.Media.Stretch.Uniform });
            tile.Children.Add(new TextBlock { Text = "Step " + (frame + 1), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 10) });
            gaitGallery.Children.Add(tile);
        }
        var gaitSheet = new Border { Child = gaitGallery, Background = Brush("Panel"), Padding = new Thickness(12) };
        gaitSheet.Measure(new Size(728, 140)); gaitSheet.Arrange(new Rect(0, 0, 728, gaitSheet.DesiredSize.Height));
        CaptureElement(gaitSheet, Path.Combine(output, "puke-walk-cycle.png"));
        bool original = settings.TitlebarPetEnabled;
        string originalCompanion = settings.TitlebarCompanion;
        Check(new Settings().TitlebarCompanion == "puke", "Existing settings default to Puke");
        SetPetCompanion("puke");
        SetPetEnabled(true); Activate();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(Settings.Load().TitlebarPetEnabled && CaptionPet.IsVisible && CaptionPet.Animating, "Enabling Puke persists and starts its visible animation");
        Check(CaptionPet.AnimationInterval == 0.5, "Idle caption uses a 2 Hz timer");
        CaptionPet.PetButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(CaptionPet.Playground?.IsOpen == true && CaptionPet.Actions.Count == 9 && CaptionPet.Motion.NookOpen, "Puke opens all nine pocket-pet controls");
        var surface = (FrameworkElement)CaptionPet.Playground!.Child;
        surface.UpdateLayout();
        Check(surface.ActualWidth <= 344 && surface.ActualWidth >= 340 && surface.ActualHeight <= 416, "Illustrated nook and all nine toys fit the popup");
        Check(System.Windows.Automation.AutomationProperties.GetName(CaptionPet.PetButton).Contains("Puke"), "Pet accessibility uses Puke");
        foreach (var (action, button) in CaptionPet.Actions)
        {
            Check(button.Content is StackPanel toys && toys.Children.Count == 2 && toys.Children[0] is PetObjectArtwork,
                "Each nook action has shared pixel artwork and a visible label");
            Check(System.Windows.Automation.AutomationProperties.GetAutomationId(button) == "puke-" + action &&
                !string.IsNullOrWhiteSpace(System.Windows.Automation.AutomationProperties.GetName(button)), "Toy keyboard controls have stable accessible names");
        }
        CaptionPet.Actions["feed"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(CaptionPet.Motion.Action == "feed" && CaptionPet.Motion.Remaining == 3, "Feed starts its full snack reaction after a slow timer");
        Check(CaptionPet.AnimationInterval == (SystemParameters.ClientAreaAnimation ? 0.125 : 0.5), "An interaction immediately selects its timer cadence");
        CaptionPet.Actions["pet"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(CaptionPet.Motion.Action == "pet", "Pet interrupts feeding with a purr");
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "puke-playground.png"));
        CaptionPet.Actions["play"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(CaptionPet.Motion.Action == "play", "Play starts chasing the ball");
        Check(Math.Abs(CaptionPet.AnimationInterval - (SystemParameters.ClientAreaAnimation ? 1.0 / 30 : 0.5)) < 0.000001, "Play selects smooth updates unless motion is reduced");
        CaptionPet.Motion.Reset(); CaptionPet.SetMusicPlaying(true);
        Check(CaptionPet.Motion.EnjoyingMusic, "Enabled Puke receives playback");
        CaptionPet.Actions["dress"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(CaptionPet.Motion.Outfit == 1 && CaptionPet.Motion.EnjoyingMusic, "Style dresses Puke without interrupting music");
        CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "puke-music.png"));
        CaptionPet.Actions["dress"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        for (int i = 0; i < 18; i++) CaptionPet.Motion.Advance(0.25);
        CaptionPet.SetMusicPlaying(true);
        CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "puke-hoodie.png"));
        foreach (string action in new[] { "highfive", "hide", "litter", "game" })
        {
            CaptionPet.Actions[action].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            for (int i = 0; i < (action == "litter" ? 16 : 8); i++) CaptionPet.Motion.Advance(0.25);
            CaptionPet.SetMusicPlaying(true);
            Check(CaptionPet.Motion.Action == action, action + " button starts its reaction");
            CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "puke-" + action + ".png"));
        }
        foreach (string kind in new[] { "roof", "rock" })
        {
            CaptionPet.SetMusicPlaying(false);
            Check(FindCompanionSelector((DependencyObject)CaptionPet.Playground!.Child) == null, "Companion switching is absent from the room");
            SetPetCompanion(kind);
            await Task.Delay(250);
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Check(CaptionPet.Motion.NookOpen && Settings.Load().TitlebarCompanion == kind && CaptionPet.Motion.Kind == kind && CaptionPet.Playground?.IsOpen == true, "Settings selection persists and replaces the companion without stale popup cleanup");
            foreach (string action in CaptionPet.Motion.ToyActions)
            {
                int outfit = CaptionPet.Motion.Outfit;
                CaptionPet.Actions[action].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(action == "dress" ? CaptionPet.Motion.Outfit == (outfit + 1) % 4 : CaptionPet.Motion.Action == action, "Every selected companion action works");
            }
            CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, kind + "-playground.png"));
        }
        var outfitMenu = CaptionPet.Actions["dress"].ContextMenu;
        outfitMenu.PlacementTarget = CaptionPet.Actions["dress"];
        outfitMenu.IsOpen = true;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(CaptionPet.Playground?.IsOpen == true && outfitMenu.IsOpen, "Opening the wardrobe menu keeps the room available");
        ((MenuItem)outfitMenu.Items[2]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        outfitMenu.RaiseEvent(new RoutedEventArgs(ContextMenu.OpenedEvent));
        Check(CaptionPet.Motion.Outfit == 2 && ((MenuItem)outfitMenu.Items[2]).IsChecked && !((MenuItem)outfitMenu.Items[1]).IsChecked,
            "The wardrobe menu selects an exact outfit and marks the current choice");
        outfitMenu.IsOpen = false;
        var actualClock = CaptionPet.LocalNow;
        DateTimeOffset LocalHour(int hour) => new DateTimeOffset(new DateTime(2026, 9, 20, hour, 0, 0), TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 9, 20, hour, 0, 0)));
        DateTimeOffset roomClock = LocalHour(7);
        CaptionPet.LocalNow = () => roomClock;
        bool mediaWasPolling = mediaTimer.IsEnabled; mediaTimer.Stop();
        await Until(() => !mediaPolling);
        CaptionPet.Interact("game"); CaptionPet.SetMusicPlaying(true);
        Check(CaptionPet.Daylight.Phase == "dawn", "The open nook refreshes local lighting with existing drawing updates");
        roomClock = LocalHour(12);
        await Task.Delay(650);
        Check(CaptionPet.Daylight.Phase == "day" && CaptionPet.Motion.Action == "game" && CaptionPet.Motion.MusicPlaying, "The existing quiet timer updates lighting without resetting activity or playback");
        if (mediaWasPolling) mediaTimer.Start();
        foreach (var (hour, name) in new[] { (7, "dawn"), (12, "day"), (19, "dusk"), (23, "night") })
        {
            roomClock = LocalHour(hour); CaptionPet.Interact("feed");
            CaptureElement((FrameworkElement)CaptionPet.Playground!.Child, Path.Combine(output, "nook-" + name + ".png"));
        }
        CaptionPet.ClosePlayground(); roomClock = LocalHour(12);
        await Task.Delay(650);
        Check(CaptionPet.Daylight.Phase == "night", "The closed nook does not update its lighting");
        CaptionPet.OpenPlayground();
        Check(CaptionPet.Daylight.Phase == "day", "Reopening refreshes lighting immediately after a clock change");
        CaptionPet.LocalNow = actualClock;
        SetPetEnabled(false);
        Check(!Settings.Load().TitlebarPetEnabled && !CaptionPet.Animating && CaptionPet.Playground?.IsOpen == false && CaptionPet.Motion.Action == "idle" && !CaptionPet.Motion.MusicPlaying && !CaptionPet.Motion.NookOpen && CaptionPet.Motion.Musing == null, "Disabling persists, dismisses the playground, stops animation, and clears reactions");
        Check(Settings.Load().TitlebarCompanion == "rock", "Disabling retains the selected companion");
        SetPetCompanion("puke"); SetPetEnabled(true); Width = 1280;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        // Windows can constrain the requested width to the CI display's work area.
        double wideWindow = ActualWidth, widePet = CaptionPet.ActualWidth;
        Check(widePet >= 80 && widePet <= 288, $"Companion space stays bounded at window width {wideWindow}: {widePet}");
        Capture(Path.Combine(output, "puke-caption-wide.png"));
        Width = 720;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(wideWindow > ActualWidth && widePet > CaptionPet.ActualWidth,
            $"Companion space grows with the available window: {wideWindow}/{widePet} versus {ActualWidth}/{CaptionPet.ActualWidth}");
        Check(CaptionPet.ActualWidth >= 80 && CaptionPet.TranslatePoint(new Point(CaptionPet.ActualWidth, 0), this).X <= CaptionActions.TranslatePoint(new Point(), this).X,
            "Puke has bounded play space without covering navigation at minimum width");
        Check(!NativeChildAt(this, CaptionPet.TranslatePoint(new Point(20, 18), this)) && CloseButton.IsVisible, "The pet stays in reachable title-bar space with window controls visible");
        Capture(Path.Combine(output, "puke-caption-narrow.png"));
        Hide(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(!CaptionPet.Animating, "A hidden Relay window stops pet animation");
        Show(); Activate();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        Check(CaptionPet.Animating, "Showing Relay resumes one pet animation timer");
        SetPetCompanion(originalCompanion); SetPetEnabled(original); Width = 1280;
    }
    private static ComboBox? FindCompanionSelector(DependencyObject parent)
    {
        if (parent is ComboBox choice && System.Windows.Automation.AutomationProperties.GetAutomationId(choice) == "companion-selector") return choice;
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            if (FindCompanionSelector(System.Windows.Media.VisualTreeHelper.GetChild(parent, i)) is { } found) return found;
        return null;
    }

}
