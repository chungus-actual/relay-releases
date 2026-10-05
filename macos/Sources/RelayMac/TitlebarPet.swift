import SwiftUI
import AppKit

@MainActor
final class PetCompanion: ObservableObject {
    @Published var motion = PetMotion()
    @Published private(set) var daylight: PetDaylight
    private let localNow: () -> Date
    init(localNow: @escaping () -> Date = { Date() }) {
        self.localNow = localNow; daylight = .at(localNow())
    }
    private func refreshDaylight() {
        guard motion.nookOpen else { return }
        let next = PetDaylight.at(localNow())
        if daylight != next { daylight = next }
    }
    private var timer: Timer?
    var isAnimating: Bool { timer != nil }
    var animationInterval: Double? { timer?.timeInterval }
    private var active = false
    private var reducedMotion = false
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    func setActive(_ active: Bool, reducedMotion: Bool) {
        guard self.active != active || self.reducedMotion != reducedMotion else { return }
        timer?.invalidate(); timer = nil
        self.active = active; self.reducedMotion = reducedMotion
        if !active { motion.setHovered(false); motion.setNookOpen(false); return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        syncTimer()
    }
    private func advanceToNow() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        motion.advance(now - lastFrame, reducedMotion: reducedMotion); lastFrame = now
        refreshDaylight()
    }
    private func syncTimer() {
        guard active else { return }
        let interval = motion.updateInterval(reducedMotion: reducedMotion)
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advanceToNow(); self.syncTimer()
            }
        }
        timer.tolerance = interval >= 0.5 ? 0.025 : 0.005
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func setNookOpen(_ open: Bool) {
        guard motion.nookOpen != open else { return }
        advanceToNow(); motion.setNookOpen(open); refreshDaylight(); syncTimer()
    }
    func setMusicPlaying(_ playing: Bool) {
        guard motion.musicPlaying != playing else { return }
        advanceToNow(); motion.setMusicPlaying(playing); syncTimer()
    }
    func setHovered(_ hovered: Bool, toward point: Double = 0.5) {
        guard motion.hovered != hovered else { return }
        advanceToNow(); motion.setHovered(hovered, toward: point); syncTimer()
    }
    func selectKind(_ kind: String) {
        guard motion.kind != PetMotion.normalizedKind(kind) else { return }
        advanceToNow(); motion.selectKind(kind); syncTimer()
    }
    func act(_ action: String, target: Double? = nil) {
        advanceToNow(); motion.act(action, target: target); syncTimer()
    }
    func chooseOutfit(_ outfit: Int) {
        guard motion.outfit != outfit else { return }
        advanceToNow(); motion.setOutfit(outfit); syncTimer()
    }
    deinit { timer?.invalidate() }
}

@MainActor
struct TitlebarPet: View {
    let theme: ShellTheme
    let musicPlaying: Bool
    let selectedCompanion: String
    @StateObject private var companion = PetCompanion()
    @ViewState private var presented = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        Button { presented.toggle() } label: {
            GeometryReader { geometry in
                PetDrawing(motion: companion.motion, theme: theme, large: false, reducedMotion: reducedMotion)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): companion.setHovered(true, toward: (Double(point.x) - 25) / max(1, Double(geometry.size.width) - 50))
                        case .ended: companion.setHovered(false)
                        }
                    }
            }.frame(height: 34)
        }.buttonStyle(.plain).help(companion.motion.name).accessibilityLabel(companion.motion.accessibilityStatus)
            .popover(isPresented: $presented, arrowEdge: .top) { playground }
            .onChange(of: selectedCompanion, initial: true) { _, kind in companion.selectKind(kind) }
            .onChange(of: musicPlaying, initial: true) { _, playing in companion.setMusicPlaying(playing) }
            .onAppear { companion.setActive(phase == .active, reducedMotion: reducedMotion) }
            .onChange(of: phase) { _, value in
                companion.setActive(value == .active, reducedMotion: reducedMotion)
                if value != .active { presented = false }
            }
            .onChange(of: presented) { _, value in
                companion.setNookOpen(value)
                if !value { companion.setHovered(false) }
            }
            .onChange(of: reducedMotion) { _, value in companion.setActive(phase == .active, reducedMotion: value) }
            .onDisappear { presented = false; companion.setActive(false, reducedMotion: reducedMotion) }
    }
    private var playground: some View {
        PetPlayground(companion: companion, theme: theme, reducedMotion: reducedMotion)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .onExitCommand { presented = false }
    }
}

@MainActor
struct PetPlayground: View {
    @ObservedObject var companion: PetCompanion
    let theme: ShellTheme
    let reducedMotion: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(companion.motion.nookTitle).font(.system(size: 20, weight: .medium, design: .serif))
                Text(companion.motion.nookStatus).font(.system(size: 11)).foregroundStyle(theme.muted)
            }.frame(width: 312, height: 40, alignment: .leading).padding(.bottom, 12)
            ZStack {
                PetNookBackground(theme: theme, daylight: companion.daylight)
                PetDrawing(motion: companion.motion, theme: theme, large: true, reducedMotion: reducedMotion)
            }.frame(width: 312, height: 140).contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): companion.setHovered(true, toward: (Double(point.x) - 50) / 212)
                    case .ended: companion.setHovered(false)
                    }
                }
                .onTapGesture { point in
                    let catX = 50 + companion.motion.position * 212
                    if abs(point.x-catX) < 44 && point.y > 54 { companion.act("pet") }
                    else { companion.act("play", target: (Double(point.x) - 50) / 212) }
                }.accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                    if let saying = companion.motion.musing {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“" + saying + "”").font(.system(size: 11, design: .serif)).fixedSize(horizontal: false, vertical: true)
                            Text("— " + companion.motion.musingAuthor).font(.system(size: 9)).foregroundStyle(theme.muted)
                        }.foregroundStyle(theme.ink).padding(8).frame(width: 178, alignment: .leading)
                            .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line))
                            .padding(8).allowsHitTesting(false)
                            .accessibilityElement(children: .ignore).accessibilityLabel(companion.motion.name + " says: " + saying + ", by " + companion.motion.musingAuthor)
                    }
                }
            Text("things to do").font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.muted).frame(width: 312, height: 24)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(companion.motion.toyActions.dropFirst(row * 3).prefix(3), id: \.self) { toy($0) }
                }.frame(height: 56)
            }
        }.frame(width: 312).padding(14).background(theme.panel).foregroundStyle(theme.ink)
            .onAppear { companion.setNookOpen(true) }
            .onDisappear { companion.setNookOpen(false) }
    }
    private func toy(_ action: String) -> some View {
        let label = companion.motion.toyLabel(action)
        let art = companion.motion.toyArtwork(action)
        let accessible = label + ", " + companion.motion.name
        return Button { companion.act(action) } label: {
            VStack(spacing: 2) {
                PetObjectArtwork(name: art, theme: theme).frame(width: 33, height: 24)
                Text(label).font(.system(size: 11, weight: .medium, design: .rounded))
            }.frame(maxWidth: .infinity).frame(height: 54)
        }.buttonStyle(PetToyButtonStyle(theme: theme, selected: companion.motion.action == action))
            .contextMenu {
                if action == "dress" {
                    ForEach(0..<4, id: \.self) { outfit in
                        Button { companion.chooseOutfit(outfit) } label: {
                            if companion.motion.outfit == outfit { Label(companion.motion.outfitNames[outfit], systemImage: "checkmark") }
                            else { Text(companion.motion.outfitNames[outfit]) }
                        }
                    }
                }
            }
            .help(action == "dress" ? "Outfit: " + companion.motion.outfitName + ". Click to cycle; right-click to choose." : accessible)
            .accessibilityLabel(action == "dress" ? accessible + ", currently " + companion.motion.outfitName : accessible)
            .accessibilityIdentifier("puke-" + action)
    }
}

private struct PetToyButtonStyle: ButtonStyle {
    let theme: ShellTheme
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Toy(configuration: configuration, theme: theme, selected: selected)
    }
    private struct Toy: View {
        let configuration: Configuration
        let theme: ShellTheme
        let selected: Bool
        @ViewState private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(theme.ink)
                .background(hovered || selected ? theme.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
                .opacity(configuration.isPressed ? 0.65 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onHover { hovered = $0 }
        }
    }
}

struct PetObjectArtwork: View {
    private static let colors: [Color?] = PetArtwork.palette.map { $0 == "accent" ? nil : Color(hex: $0) }
    let name: String
    let theme: ShellTheme
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 44, y: size.height / 32)
            for pixel in PetArtwork.layers[name] ?? [] {
                context.fill(Path(CGRect(x: pixel.x, y: pixel.y, width: pixel.width, height: 1)),
                    with: .color(Self.colors[pixel.color] ?? theme.accent), style: FillStyle(antialiased: false))
            }
        }.accessibilityHidden(true)
    }
}

struct PetNookBackground: View {
    let theme: ShellTheme
    let daylight: PetDaylight
    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.card
            Color(hex: daylight.glowHex).opacity(daylight.wallOpacity)
            Rectangle().fill(theme.soft).frame(height: 38).offset(y: 102)
            Rectangle().fill(Color(hex: daylight.glowHex).opacity(daylight.floorOpacity)).frame(height: 38).offset(y: 102)
            Path { path in
                path.move(to: CGPoint(x: 38, y: 66)); path.addLine(to: CGPoint(x: 91, y: 66))
                path.addLine(to: CGPoint(x: 170, y: 140)); path.addLine(to: CGPoint(x: 73, y: 140)); path.closeSubpath()
            }.fill(Color(hex: daylight.glowHex).opacity(daylight.beamOpacity))
            PetObjectArtwork(name: daylight.windowArtwork, theme: theme).frame(width: 88, height: 64).offset(x: 20, y: 10)
            PetObjectArtwork(name: "nookPlant", theme: theme).frame(width: 44, height: 32).offset(x: 258, y: 70)
            Ellipse().fill(Color(hex: "DB8A7A").opacity(theme.dark ? 0.22 : 0.2))
                .frame(width: 160, height: 22).offset(x: 76, y: 110)
            Ellipse().strokeBorder(Color(hex: "DB8A7A").opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 146, height: 14).offset(x: 83, y: 114)
        }.frame(width: 312, height: 140)
    }
}

struct PetDrawing: View {
    let motion: PetMotion
    let theme: ShellTheme
    let large: Bool
    let reducedMotion: Bool
    private let cream = Color(hex: "FFF0CE"), pink = Color(hex: "DB8A7A"), ink = Color(hex: "49313D")
    private static let colors: [Color?] = PetArtwork.palette.map { $0 == "accent" ? nil : Color(hex: $0) }
    private func layer(_ context: inout GraphicsContext, _ name: String, dx: Int = 0, dy: Int = 0) {
        for pixel in PetArtwork.layers[motion.artworkLayer(name)] ?? [] {
            context.fill(Path(CGRect(x: Double(pixel.x+dx),y: Double(pixel.y+dy),width: Double(pixel.width),height: 1)),
                         with: .color(Self.colors[pixel.color] ?? theme.accent), style: FillStyle(antialiased: false))
        }
    }
    var body: some View {
        Canvas { context, size in
            let reducedMotion = reducedMotion || motion.isRock
            let scale = large ? 2.0 : 1.0
            let x = (25 * scale + motion.position * max(0, size.width - 50 * scale)).rounded()
            let floor = large ? size.height - 23 : size.height - 1
            let sleeping = motion.sleeping
            let resting = sleeping || motion.transition == "settle"
            let stretching = motion.transition == "stretch" && !reducedMotion
            let yawning = motion.transition == "yawn" && !reducedMotion
            func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Path {
                Path(ellipseIn: CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2))
            }
            context.fill(ellipse(x, floor, 15*scale, 2*scale), with: .color(.black.opacity(0.15)))
            let hiding = motion.atBox || reducedMotion && motion.action == "hide"
            let boxProgress = reducedMotion && hiding ? 1.0 : motion.boxProgress
            let boxX = (25*scale + (reducedMotion ? motion.position : motion.target)*max(0, size.width-50*scale)).rounded()
            func boxLayer(_ name: String) {
                var box = context
                box.opacity = reducedMotion ? 1 : motion.boxOpacity
                box.translateBy(x: boxX - 22*scale, y: floor - 32*scale)
                box.scaleBy(x: scale, y: scale)
                layer(&box, name)
            }
            if motion.action == "hide" { boxLayer("boxBack") }
            let littering = motion.kind == "puke" && motion.action == "litter" && (reducedMotion || abs(motion.position - motion.target) < 0.04)
            let sitting = motion.sitting || hiding
            let dancing = motion.enjoyingMusic && sitting && !reducedMotion
            let waving = dancing && motion.danceMove == 0
            let raisingPaw = motion.action == "highfive" || waving
            let gaitFrame = !reducedMotion && motion.walking ? 1 + motion.gaitFrame(runwayPixels: size.width/scale-50) : 0
            let feet = PetArtwork.gait[gaitFrame]
            let dig = reducedMotion ? 0 : motion.digPawOffset
            let gesture = !reducedMotion && (motion.action == "highfive" || littering) && sin(motion.time*8) > 0 ? 1 : 0
            let bob = !reducedMotion && (motion.action == "play") && sin(motion.time*7) > 0 ? 1 : 0
            let breath = sleeping && !reducedMotion && sin(motion.sleepTime*0.7) > 0 ? 1 : 0
            let groom = reducedMotion ? 0 : motion.groomFrame
            let shake = motion.action == "groom" && motion.kind == "roof" && !reducedMotion ? (groom == 0 ? -1 : 1) : 0
            let crouch = motion.isRock ? 0 : hiding ? Int((6 * boxProgress).rounded()) : littering ? 2 : 0
            var cat = context
            cat.clip(to: Path(CGRect(x: 0,y: 0,width: size.width,height: floor+(hiding ? 0 : 2*scale))))
            cat.translateBy(x: x,y: floor+Double(crouch-bob)*scale)
            cat.scaleBy(x: scale*motion.facing,y: scale); cat.translateBy(x: -22,y: -32)
            if motion.digging { layer(&cat, "digPatch") }
            if motion.isRock {
                layer(&cat, "rockBody"); layer(&cat, "rockEyes")
                if motion.outfit == 1 { layer(&cat, "rockBandana") }
                if motion.outfit == 2 { layer(&cat, "rockHoodie") }
                if motion.outfit == 3 { layer(&cat, "rockShades") }
                if motion.action == "groom" { layer(&cat, "groomSparkle") }
                if motion.action == "game" { layer(&cat, "gameConsole") }
            } else {
                let progress = sleeping || reducedMotion ? 1.0 : motion.settleProgress
                let startingToSettle = resting && progress < 0.5
                let wardrobePose = resting ? (startingToSettle ? "sitting" : ["curl", "chin", "loaf", "perch"][motion.sleepStyle]) :
                    stretching ? "stretching" : sitting ? "sitting" : "standing"
                let clothing = motion.clothingLayer(wardrobePose)
                func coat(_ context: inout GraphicsContext) {
                    if motion.outfit == 2, let clothing { layer(&context, clothing, dy: resting ? -breath : 0) }
                }
                if resting {
                    let body = startingToSettle ? "sitBody" : motion.sleepStyle == 2 ? "loafBody" : motion.sleepStyle == 3 ? "sitBody" : "sleepBody"
                    layer(&cat, body, dy: -breath)
                    coat(&cat)
                } else if stretching {
                    layer(&cat, "tail")
                    layer(&cat, "hind")
                    layer(&cat, "stretchBody")
                    coat(&cat)
                    layer(&cat, "stretchFront")
                } else if sitting {
                    layer(&cat, hiding ? "tuckedTail" : "sitTail")
                    layer(&cat, "sitBody")
                    coat(&cat)
                    if !waving && motion.action != "groom" { layer(&cat, "sitFront") }
                } else {
                    let flick = !reducedMotion && (motion.walking ? sin(motion.time*2) > 0 : motion.time.truncatingRemainder(dividingBy: 24) > 23.5) ? 1 : 0
                    layer(&cat, "tail", dx: flick - shake)
                    layer(&cat, "backHind", dx: feet[0].x, dy: feet[0].y); layer(&cat, "backFront", dx: feet[1].x + dig, dy: feet[1].y - max(0, dig))
                    layer(&cat, "body")
                    coat(&cat)
                    layer(&cat, "hind", dx: feet[2].x, dy: feet[2].y)
                    if !raisingPaw { layer(&cat, "front", dx: feet[3].x - dig, dy: feet[3].y + min(0, dig)) }
                }
                let restHeadX = [-5, -2, -3, -4][motion.sleepStyle]
                let restHeadY = [8, 9, 5, 3][motion.sleepStyle]
                let glance = motion.glancing && !reducedMotion ? Int(motion.lookDirection * motion.facing) : 0
                let headX = (resting ? Int((-4 + Double(restHeadX + 4) * progress).rounded()) : sitting ? -4 : 0) + glance + shake
                let headY = (resting ? Int((Double(restHeadY) * progress).rounded()) : hiding ? -Int((4 * boxProgress).rounded()) : motion.digging ? 3 : motion.action == "game" ? 1 : stretching ? 5 : dancing ? motion.danceHeadOffset : motion.action == "feed" && !reducedMotion ? 1+(sin(motion.time*12) > 0 ? 1 : 0) : 0) - (glance == 0 ? 0 : 1)
                layer(&cat, motion.earTwitch && !reducedMotion ? "headTwitch" : "head", dx: headX, dy: headY)
                let closed = yawning || ["pet", "groom"].contains(motion.action) || (!reducedMotion && motion.time.truncatingRemainder(dividingBy: 8) > 7.8)
                layer(&cat, resting && !motion.glancing ? "sleepEyes" : closed ? "closed" : "eyes", dx: headX, dy: headY)
                layer(&cat, "nose", dx: headX, dy: headY); layer(&cat, "whiskers", dx: headX, dy: headY)
                if yawning { layer(&cat, "yawnMouth", dx: headX, dy: headY) }
                if motion.outfit == 3 || motion.wearingShades && !resting { layer(&cat, "shades", dx: headX, dy: headY) }
                if motion.outfit == 1, let clothing {
                    layer(&cat, clothing, dy: resting ? -breath : hiding ? -Int((4 * boxProgress).rounded()) : 0)
                }
                if motion.action == "groom" {
                    if motion.kind == "puke" {
                        layer(&cat, "groomPaw", dx: 1, dy: -groom * 4)
                        if groom == 0 { layer(&cat, "groomTongue") }
                    } else { layer(&cat, "shakeMarks", dx: shake) }
                }
                if !resting && raisingPaw {
                    let pawX = sitting ? -4 + motion.dancePawOffset : 0
                    layer(&cat, "raisedFront", dx: pawX, dy: -gesture)
                    layer(&cat, "paw", dx: pawX + 2, dy: -2-gesture)
                }
                if motion.digging { layer(&cat, "digDirt", dx: dig, dy: -abs(dig)) }
                if motion.action == "game" {
                    layer(&cat, "gameConsole")
                    layer(&cat, "gamePaws", dy: reducedMotion ? 0 : motion.gamePawOffset)
                }
                if resting {
                    layer(&cat, startingToSettle ? "sitTail" : motion.sleepStyle >= 2 ? "tuckedTail" : "sleepTail")
                    if motion.sleepStyle == 1 { layer(&cat, "chinPaws") }
                }
            }
            if motion.action == "litter" && motion.kind == "puke" {
                let trayX = 25*scale + (reducedMotion ? motion.position : 0.84)*max(0, size.width-50*scale)
                let tray = Path(roundedRect: CGRect(x: trayX-16*scale,y: floor-7*scale,width: 32*scale,height: 11*scale), cornerRadius: 3)
                context.fill(tray, with: .color(theme.card)); context.stroke(tray, with: .color(theme.line), lineWidth: 1)
                context.fill(Path(roundedRect: CGRect(x: trayX-13*scale,y: floor-6*scale,width: 26*scale,height: 5*scale), cornerRadius: 2), with: .color(Color(hex: "B8AA92")))
                for grain in 0..<9 {
                    context.fill(ellipse(trayX+(Double(grain)*2.5-10)*scale, floor-(grain % 2 == 0 ? 4 : 2.5)*scale, 0.45*scale, 0.45*scale), with: .color(ink.opacity(0.5)))
                }
                if littering && motion.remaining < 1.2 {
                    context.stroke(Path { p in
                        p.move(to: CGPoint(x: trayX+18*scale,y: floor-15*scale)); p.addLine(to: CGPoint(x: trayX+18*scale,y: floor-9*scale))
                        p.move(to: CGPoint(x: trayX+15*scale,y: floor-12*scale)); p.addLine(to: CGPoint(x: trayX+21*scale,y: floor-12*scale))
                    }, with: .color(theme.accent), lineWidth: 1.2)
                }
            }
            if motion.action == "hide" { boxLayer("boxFront") }
            if motion.action == "highfive" {
                let starX = x+motion.facing*22*scale
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: starX,y: floor-18*scale)); p.addLine(to: CGPoint(x: starX,y: floor-12*scale))
                    p.move(to: CGPoint(x: starX-3*scale,y: floor-15*scale)); p.addLine(to: CGPoint(x: starX+3*scale,y: floor-15*scale))
                }, with: .color(theme.accent), lineWidth: 1.2)
            }
            if motion.action == "pet" {
                var heart = context
                let lift = reducedMotion ? 0 : (1-motion.remaining/2.4)*(large ? 24 : 5)
                heart.translateBy(x: x+24*scale,y: floor-23*scale-lift); heart.scaleBy(x: scale*0.65,y: scale*0.65)
                heart.fill(Path { p in
                    p.move(to: CGPoint(x: 0,y: 3)); p.addCurve(to: CGPoint(x: 0,y: -4),control1: CGPoint(x: -7,y: -2),control2: CGPoint(x: -4,y: -7))
                    p.addCurve(to: CGPoint(x: 0,y: 3),control1: CGPoint(x: 4,y: -7),control2: CGPoint(x: 7,y: -2)); p.closeSubpath()
                }, with: .color(pink))
            }
            if motion.action == "litter" && motion.isRock {
                for drop in 0..<3 {
                    context.fill(ellipse(x+Double(drop*6-6)*scale, floor-21*scale, scale, 2*scale), with: .color(theme.accent))
                }
            }
            if motion.kind != "puke" && ["feed", "play"].contains(motion.action) {
                let propX = motion.action == "feed" || motion.isRock ? x+motion.facing*24*scale : 25*scale+motion.target*max(0, size.width-50*scale)
                var prop = context
                prop.translateBy(x: propX-11*scale, y: floor-14*scale)
                prop.scaleBy(x: scale*0.5, y: scale*0.5)
                layer(&prop, motion.toyArtwork(motion.action))
            }
            if motion.action == "feed" && motion.kind == "puke" {
                var fish = context
                fish.translateBy(x: x+motion.facing*25*scale,y: floor-3*scale); fish.scaleBy(x: scale*0.6,y: scale*0.6)
                fish.fill(Path { p in
                    p.move(to: CGPoint(x: -7,y: 0)); p.addQuadCurve(to: CGPoint(x: 7,y: 0),control: CGPoint(x: 0,y: -8)); p.addQuadCurve(to: CGPoint(x: -7,y: 0),control: CGPoint(x: 0,y: 8))
                    p.move(to: CGPoint(x: 7,y: 0)); p.addLine(to: CGPoint(x: 12,y: -5)); p.addLine(to: CGPoint(x: 12,y: 5)); p.closeSubpath()
                },with: .color(theme.accent))
            }
            if motion.action == "play" && motion.kind == "puke" {
                let ballX = 25*scale+motion.target*max(0,size.width-50*scale)
                context.fill(ellipse(ballX,floor-4*scale,4*scale,4*scale),with: .color(theme.accent))
                context.stroke(ellipse(ballX,floor-4*scale,2*scale,3.5*scale),with: .color(cream), lineWidth: 0.6)
                context.stroke(Path { p in p.move(to: CGPoint(x: ballX,y: floor)); p.addLine(to: CGPoint(x: ballX+10*scale,y: floor)) },with: .color(theme.accent), lineWidth: 0.8)
            }
            if motion.enjoyingMusic {
                let lift = 0.0
                context.draw(Text("♪").font(.system(size: large ? 17 : 10)).foregroundColor(theme.accent),
                             at: CGPoint(x: x-motion.facing*6*scale, y: floor-30*scale+lift), anchor: .topLeading)
            }
            if sleeping && large { context.draw(Text("z z").font(.system(size: 12)).foregroundColor(theme.muted),at: CGPoint(x: x+35,y: floor-40-Double(breath))) }
        }
    }
}
