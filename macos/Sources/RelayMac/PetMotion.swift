import Foundation

struct PetMotion {
    static let kinds = ["puke", "roof", "rock"]
    static func normalizedKind(_ value: String) -> String { kinds.contains(value.lowercased()) ? value.lowercased() : "puke" }
    private(set) var kind: String
    var name: String { kind == "roof" ? "Roof" : kind == "rock" ? "Rock" : "Puke" }
    var isRock: Bool { kind == "rock" }
    var nookTitle: String { name.lowercased() + "’s place" }
    private var wardrobeChoices: [String: Int] = [:]
    mutating func selectKind(_ value: String) {
        let next = Self.normalizedKind(value)
        guard kind != next else { return }
        let playing = musicPlaying, open = nookOpen
        let choices = wardrobeChoices
        self = PetMotion(kind: next, random: random)
        wardrobeChoices = choices; outfit = choices[next] ?? 0
        setMusicPlaying(playing); setNookOpen(open)
    }
    func artworkLayer(_ base: String) -> String {
        let roof = "roof" + base.prefix(1).uppercased() + base.dropFirst()
        return kind == "roof" && PetArtwork.layers[roof] != nil ? roof : base
    }
    var toyActions: [String] { ["pet", "feed", "play", "dress", "highfive", kind == "roof" ? "dig" : "hide", "litter", "game", "groom"] }
    func toyLabel(_ action: String) -> String {
        return ["pet": isRock ? "Admire" : "Pet", "feed": "Feed", "play": isRock ? "Ponder" : "Play", "dress": "Outfit", "groom": isRock ? "Polish" : kind == "roof" ? "Shake" : "Groom", "highfive": "High five", "hide": "Box", "dig": "Dig", "litter": isRock ? "Rinse" : kind == "roof" ? "Walk" : "Litter", "game": "Game"][action] ?? action
    }
    func toyArtwork(_ action: String) -> String {
        if isRock && ["feed", "play"].contains(action) { return "toyStone" }
        if kind == "roof" && ["feed", "play"].contains(action) { return action == "feed" ? "toyBowl" : "toyBone" }
        return ["pet": "toyPet", "feed": "toyFeed", "play": "toyPlay", "dress": "toyDress", "highfive": "toyHighfive", "hide": "toyHide", "dig": "toyDig", "groom": "toyGroom", "litter": isRock ? "toyRinse" : kind == "roof" ? "nookPlant" : "toyLitter", "game": "toyGame"][action] ?? "toyPet"
    }
    var accessibilityStatus: String { name + (enjoyingMusic ? " is enjoying the music" : ", " + nookStatus + " Open companion playground.") }

    private let random: () -> Double
    private(set) var nookOpen = false
    private(set) var musing: String?
    var musingAuthor: String { musing == nil ? "" : PetSayings.authors[lastMusing] }
    private(set) var musingRemaining = 0.0
    private var musingWait = 0.0
    private var musingScheduled = false
    private var lastMusing = -1
    mutating func setNookOpen(_ open: Bool) {
        guard nookOpen != open else { return }
        nookOpen = open
        if open && !musingScheduled { musingWait = 18 + random() * 12; musingScheduled = true }
        if !open { musing = nil; musingRemaining = 0 }
    }
    private mutating func hush() {
        musing = nil; musingRemaining = 0
        if nookOpen { musingWait = max(musingWait, 30) }
    }
    private mutating func advanceMusings(_ delta: Double) {
        guard nookOpen else { return }
        musingRemaining = max(0, musingRemaining - delta)
        if musingRemaining == 0 { musing = nil }
        guard action == "idle", !walking else { return }
        musingWait = max(0, musingWait - delta)
        guard musingWait == 0, musingRemaining == 0, transition.isEmpty else { return }
        let choices = PetSayings.quotes.indices.filter { (PetSayings.owners[$0] == "all" || PetSayings.owners[$0] == kind) && $0 != lastMusing }
        let choice = choices[Int(random() * Double(choices.count))]
        lastMusing = choice; musing = PetSayings.quotes[choice]; musingRemaining = 10
        musingWait = 90 + random() * 60
    }
    private var curiosityTime = 0.0
    private var restTime = 0.0
    private var travelMode = ""
    private var sleepPoseChosen = false
    private(set) var sleepingThroughMusic = false
    private(set) var wakeRemaining = 0.0
    private(set) var hovered = false
    private(set) var glanceRemaining = 0.0
    private var nextGlanceTime = 0.0
    private(set) var lookDirection = 1.0
    var glancing: Bool { glanceRemaining > 0 && action == "idle" }
    private var sleepDelay: Double { kind == "roof" ? 45 : 6 }
    var transition: String {
        guard !isRock, action == "idle", !walking else { return "" }
        if wakeRemaining > 0 { return "stretch" }
        guard !musicPlaying || sleepingThroughMusic else { return "" }
        if restTime >= sleepDelay - 1.5 && restTime < sleepDelay { return "settle" }
        if restTime >= sleepDelay - 3 && restTime < sleepDelay - 1.5 { return "yawn" }
        return ""
    }
    var settleProgress: Double { min(1, max(0, (restTime - (sleepDelay - 1.5)) / 1.5)) }
    var earTwitch: Bool { sleeping && sleepingThroughMusic && sleepTime.truncatingRemainder(dividingBy: 16) >= 14.5 && sleepTime.truncatingRemainder(dividingBy: 16) < 15.5 }
    func updateInterval(reducedMotion: Bool = false) -> Double {
        if reducedMotion || isRock { return 0.5 }
        if walking || ["play", "hide", "litter"].contains(action) { return 1.0 / 30 }
        if action != "idle" || !transition.isEmpty || glancing || enjoyingMusic { return 1.0 / 8 }
        return 0.5
    }
    mutating func setHovered(_ value: Bool, toward point: Double = 0.5) {
        guard hovered != value else { return }
        hovered = value
        if !value { glanceRemaining = 0; return }
        guard !isRock, action == "idle", !walking, time >= nextGlanceTime else { return }
        lookDirection = point.isFinite && point < position ? -1 : 1
        glanceRemaining = 1.5; nextGlanceTime = time + 8
    }
    private mutating func wake() {
        hush()
        restTime = 0; sleepTime = 0; sleepPoseChosen = false; sleepingThroughMusic = false
        glanceRemaining = 0
    }
    // Enter only after arriving; rise before the empty box disappears.
    var boxProgress: Double { action == "hide" ? min(1, max(0, (4.8 - remaining) / 0.6), max(0, (remaining - 0.25) / 0.6)) : 0 }
    var boxOpacity: Double { action == "hide" ? min(1, remaining / 0.25) : 0 }
    var atBox: Bool { action == "hide" && !walking && abs(position - target) < 0.002 }
    var nookStatus: String {
        if isRock { return ["pet": "Rock feels appreciated. Probably.", "feed": "A smaller rock. Excellent company.", "play": "A great deal is happening internally.", "highfive": "Immovable. Respectable.", "hide": "A geological specimen in storage.", "litter": "A refreshing century of erosion.", "game": "Rock is carrying the team.", "groom": "A little polish. Still a rock."][action] ?? "Still here." }
        if kind == "roof" {
            if action == "play" { return "Brought it back." }
            if action == "dig" { return "Nothing buried. Yet." }
            if action == "groom" { return "A full-body reset." }
            if action == "feed" { return "Gone in seconds." }
            if action == "litter" { return "So many smells. So little time." }
            if action == "pet" { return "Right behind the ears." }
        }
        switch action {
        case "pet": return "Yes. This is the spot."
        case "feed": return "Compliments to the tin opener."
        case "play": return "The yarn had it coming."
        case "highfive": return "An excellent tiny high five."
        case "hide": return "If I fits, I sits."
        case "game": return "Just one more life."
        case "groom": return "Every whisker in its place."
        case "litter": return "A little privacy, please."
        default:
            if sleeping { return sleepingThroughMusic ? "Snoozing through the soundtrack." : "Asleep." }
            if transition == "stretch" { return "One very big stretch." }
            if transition == "yawn" || transition == "settle" { return "Settling in." }
            return enjoyingMusic ? "A little groove, mostly paws." : "Nothing urgent."
        }
    }
    private let acceleration = 1.2
    private(set) var velocity = 0.0
    private(set) var travelDistance = 0.0
    func gaitFrame(runwayPixels: Double) -> Int { Int(travelDistance * max(0, runwayPixels) / 3) % 4 }
    private func stoppingPoint() -> Double { min(0.92, max(0.08, position + velocity * abs(velocity) / (2 * acceleration))) }
    private var nextCuriosity: Double
    init(kind: String = "puke", random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.kind = Self.normalizedKind(kind)
        self.random = random; nextCuriosity = 90 + random() * 60
    }
    private mutating func scheduleCuriosity() { curiosityTime = 0; nextCuriosity = 90 + random() * 60 }
    private(set) var time = 0.0
    private(set) var position = 0.5
    private(set) var target = 0.5
    private(set) var facing = 1.0
    private(set) var walking = false
    private(set) var action = "idle"
    private(set) var remaining = 0.0
    private(set) var musicPlaying = false
    var enjoyingMusic: Bool { !isRock && musicPlaying && !sleepingThroughMusic && action == "idle" }
    private(set) var musicTime = 0.0
    // Eight seconds each: a seated paw wave, then a gentle head bob.
    var danceMove: Int { Int(musicTime / 8) % 2 }
    var sitting: Bool { (action == "game" || action == "groom" && kind == "puke" || action == "idle" && (enjoyingMusic || restTime >= 1)) && !walking && !sleeping && wakeRemaining == 0 }
    var groomFrame: Int { action == "groom" ? Int((3.6 - remaining) / 0.3) % 2 : 0 }
    var digging: Bool { kind == "roof" && action == "dig" }
    var digPawOffset: Int { digging ? (sin((4.8 - remaining) * 8) > 0 ? 1 : -1) : 0 }
    var gamePawOffset: Int { action == "game" && sin((6 - remaining) * 5) > 0 ? 1 : 0 }
    var dancePawOffset: Int { enjoyingMusic && sitting && danceMove == 0 ? Int(sin(musicTime * 2.4).rounded()) : 0 }
    var danceHeadOffset: Int { enjoyingMusic && sitting && danceMove == 1 && sin(musicTime * 2.4) > 0 ? 1 : 0 }
    private(set) var fumbled = false
    private(set) var outfit = 0
    var outfitNames: [String] { ["Classic", "Bandana", isRock ? "Cap" : "Hoodie", "Shades"] }
    var outfitName: String { outfitNames[outfit] }
    mutating func setOutfit(_ outfit: Int) {
        guard (0...3).contains(outfit), outfit != self.outfit else { return }
        self.outfit = outfit; wardrobeChoices[kind] = outfit; wake(); wakeRemaining = 0; scheduleCuriosity()
    }
    func clothingLayer(_ pose: String) -> String? { (1...2).contains(outfit) ? PetArtwork.wardrobe[pose]![outfit - 1] : nil }
    var wearingShades: Bool { enjoyingMusic || outfit == 3 }
    private(set) var sleepStyle = 0
    private(set) var sleepTime = 0.0
    var sleeping: Bool { !isRock && (!musicPlaying || sleepingThroughMusic) && action == "idle" && restTime >= sleepDelay && !walking }
    mutating func setMusicPlaying(_ playing: Bool) {
        guard musicPlaying != playing else { return }
        let wasSleeping = sleeping
        let stayAsleep = playing && wasSleeping && random() < (kind == "roof" ? 0.2 : 0.65)
        let preserveNap = wasSleeping && (stayAsleep || !playing)
        musicPlaying = playing; musicTime = 0
        sleepingThroughMusic = stayAsleep
        if !preserveNap {
            wake()
            wakeRemaining = playing && action == "idle" && !isRock ? 1.2 : 0
        }
        scheduleCuriosity()
        if action == "idle" { target = stoppingPoint(); travelMode = "" }
    }
    mutating func act(_ action: String, target: Double? = nil) {
        let action = kind == "roof" && action == "hide" ? "dig" : action
        if action == "dig" && kind != "roof" { return }
        if action == "dress" { setOutfit((outfit + 1) % 4); return }
        guard ["pet", "feed", "play", "highfive", "hide", "dig", "litter", "game", "groom"].contains(action) else { return }
        scheduleCuriosity()
        wake(); wakeRemaining = 0
        self.action = action; remaining = action == "game" ? 6 : action == "groom" ? 3.6 : action == "hide" || action == "dig" || action == "litter" ? 4.8 : action == "feed" ? 3 : 2.4; sleepTime = 0; fumbled = false
        travelMode = action
        if action == "pet" || action == "feed" || action == "highfive" || action == "game" || action == "dig" || action == "groom" { self.target = position; velocity = 0; walking = false }
        if action == "hide" || action == "litter" { self.target = action == "hide" ? 0.32 : 0.84 }
        if action == "play" {
            self.target = target.flatMap { $0.isFinite ? min(0.92, max(0.08, $0)) : nil } ?? (position < 0.5 ? 0.82 : 0.18)
        }
        if isRock { self.target = position; velocity = 0; walking = false }
    }
    mutating func advance(_ delta: Double, reducedMotion: Bool = false) {
        guard delta.isFinite && delta > 0 else { return }
        let delta = min(delta, 1); time += delta
        glanceRemaining = max(0, glanceRemaining - delta)
        wakeRemaining = max(0, wakeRemaining - delta)
        if action != "hide" || reducedMotion || isRock || atBox { remaining = max(0, remaining - delta) }
        if remaining == 0 { action = "idle" }
        restTime = action == "idle" && (!musicPlaying || sleepingThroughMusic) ? restTime + delta : 0
        // Roof takes short naps, then watches the room again without starting travel.
        if kind == "roof" && sleeping && restTime >= sleepDelay + 30 {
            restTime = 0; sleepTime = 0; sleepPoseChosen = false; sleepingThroughMusic = false
            glanceRemaining = 0; wakeRemaining = 1.2
        }
        if !sleepPoseChosen && restTime >= sleepDelay - 1.5 && !walking { sleepStyle = Int(random() * 4); sleepPoseChosen = true }
        if reducedMotion || isRock { walking = false; velocity = 0; sleepTime = 0; advanceMusings(delta); return }
        if action == "idle" && !musicPlaying {
            curiosityTime += delta
            if curiosityTime >= nextCuriosity { act(["play", kind == "roof" ? "dig" : "hide", "litter", "highfive", "groom", "game"][Int(random() * 6)]) }
        }
        if enjoyingMusic {
            if wakeRemaining == 0 { musicTime += delta }
            if travelMode != "music" { travelMode = "music"; target = stoppingPoint() }
        } else if action == "idle" {
            // Settle where the last interaction ended; idle time never starts pacing.
            if travelMode != "rest" { travelMode = "rest"; target = stoppingPoint() }
        }
        if action == "play" && remaining <= 1.2 && !fumbled {
            target = min(0.92, max(0.08, target + facing * 0.12)); fumbled = true
        }
        let speed = action == "play" ? 0.32 : action == "hide" || action == "litter" ? 0.3 : 0.16
        // Small integration steps keep braking and reversals stable across timer delays.
        var remainingStep = velocity != 0 || target != position ? delta : 0
        while remainingStep > 0 {
            let dt = min(remainingStep, 1.0 / 120); remainingStep -= dt
            let distance = target - position
            let direction = distance == 0 ? 0.0 : distance > 0 ? 1.0 : -1.0
            let desired = direction * min(speed, sqrt(2 * acceleration * abs(distance) + acceleration * acceleration * dt * dt) - acceleration * dt)
            let priorVelocity = velocity
            velocity += min(acceleration*dt, max(-acceleration*dt, desired-velocity))
            var movement = (priorVelocity+velocity)*0.5*dt
            if abs(movement) >= abs(distance) && ((movement > 0 && distance > 0) || (movement < 0 && distance < 0) || (movement == 0 && distance == 0)) { movement = distance; velocity = 0 }
            let next = min(0.92, max(0.08, position+movement))
            travelDistance += abs(next-position); position = next
            if next == 0.08 || next == 0.92 { velocity = 0 }
        }
        walking = abs(velocity) > 0.0001 || abs(target-position) > 0.0001
        if abs(velocity) > 0.0001 { facing = velocity >= 0 ? 1 : -1 }
        if sleeping {
            sleepTime += delta
        } else { sleepTime = 0 }
        advanceMusings(delta)
    }
}
