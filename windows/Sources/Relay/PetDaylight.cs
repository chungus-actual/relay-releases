using System;

namespace Relay;

// Local wall-clock time, independent of animation time and the app's color scheme.
public readonly record struct PetDaylight
{
    public string Phase { get; }
    public PetDaylight(int hour)
    {
        Phase = ((hour % 24 + 24) % 24) switch
        {
            >= 6 and < 8 => "dawn", >= 8 and < 18 => "day", >= 18 and < 20 => "dusk", _ => "night"
        };
    }
    public static PetDaylight At(DateTimeOffset date, TimeZoneInfo? zone = null) => new(TimeZoneInfo.ConvertTime(date, zone ?? TimeZoneInfo.Local).Hour);
    public string WindowArtwork => Phase switch { "dawn" => "nookWindowDawn", "day" => "nookWindowDay", "dusk" => "nookWindowDusk", _ => "nookWindow" };
    public string GlowHex => Phase switch { "dawn" => "F2B388", "day" => "FFE4A8", "dusk" => "ED936F", _ => "92ACE8" };
    public double WallOpacity => Phase == "night" ? 0.08 : Phase == "day" ? 0.06 : 0.10;
    public double FloorOpacity => Phase == "night" ? 0.08 : Phase == "day" ? 0.15 : 0.18;
    public double BeamOpacity => Phase == "night" ? 0.035 : Phase == "day" ? 0.12 : 0.10;
}
