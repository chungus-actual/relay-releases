using System;

namespace Relay;

// Transient play state: no hunger meters, background decay, or per-frame settings writes.
public sealed class PetMotion
{
    public static readonly string[] Kinds = ["puke", "roof", "rock"];
    public static string NormalizedKind(string? value) => value?.ToLowerInvariant() is "roof" ? "roof" : value?.ToLowerInvariant() is "rock" ? "rock" : "puke";
    public string Kind { get; private set; }
    public string Name => Kind == "roof" ? "Roof" : Kind == "rock" ? "Rock" : "Puke";
    public bool IsRock => Kind == "rock";
    public string NookTitle => Name.ToLowerInvariant() + "’s place";
    private System.Collections.Generic.Dictionary<string, int> wardrobeChoices = new();
    public void SelectKind(string value)
    {
        string next = NormalizedKind(value);
        if (Kind == next) return;
        bool playing = MusicPlaying, open = NookOpen;
        var choices = wardrobeChoices;
        Kind = next; Reset(); wardrobeChoices = choices;
        Outfit = choices.TryGetValue(next, out int remembered) ? remembered : 0;
        SetMusicPlaying(playing); SetNookOpen(open);
    }
    public string ArtworkLayer(string name)
    {
        string roof = "roof" + char.ToUpperInvariant(name[0]) + name[1..];
        return Kind == "roof" && PetArtwork.Layers.ContainsKey(roof) ? roof : name;
    }
    public string[] ToyActions => ["pet", "feed", "play", "dress", "highfive", Kind == "roof" ? "dig" : "hide", "litter", "game", "groom"];
    public string ToyLabel(string action) => action switch
    {
        "pet" => IsRock ? "Admire" : "Pet", "feed" => "Feed", "play" => IsRock ? "Ponder" : "Play",
        "dress" => "Outfit", "groom" => IsRock ? "Polish" : Kind == "roof" ? "Shake" : "Groom", "highfive" => "High five", "hide" => "Box", "dig" => "Dig",
        "litter" => IsRock ? "Rinse" : Kind == "roof" ? "Walk" : "Litter", "game" => "Game", _ => action
    };
    public string ToyArtwork(string action) => action switch
    {
        "feed" or "play" when IsRock => "toyStone", "feed" when Kind == "roof" => "toyBowl", "play" when Kind == "roof" => "toyBone",
        "pet" => "toyPet", "feed" => "toyFeed", "play" => "toyPlay", "dress" => "toyDress", "highfive" => "toyHighfive",
        "hide" => "toyHide", "dig" => "toyDig", "groom" => "toyGroom", "litter" => IsRock ? "toyRinse" : Kind == "roof" ? "nookPlant" : "toyLitter", "game" => "toyGame", _ => "toyPet"
    };
    public string AccessibilityStatus => Name + (EnjoyingMusic ? " is enjoying the music" : ", " + NookStatus + " Open companion playground.");

    private readonly Func<double> random;
    public bool NookOpen { get; private set; }
    public string? Musing { get; private set; }
    public string MusingAuthor => Musing == null ? "" : PetSayings.Authors[lastMusing];
    public double MusingRemaining { get; private set; }
    private double musingWait;
    private bool musingScheduled;
    private int lastMusing = -1;
    public void SetNookOpen(bool open)
    {
        if (NookOpen == open) return;
        NookOpen = open;
        if (open && !musingScheduled) { musingWait = 18 + random() * 12; musingScheduled = true; }
        if (!open) { Musing = null; MusingRemaining = 0; }
    }
    private void Hush()
    {
        Musing = null; MusingRemaining = 0;
        if (NookOpen) musingWait = Math.Max(musingWait, 30);
    }
    private void AdvanceMusings(double delta)
    {
        if (!NookOpen) return;
        MusingRemaining = Math.Max(0, MusingRemaining - delta);
        if (MusingRemaining == 0) Musing = null;
        if (Action != "idle" || Walking) return;
        musingWait = Math.Max(0, musingWait - delta);
        if (musingWait != 0 || MusingRemaining != 0 || Transition != "") return;
        var choices = new System.Collections.Generic.List<int>();
        for (int i = 0; i < PetSayings.Quotes.Length; i++) if ((PetSayings.Owners[i] == "all" || PetSayings.Owners[i] == Kind) && i != lastMusing) choices.Add(i);
        int choice = choices[(int)(random() * choices.Count)];
        lastMusing = choice; Musing = PetSayings.Quotes[choice]; MusingRemaining = 10;
        musingWait = 90 + random() * 60;
    }
    private double curiosityTime, nextCuriosity, restTime;
    private string travelMode = "";
    private bool sleepPoseChosen;
    public bool SleepingThroughMusic { get; private set; }
    public double WakeRemaining { get; private set; }
    public bool Hovered { get; private set; }
    public double GlanceRemaining { get; private set; }
    private double nextGlanceTime;
    public int LookDirection { get; private set; } = 1;
    public bool Glancing => GlanceRemaining > 0 && Action == "idle";
    private double SleepDelay => Kind == "roof" ? 45 : 6;
    public string Transition => IsRock || Action != "idle" || Walking ? "" : WakeRemaining > 0 ? "stretch" :
        MusicPlaying && !SleepingThroughMusic ? "" : restTime >= SleepDelay - 1.5 && restTime < SleepDelay ? "settle" : restTime >= SleepDelay - 3 && restTime < SleepDelay - 1.5 ? "yawn" : "";
    public double SettleProgress => Math.Clamp((restTime - (SleepDelay - 1.5)) / 1.5, 0, 1);
    public bool EarTwitch => Sleeping && SleepingThroughMusic && SleepTime % 16 >= 14.5 && SleepTime % 16 < 15.5;
    public double UpdateInterval(bool reducedMotion = false)
    {
        if (reducedMotion || IsRock) return 0.5;
        if (Walking || Action is "play" or "hide" or "litter") return 1.0 / 30;
        if (Action != "idle" || Transition != "" || Glancing || EnjoyingMusic) return 1.0 / 8;
        return 0.5;
    }
    public void SetHovered(bool value, double toward = 0.5)
    {
        if (Hovered == value) return;
        Hovered = value;
        if (!value) { GlanceRemaining = 0; return; }
        if (IsRock || Action != "idle" || Walking || Time < nextGlanceTime) return;
        LookDirection = double.IsFinite(toward) && toward < Position ? -1 : 1;
        GlanceRemaining = 1.5; nextGlanceTime = Time + 8;
    }
    private void Wake()
    {
        Hush();
        restTime = SleepTime = 0; sleepPoseChosen = SleepingThroughMusic = false;
        GlanceRemaining = 0;
    }
    // Enter only after arriving; rise before the empty box disappears.
    public double BoxProgress => Action == "hide" ? Math.Min(1, Math.Min(Math.Max(0, (4.8 - Remaining) / 0.6), Math.Max(0, (Remaining - 0.25) / 0.6))) : 0;
    public double BoxOpacity => Action == "hide" ? Math.Min(1, Remaining / 0.25) : 0;
    public bool AtBox => Action == "hide" && !Walking && Math.Abs(Position - Target) < 0.002;
    public string NookStatus => IsRock ? Action switch
    {
        "pet" => "Rock feels appreciated. Probably.", "feed" => "A smaller rock. Excellent company.",
        "play" => "A great deal is happening internally.", "highfive" => "Immovable. Respectable.",
        "hide" => "A geological specimen in storage.", "litter" => "A refreshing century of erosion.",
        "game" => "Rock is carrying the team.", "groom" => "A little polish. Still a rock.", _ => "Still here."
    } : Kind == "roof" && Action is "play" or "feed" or "litter" or "pet" or "dig" or "groom" ? Action switch
    {
        "dig" => "Nothing buried. Yet.", "groom" => "A full-body reset.", "play" => "Brought it back.", "feed" => "Gone in seconds.",
        "litter" => "So many smells. So little time.", _ => "Right behind the ears."
    } : Action switch
    {
        "pet" => "Yes. This is the spot.",
        "feed" => "Compliments to the tin opener.",
        "play" => "The yarn had it coming.",
        "highfive" => "An excellent tiny high five.",
        "hide" => "If I fits, I sits.",
        "game" => "Just one more life.",
        "groom" => "Every whisker in its place.",
        "litter" => "A little privacy, please.",
        _ => Sleeping ? SleepingThroughMusic ? "Snoozing through the soundtrack." : "Asleep." :
            Transition == "stretch" ? "One very big stretch." : Transition is "yawn" or "settle" ? "Settling in." :
            EnjoyingMusic ? "A little groove, mostly paws." : "Nothing urgent."
    };
    private const double Acceleration = 1.2;
    public double Velocity { get; private set; }
    public double TravelDistance { get; private set; }
    public int GaitFrame(double runwayPixels) => (int)(TravelDistance * Math.Max(0, runwayPixels) / 3) % 4;
    private double StoppingPoint() => Math.Clamp(Position + Velocity * Math.Abs(Velocity) / (2 * Acceleration), 0.08, 0.92);
    public PetMotion(Func<double>? random = null, string kind = "puke")
    {
        Kind = NormalizedKind(kind);
        this.random = random ?? Random.Shared.NextDouble;
        nextCuriosity = 90 + this.random() * 60;
    }
    private void ScheduleCuriosity() { curiosityTime = 0; nextCuriosity = 90 + random() * 60; }
    public double Time { get; private set; }
    public double Position { get; private set; } = 0.5;
    public double Target { get; private set; } = 0.5;
    public int Facing { get; private set; } = 1;
    public bool Walking { get; private set; }
    public string Action { get; private set; } = "idle";
    public double Remaining { get; private set; }
    public bool MusicPlaying { get; private set; }
    public bool EnjoyingMusic => !IsRock && MusicPlaying && !SleepingThroughMusic && Action == "idle";
    public double MusicTime { get; private set; }
    // Eight seconds each: a seated paw wave, then a gentle head bob.
    public int DanceMove => (int)(MusicTime / 8) % 2;
    public bool Sitting => (Action == "game" || Action == "groom" && Kind == "puke" || Action == "idle" && (EnjoyingMusic || restTime >= 1)) && !Walking && !Sleeping && WakeRemaining == 0;
    public int GroomFrame => Action == "groom" ? (int)((3.6 - Remaining) / 0.3) % 2 : 0;
    public bool Digging => Kind == "roof" && Action == "dig";
    public int DigPawOffset => Digging ? (Math.Sin((4.8 - Remaining) * 8) > 0 ? 1 : -1) : 0;
    public int GamePawOffset => Action == "game" && Math.Sin((6 - Remaining) * 5) > 0 ? 1 : 0;
    public int DancePawOffset => EnjoyingMusic && Sitting && DanceMove == 0 ? (int)Math.Round(Math.Sin(MusicTime * 2.4), MidpointRounding.AwayFromZero) : 0;
    public int DanceHeadOffset => EnjoyingMusic && Sitting && DanceMove == 1 && Math.Sin(MusicTime * 2.4) > 0 ? 1 : 0;
    public bool Fumbled { get; private set; }
    public int Outfit { get; private set; }
    public string[] OutfitNames => ["Classic", "Bandana", IsRock ? "Cap" : "Hoodie", "Shades"];
    public string OutfitName => Outfit switch { 1 => "Bandana", 2 => IsRock ? "Cap" : "Hoodie", 3 => "Shades", _ => "Classic" };
    public void SetOutfit(int outfit)
    {
        if (outfit < 0 || outfit > 3 || outfit == Outfit) return;
        Outfit = outfit; wardrobeChoices[Kind] = outfit; Wake(); WakeRemaining = 0; ScheduleCuriosity();
    }
    public string? ClothingLayer(string pose) => Outfit is 1 or 2 ? PetArtwork.Wardrobe[pose][Outfit - 1] : null;
    public bool WearingShades => EnjoyingMusic || Outfit == 3;
    public int SleepStyle { get; private set; }
    public double SleepTime { get; private set; }
    public bool Sleeping => !IsRock && (!MusicPlaying || SleepingThroughMusic) && Action == "idle" && restTime >= SleepDelay && !Walking;
    public void SetMusicPlaying(bool playing)
    {
        if (MusicPlaying == playing) return;
        bool wasSleeping = Sleeping;
        bool stayAsleep = playing && wasSleeping && random() < (Kind == "roof" ? 0.2 : 0.65);
        bool preserveNap = wasSleeping && (stayAsleep || !playing);
        MusicPlaying = playing; MusicTime = 0;
        SleepingThroughMusic = stayAsleep;
        if (!preserveNap)
        {
            Wake();
            WakeRemaining = playing && Action == "idle" && !IsRock ? 1.2 : 0;
        }
        ScheduleCuriosity();
        if (Action == "idle") { Target = StoppingPoint(); travelMode = ""; }
    }
    public void Act(string action, double? target = null)
    {
        if (Kind == "roof" && action == "hide") action = "dig";
        if (action == "dig" && Kind != "roof") return;
        if (action == "dress") { SetOutfit((Outfit + 1) % 4); return; }
        if (action is not ("pet" or "feed" or "play" or "highfive" or "hide" or "dig" or "litter" or "game" or "groom")) return;
        ScheduleCuriosity();
        Wake(); WakeRemaining = 0;
        Action = action; Remaining = action == "game" ? 6 : action == "groom" ? 3.6 : action is "hide" or "dig" or "litter" ? 4.8 : action == "feed" ? 3 : 2.4; SleepTime = 0; Fumbled = false;
        travelMode = action;
        if (action is "pet" or "feed" or "highfive" or "game" or "dig" or "groom") { Target = Position; Velocity = 0; Walking = false; }
        if (action is "hide" or "litter") Target = action == "hide" ? 0.32 : 0.84;
        if (action == "play") Target = target is { } point && double.IsFinite(point) ? Math.Clamp(point, 0.08, 0.92) : Position < 0.5 ? 0.82 : 0.18;
        if (IsRock) { Target = Position; Velocity = 0; Walking = false; }
    }
    public void Advance(double delta, bool reducedMotion = false)
    {
        if (!double.IsFinite(delta) || delta <= 0) return;
        delta = Math.Min(delta, 1); Time += delta;
        GlanceRemaining = Math.Max(0, GlanceRemaining - delta);
        WakeRemaining = Math.Max(0, WakeRemaining - delta);
        if (Action != "hide" || reducedMotion || IsRock || AtBox) Remaining = Math.Max(0, Remaining - delta);
        if (Remaining == 0) Action = "idle";
        restTime = Action == "idle" && (!MusicPlaying || SleepingThroughMusic) ? restTime + delta : 0;
        // Roof takes short naps, then watches the room again without starting travel.
        if (Kind == "roof" && Sleeping && restTime >= SleepDelay + 30)
        {
            restTime = SleepTime = 0; sleepPoseChosen = SleepingThroughMusic = false;
            GlanceRemaining = 0; WakeRemaining = 1.2;
        }
        if (!sleepPoseChosen && restTime >= SleepDelay - 1.5 && !Walking) { SleepStyle = (int)(random() * 4); sleepPoseChosen = true; }
        if (reducedMotion || IsRock) { Walking = false; Velocity = 0; SleepTime = 0; AdvanceMusings(delta); return; }
        if (Action == "idle" && !MusicPlaying)
        {
            curiosityTime += delta;
            if (curiosityTime >= nextCuriosity)
                Act(new[] { "play", Kind == "roof" ? "dig" : "hide", "litter", "highfive", "groom", "game" }[(int)(random() * 6)]);
        }
        if (EnjoyingMusic)
        {
            if (WakeRemaining == 0) MusicTime += delta;
            if (travelMode != "music") { travelMode = "music"; Target = StoppingPoint(); }
        }
        else if (Action == "idle")
        {
            // Settle where the last interaction ended; idle time never starts pacing.
            if (travelMode != "rest") { travelMode = "rest"; Target = StoppingPoint(); }
        }
        if (Action == "play" && Remaining <= 1.2 && !Fumbled)
        {
            Target = Math.Clamp(Target + Facing * 0.12, 0.08, 0.92); Fumbled = true;
        }
        double speed = Action == "play" ? 0.32 : Action is "hide" or "litter" ? 0.3 : 0.16;
        // Small integration steps keep braking and reversals stable across timer delays.
        double remainingStep = Velocity != 0 || Target != Position ? delta : 0;
        while (remainingStep > 0)
        {
            double dt = Math.Min(remainingStep, 1.0 / 120); remainingStep -= dt;
            double distance = Target - Position;
            double desired = Math.Sign(distance) * Math.Min(speed, Math.Sqrt(2 * Acceleration * Math.Abs(distance) + Acceleration * Acceleration * dt * dt) - Acceleration * dt);
            double priorVelocity = Velocity;
            Velocity += Math.Clamp(desired - Velocity, -Acceleration * dt, Acceleration * dt);
            double movement = (priorVelocity + Velocity) * 0.5 * dt;
            if (Math.Abs(movement) >= Math.Abs(distance) && Math.Sign(movement) == Math.Sign(distance))
            { movement = distance; Velocity = 0; }
            double next = Math.Clamp(Position + movement, 0.08, 0.92);
            TravelDistance += Math.Abs(next - Position); Position = next;
            if (next is 0.08 or 0.92) Velocity = 0;
        }
        Walking = Math.Abs(Velocity) > 0.0001 || Math.Abs(Target - Position) > 0.0001;
        if (Math.Abs(Velocity) > 0.0001) Facing = Velocity >= 0 ? 1 : -1;
        if (Sleeping)
        {
            SleepTime += delta;
        }
        else SleepTime = 0;
        AdvanceMusings(delta);
    }
    public void Reset()
    {
        wardrobeChoices = new();
        NookOpen = musingScheduled = false; Musing = null; MusingRemaining = musingWait = 0; lastMusing = -1;
        Time = Remaining = SleepTime = MusicTime = Velocity = TravelDistance = restTime = WakeRemaining = GlanceRemaining = nextGlanceTime = 0;
        Hovered = SleepingThroughMusic = sleepPoseChosen = false; LookDirection = 1; travelMode = ""; Position = Target = 0.5; Facing = 1; SleepStyle = Outfit = 0; Walking = MusicPlaying = Fumbled = false; Action = "idle"; ScheduleCuriosity();
    }
}
