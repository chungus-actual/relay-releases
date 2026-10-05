using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Threading;

namespace Relay;

public partial class MainWindow
{
    private readonly DispatcherTimer greetingTimer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMinutes(1) };
    private DateTime nextGreeting;
    private int greetingCategory = Random.Shared.Next(4);
    private string greeting = "sup, chungus";

    private void InitializeGreetings()
    {
        greetingTimer.Tick += (_, _) => RefreshGreeting();
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible && !quitting) { greetingTimer.Start(); RefreshGreeting(); }
            else greetingTimer.Stop();
        };
    }

    private void RefreshGreeting()
    {
        var now = DateTime.Now;
        if (now >= nextGreeting)
        {
            int unread = services.Sum(s => s.Unread ?? 0);
            var options = GreetingOptions(now, unread, greetingCategory++ % 4);
            var choices = options.Where(text => text != greeting).ToArray();
            greeting = choices.Length > 0 ? choices[Random.Shared.Next(choices.Length)] : options[0];
            nextGreeting = now.AddMinutes(5);
        }
        CaptionContext.Text = greeting;
        CaptionContext.ToolTip = greeting;
    }

    private static string[] GreetingOptions(DateTime now, int unread, int category) => category switch
    {
        0 => now.Hour switch
        {
            < 5 => ["go to bed, swamp creature", "the group chat is not a sleep aid", "even your browser wants a nap"],
            < 12 => ["morning, absolute specimen", "coffee first. bad takes second.", "rise and mildly inconvenience"],
            < 17 => ["afternoon, keyboard goblin", "drink water. resume nonsense.", "a little yap as a treat"],
            < 22 => ["evening, distinguished gremlin", "clock out. goblin hours begin.", "what’s for dinner, besides drama?"],
            _ => ["one more message, allegedly", "bedtime is a social construct. mostly.", "your pillow has filed a complaint"]
        },
        1 => now.DayOfWeek switch
        {
            DayOfWeek.Monday => ["monday. deeply unserious behavior.", "new week, same goblins", "monday has entered without consent"],
            DayOfWeek.Tuesday => ["tuesday: monday in a fake mustache", "a deeply tuesday situation", "tuesday. keep expectations moist."],
            DayOfWeek.Wednesday => ["wednesday, my dudes", "halfway to a worse sleep schedule", "the week has developed a hump"],
            DayOfWeek.Thursday => ["friday’s loading screen", "thursday. almost socially acceptable.", "one more day of pretending"],
            DayOfWeek.Friday => ["friday. release the idiots.", "weekend goblin pending", "productivity has left the chat"],
            DayOfWeek.Saturday => ["saturday. pants are a suggestion.", "premium nonsense hours", "today’s agenda: absolutely questionable"],
            _ => ["sunday. ignore the calendar’s threats.", "the sunday scaries can wait", "rest up, professional yapper"]
        },
        2 => unread switch
        {
            >= 100 => ["your inbox has become a municipality", unread + " unread. send a search party.", "the gang has discovered unlimited texting"],
            >= 20 => [unread + " unread. the council is yapping.", "your notifications have unionized", "that chat is legally a podcast now"],
            > 0 => [unread + " unread. probably a terrible meme.", "the goblins request your presence", "someone has posted. consequences await."],
            _ => ["no unread reported. suspicious.", "a rare lull in the nonsense", "quiet on the goblin front"]
        },
        _ => ["sup, chungus", "wash your buttcrack. with soap.", "hydrate before you elaborate", "posture check, shrimp", "clean cheeks. clear conscience.", "touch grass. wash ass.", "your chair misses the old you. stand up.", "floss. the teeth, not the dance."]
    };
}
