import AppKit
import SwiftUI

@main
struct ControlChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            for mode in ["Dark", "Light"] {
                var clicks = 0
                let theme = ShellTheme(settings: AppearancePreferences(mode: mode), system: .dark)
                let host = NSHostingView(rootView: AddAccountButton(theme: theme) { clicks += 1 }
                    .frame(width: 188, height: 80))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 188, height: 80),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                // Real AppKit mouse events, confined to this offscreen fixture window.
                // The visible button occupies x=20...168, y=20...60.
                for (index, x) in [24.0, 94.0, 164.0].enumerated() {
                    let point = host.convert(NSPoint(x: x, y: 40), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        app.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard clicks == index + 1 else {
                        fputs("FAIL: \(mode) Add account click at x=\(x) produced \(clicks) actions\n", stderr)
                        exit(1)
                    }
                }
                window.close()
            }
            await checkPetPlayground(app)
            await checkDaylight()
            let pet = PetCompanion()
            pet.setActive(true, reducedMotion: false)
            try? await Task.sleep(for: .milliseconds(600))
            guard pet.isAnimating && pet.motion.time > 0 else { fatalError("Visible pet timer did not start") }
            guard pet.animationInterval == 0.5 else { fatalError("Idle pet timer must run at 2 Hz") }
            pet.setHovered(true, toward: 0)
            guard pet.motion.glancing && pet.animationInterval == 0.125 else { fatalError("Hover did not immediately speed up the timer") }
            pet.setHovered(false)
            guard !pet.motion.glancing && pet.animationInterval == 0.5 else { fatalError("Hover exit did not restore idle timer") }
            pet.setMusicPlaying(true)
            guard pet.animationInterval == 0.125 else { fatalError("Music did not immediately update timer cadence") }
            guard pet.motion.enjoyingMusic else { fatalError("Puke did not react to playback") }
            pet.setMusicPlaying(false)
            guard !pet.motion.enjoyingMusic else { fatalError("Puke kept reacting after playback cleared") }
            try? await Task.sleep(for: .milliseconds(300))
            pet.act("feed")
            guard pet.motion.remaining == 3 else { fatalError("Slow timer elapsed time shortened a new interaction") }
            pet.act("pet")
            guard pet.motion.action == "pet" else { fatalError("Newest pet action did not replace feeding") }
            try? await Task.sleep(for: .milliseconds(2700))
            guard pet.motion.action == "idle" && pet.animationInterval == 0.5 else { fatalError("Completed reaction did not restore idle cadence") }
            pet.setHovered(true)
            pet.setActive(false, reducedMotion: false)
            guard !pet.motion.hovered else { fatalError("Inactive pet retained hover state") }
            let stoppedAt = pet.motion.time
            try? await Task.sleep(for: .milliseconds(120))
            guard !pet.isAnimating && pet.motion.time == stoppedAt else { fatalError("Inactive pet animation kept running") }
            pet.setActive(true, reducedMotion: false)
            pet.act("play")
            guard pet.animationInterval == 1.0 / 30 else { fatalError("Play did not immediately select 30 Hz") }
            pet.setActive(true, reducedMotion: true)
            guard pet.animationInterval == 0.5 else { fatalError("Reduced motion timer must run at 2 Hz") }
            let stillAt = pet.motion.position
            try? await Task.sleep(for: .milliseconds(300))
            guard pet.motion.position == stillAt else { fatalError("Reduced-motion pet moved") }
            pet.setActive(false, reducedMotion: true)
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--pet-snapshots") {
                do { try renderPetSnapshots(to: ProcessInfo.processInfo.arguments[index + 1]) }
                catch { fputs("FAIL: pet snapshots: \(error)\n", stderr); exit(1) }
            }
            print("PASS: Add account left, center, and right clicks activate exactly once in dark and light themes; pet timer pause/resume, action replacement, and reduced motion")
            exit(0)
        }
        app.run()
    }

    @MainActor private static func checkDaylight() async {
        func localHour(_ hour: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: hour))! }
        var roomClock = localHour(7)
        let actor = PetCompanion(localNow: { roomClock })
        actor.selectKind("rock"); actor.setNookOpen(true); actor.setActive(true, reducedMotion: true)
        actor.act("game"); actor.setMusicPlaying(true)
        guard actor.daylight.phase == "dawn" && actor.animationInterval == 0.5 else { fatalError("The nook did not use local dawn and its quiet timer") }
        roomClock = localHour(12)
        try? await Task.sleep(for: .milliseconds(650))
        guard actor.daylight.phase == "day" && actor.motion.action == "game" && actor.motion.musicPlaying else { fatalError("Lighting failed to update independently of activity and playback") }
        roomClock = localHour(5)
        try? await Task.sleep(for: .milliseconds(650))
        guard actor.daylight.phase == "night" else { fatalError("Moving the wall clock backward did not update the room") }
        actor.setActive(false, reducedMotion: true); roomClock = localHour(19)
        try? await Task.sleep(for: .milliseconds(650))
        guard actor.daylight.phase == "night" && !actor.isAnimating else { fatalError("The inactive nook retained a lighting timer") }
        actor.setNookOpen(true)
        guard actor.daylight.phase == "dusk" else { fatalError("Reopening retained stale room lighting") }
        actor.setNookOpen(false)
        print("PASS: room lighting follows local clock changes on the existing timer, pauses while closed, and refreshes on reopening")
    }

    @MainActor private static func checkPetPlayground(_ app: NSApplication) async {
        for mode in ["Dark", "Light"] {
            let pet = PetCompanion()
            let theme = ShellTheme(settings: AppearancePreferences(mode: mode), system: .dark)
            let host = NSHostingView(rootView: AnyView(PetPlayground(companion: pet, theme: theme, reducedMotion: false)))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: 412),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: mode == "Dark" ? .darkAqua : .aqua)
            window.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            func click(_ x: Double, _ yFromTop: Double) async {
                let point = host.convert(NSPoint(x: x, y: host.isFlipped ? yFromTop : host.bounds.height - yFromTop), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    app.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            func findSelector(_ view: NSView) -> NSPopUpButton? {
                if let selector = view as? NSPopUpButton { return selector }
                return view.subviews.compactMap { findSelector($0) }.first
            }
            for kind in PetMotion.kinds {
                guard findSelector(host) == nil else { fatalError("Companion switching must stay in Settings") }
                pet.selectKind(kind)
                try? await Task.sleep(for: .milliseconds(100))
                guard pet.motion.kind == kind else { fatalError("Settings selection did not reach the companion") }
                if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--pet-snapshots") {
                    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[flag+1])
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot capture native companion controls") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode companion capture") }
                    try? png.write(to: directory.appendingPathComponent("\(kind)-native-\(mode.lowercased()).png"))
                }
                for (index, action) in pet.motion.toyActions.enumerated() {
                    let x = [66.0, 170, 274][index % 3], y = 258.0 + Double(index / 3) * 56
                    pet.act("feed"); let outfit = pet.motion.outfit
                    await click(x, y)
                    guard action == "dress" ? pet.motion.outfit == (outfit + 1) % 4 : pet.motion.action == action else {
                        fatalError("\(mode) toy \(action) did not activate at its visible position")
                    }
                }
                pet.act("feed"); await click(170, 156)
                guard pet.motion.action == "pet" else { fatalError("Clicking Puke in his nook must pet him") }
                await click(294, 186)
                guard pet.motion.action == "play" && (pet.motion.isRock ? pet.motion.target == pet.motion.position : pet.motion.target > 0.8) else { fatalError("Clicking the nook floor must place the yarn") }
                pet.motion = PetMotion(kind: kind, random: { 0.65 }); pet.setNookOpen(true)
                for _ in 0..<30 { pet.motion.advance(1, reducedMotion: true) }
                guard pet.motion.musing != nil && !pet.motion.musingAuthor.isEmpty else { fatalError("Nook did not display an attributed quote") }
                await click(170, 258)
                guard pet.motion.action == "feed" && pet.motion.musing == nil else { fatalError("Speech blocked a toy or survived an interaction") }
            }
            host.rootView = AnyView(EmptyView())
            window.close()
            try? await Task.sleep(for: .milliseconds(100))
            guard !pet.motion.nookOpen && pet.motion.musing == nil else { fatalError("Closing the nook retained its quote lifecycle") }
        }
        print("PASS: rooms omit the companion selector; nine species-specific toys, room clicks, and speech cleanup work in both themes")
    }

    @MainActor private static func renderPetSnapshots(to directory: String) throws {
        let names = ["Paw left", "Paw right", "Head up", "Head down", "Nap", "Reduced motion", "Chin on paws", "Loaf", "Tucked tail", "Yawn", "Settling", "Stretch", "Sleep through music", "Ear twitch", "Hover glance", "Start settling", "Settling loaf", "Settling tucked tail"]
        var samples: [PetMotion] = []
        for (index, _) in names.enumerated() {
            let style = index == 6 ? 1 : index == 7 || index == 16 ? 2 : index == 8 || index == 17 ? 3 : 0
            var motion = PetMotion(random: { Double(style) / 4 + 0.01 })
            if index == 4 || (6...8).contains(index) || (12...14).contains(index) {
                for _ in 0..<24 { motion.advance(0.25) }
                if index == 12 || index == 13 { motion.setMusicPlaying(true) }
                if index == 13 { for _ in 0..<58 { motion.advance(0.25) } }
                if index == 14 { motion.setHovered(true, toward: 0) }
            } else if index >= 15 {
                for _ in 0..<18 { motion.advance(0.25) }
            } else if index == 9 || index == 10 {
                for _ in 0..<(index == 9 ? 14 : 21) { motion.advance(0.25) }
            } else if index == 11 { motion.setMusicPlaying(true) }
            else {
                motion.setMusicPlaying(true)
                for _ in 0..<80 {
                    motion.advance(0.25, reducedMotion: index == 5)
                    if index == 0 && motion.dancePawOffset == -1 || index == 1 && motion.dancePawOffset == 1 ||
                        index == 2 && motion.danceMove == 1 && motion.danceHeadOffset == 0 ||
                        index == 3 && motion.danceHeadOffset == 1 || index == 5 && motion.wakeRemaining == 0 { break }
                }
            }
            samples.append(motion)
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in ["Dark", "Light"] {
            let theme = ShellTheme(settings: AppearancePreferences(mode: mode), system: .dark)
            try renderWardrobeSnapshots(to: output, theme: theme, mode: mode)
            let roomGallery = VStack(spacing: 12) {
                ForEach([7, 12, 19, 23], id: \.self) { hour in
                    VStack {
                        Text(PetDaylight(hour: hour).phase).foregroundStyle(theme.ink)
                        ZStack {
                            PetNookBackground(theme: theme, daylight: PetDaylight(hour: hour))
                            let roof = PetMotion(kind: "roof")
                            PetDrawing(motion: roof, theme: theme, large: true, reducedMotion: true)
                        }.frame(width: 312, height: 140).clipShape(RoundedRectangle(cornerRadius: 16))
                        PetObjectArtwork(name: "toyBowl", theme: theme).frame(width: 44, height: 32)
                    }
                }
            }.padding(16).background(theme.panel)
            let roomRenderer = ImageRenderer(content: roomGallery); roomRenderer.scale = 2
            guard let data = roomRenderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent("daylight-\(mode.lowercased()).png"))
            let pet = PetCompanion()
            for _ in 0..<12 { pet.motion.advance(0.5) }
            let nook = ImageRenderer(content: PetPlayground(companion: pet, theme: theme, reducedMotion: false))
            nook.scale = 3
            if let data = nook.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("nook-\(mode.lowercased()).png"))
            } else { throw CocoaError(.fileWriteUnknown) }
            for scenario in ["box", "philosophy", "gaming", "reduced-box"] {
                let actor = PetCompanion(); actor.motion = PetMotion(random: { 0.65 })
                if scenario == "philosophy" {
                    actor.setNookOpen(true)
                    for _ in 0..<30 { actor.motion.advance(1, reducedMotion: true) }
                } else if scenario == "gaming" { actor.act("game"); actor.motion.advance(0.2) }
                else {
                    actor.act("hide")
                    for _ in 0..<40 { actor.motion.advance(0.05, reducedMotion: scenario == "reduced-box") }
                }
                let picture = ImageRenderer(content: PetPlayground(companion: actor, theme: theme, reducedMotion: scenario == "reduced-box"))
                picture.scale = 3
                guard let data = picture.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output.appendingPathComponent("\(scenario)-\(mode.lowercased()).png"))
            }
            for scenario in ["dig-left", "dig-right", "dig-reduced"] {
                let actor = PetCompanion(); actor.selectKind("roof"); actor.act("dig")
                actor.motion.advance(scenario == "dig-left" ? 0.125 : 0.5, reducedMotion: scenario == "dig-reduced")
                let renderer = ImageRenderer(content: PetPlayground(companion: actor, theme: theme, reducedMotion: scenario == "dig-reduced"))
                renderer.scale = 3
                guard let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output.appendingPathComponent("\(scenario)-\(mode.lowercased()).png"))
            }
            for kind in ["roof", "rock"] {
                let poses = ["idle", "nap", "pet", "feed", "play", "highfive", kind == "roof" ? "dig" : "hide", "litter", "game", "bandana", "hoodie", "shades", "music", "philosophy"]
                var actors: [PetCompanion] = []
                for pose in poses {
                    let actor = PetCompanion(); actor.motion = PetMotion(kind: kind, random: { 0.9 })
                    if pose == "nap" { for _ in 0..<(kind == "roof" ? 45 : 6) { actor.motion.advance(1) } }
                    else if pose == "music" { actor.setMusicPlaying(true); actor.motion.advance(1) }
                    else if pose == "philosophy" { actor.setNookOpen(true); for _ in 0..<29 { actor.motion.advance(1, reducedMotion: true) } }
                    else if ["bandana", "hoodie", "shades"].contains(pose) {
                        for _ in 0..<(pose == "bandana" ? 1 : pose == "hoodie" ? 2 : 3) { actor.act("dress") }
                    } else if pose != "idle" {
                        actor.act(pose)
                        for _ in 0..<8 { actor.motion.advance(0.25) }
                    }
                    actors.append(actor)
                }
                let sheet = VStack(spacing: 8) {
                    ForEach(0..<7) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<2) { column in
                                let index = row*2+column
                                VStack {
                                    Text(poses[index]).foregroundStyle(theme.ink)
                                    PetDrawing(motion: actors[index].motion, theme: theme, large: true, reducedMotion: false)
                                        .frame(width: 312, height: 140).background(theme.card)
                                    Text(actors[index].motion.nookStatus).font(.system(size: 11)).foregroundStyle(theme.muted)
                                }
                            }
                        }
                    }
                }.padding(8).background(theme.panel)
                let renderer = ImageRenderer(content: sheet); renderer.scale = 1.5
                guard let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output.appendingPathComponent("\(kind)-\(mode.lowercased()).png"))
            }
            let gallery = VStack(spacing: 12) {
                ForEach(0..<6) { row in
                    HStack(spacing: 12) {
                        ForEach(0..<3) { column in
                            let index = row * 3 + column
                            VStack {
                                Text(names[index]).foregroundStyle(theme.ink)
                                PetDrawing(motion: samples[index], theme: theme, large: true, reducedMotion: index == 5)
                                    .frame(width: 288, height: 104)
                            }
                        }
                    }
                }
            }.padding(16).background(theme.panel)
            let renderer = ImageRenderer(content: gallery)
            renderer.scale = 2
            guard let data = renderer.nsImage?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output.appendingPathComponent("puke-\(mode.lowercased()).png"))
        }
    }
    @MainActor private static func renderWardrobeSnapshots(to output: URL, theme: ShellTheme, mode: String) throws {
        let poses = ["Standing", "Seated", "Feeding", "High five", "Groom 1", "Groom 2", "Stretch", "Curled nap", "Chin nap", "Loaf nap", "Perched nap", "Box / dig", "Groom reduced", "Litter reduced"]
        func sample(_ kind: String, _ outfit: Int, _ pose: String) -> PetMotion {
            let style = pose == "Chin nap" ? 1 : pose == "Loaf nap" ? 2 : pose == "Perched nap" ? 3 : 0
            var motion = PetMotion(kind: kind, random: { Double(style) / 4 + 0.01 })
            motion.setOutfit(outfit)
            if pose.hasSuffix("nap") { for _ in 0..<(kind == "roof" ? 45 : 6) { motion.advance(1) } }
            else if pose == "Seated" { motion.advance(1) }
            else if pose == "Stretch" { motion.setMusicPlaying(true) }
            else if pose == "Feeding" { motion.act("feed"); motion.advance(0.2) }
            else if pose == "High five" { motion.act("highfive") }
            else if pose.hasPrefix("Groom") { motion.act("groom"); motion.advance(pose == "Groom 1" ? 0.1 : 0.4, reducedMotion: pose.hasSuffix("reduced")) }
            else if pose == "Box / dig" { motion.act("hide"); for _ in 0..<20 { motion.advance(0.1) } }
            else if pose == "Litter reduced" { motion.act("litter"); motion.advance(1, reducedMotion: true) }
            return motion
        }
        for kind in PetMotion.kinds {
            let sheet = VStack(spacing: 0) {
                ForEach(poses, id: \.self) { pose in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { outfit in
                            let motion = sample(kind, outfit, pose)
                            VStack(spacing: 0) {
                                PetDrawing(motion: motion, theme: theme, large: false, reducedMotion: pose.hasSuffix("reduced"))
                                    .frame(width: 64, height: 34).scaleEffect(2).frame(width: 128, height: 68)
                                Text(motion.outfitName + " · " + pose).font(.system(size: 9)).foregroundStyle(theme.ink)
                            }.frame(width: 128)
                        }
                    }
                }
            }.padding(8).background(theme.panel)
            let renderer = ImageRenderer(content: sheet)
            guard let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent("\(kind)-wardrobe-\(mode.lowercased()).png"))
        }
    }
}
