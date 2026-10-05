import SwiftUI

struct GreetingView: View {
    @ObservedObject var unread: UnreadCenter
    let theme: ShellTheme
    @ViewState private var greeting = "sup, chungus"
    @ViewState private var category = Int.random(in: 0..<4)
    @ViewState private var next = Date.distantPast
    var body: some View {
        Text(greeting).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1).help(greeting)
            .task {
                guard !ProcessInfo.processInfo.arguments.contains("--snapshot-directory") else { return }
                while !Task.isCancelled {
                    if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }), Date() >= next {
                        let now = Date()
                        let count = unread.states.values.reduce(0) { $0 + $1.count }
                        let hour = Calendar.current.component(.hour, from: now)
                        let weekday = Calendar.current.component(.weekday, from: now)
                        let timeGroup = hour < 5 ? 0 : hour < 12 ? 1 : hour < 17 ? 2 : hour < 22 ? 3 : 4
                        let dayGroup = 5 + (weekday + 5) % 7
                        let unreadGroup = count >= 100 ? 12 : count >= 20 ? 13 : count > 0 ? 14 : 15
                        let group = [timeGroup, dayGroup, unreadGroup, 16][category]
                        let choices = Self.lines[group].map { $0.replacingOccurrences(of: "{n}", with: String(count)) }.filter { $0 != greeting }
                        if let choice = choices.randomElement() { greeting = choice }
                        category = (category + 1) % 4
                        next = now.addingTimeInterval(300)
                    }
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                }
            }
    }
    private static let lines: [[String]] = [
    [
        "go to bed, swamp creature",
        "the group chat is not a sleep aid",
        "even your browser wants a nap"
    ],
    [
        "morning, absolute specimen",
        "coffee first. bad takes second.",
        "rise and mildly inconvenience"
    ],
    [
        "afternoon, keyboard goblin",
        "drink water. resume nonsense.",
        "a little yap as a treat"
    ],
    [
        "evening, distinguished gremlin",
        "clock out. goblin hours begin.",
        "what’s for dinner, besides drama?"
    ],
    [
        "one more message, allegedly",
        "bedtime is a social construct. mostly.",
        "your pillow has filed a complaint"
    ],
    [
        "monday. deeply unserious behavior.",
        "new week, same goblins",
        "monday has entered without consent"
    ],
    [
        "tuesday: monday in a fake mustache",
        "a deeply tuesday situation",
        "tuesday. keep expectations moist."
    ],
    [
        "wednesday, my dudes",
        "halfway to a worse sleep schedule",
        "the week has developed a hump"
    ],
    [
        "friday’s loading screen",
        "thursday. almost socially acceptable.",
        "one more day of pretending"
    ],
    [
        "friday. release the idiots.",
        "weekend goblin pending",
        "productivity has left the chat"
    ],
    [
        "saturday. pants are a suggestion.",
        "premium nonsense hours",
        "today’s agenda: absolutely questionable"
    ],
    [
        "sunday. ignore the calendar’s threats.",
        "the sunday scaries can wait",
        "rest up, professional yapper"
    ],
    [
        "your inbox has become a municipality",
        "{n} unread. send a search party.",
        "the gang has discovered unlimited texting"
    ],
    [
        "{n} unread. the council is yapping.",
        "your notifications have unionized",
        "that chat is legally a podcast now"
    ],
    [
        "{n} unread. probably a terrible meme.",
        "the goblins request your presence",
        "someone has posted. consequences await."
    ],
    [
        "no unread reported. suspicious.",
        "a rare lull in the nonsense",
        "quiet on the goblin front"
    ],
    [
        "sup, chungus",
        "wash your buttcrack. with soap.",
        "hydrate before you elaborate",
        "posture check, shrimp",
        "clean cheeks. clear conscience.",
        "touch grass. wash ass.",
        "your chair misses the old you. stand up.",
        "floss. the teeth, not the dance."
    ]
]
}
