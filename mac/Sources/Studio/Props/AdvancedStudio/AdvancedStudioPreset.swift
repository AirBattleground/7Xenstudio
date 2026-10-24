// "OPUS Advanced Studio": BGMI-style ultra-luxury broadcast package with AirBattleground branding.
// Black / gunmetal / metallic gold / crimson. Every data text is a {{MatchKeys}} binding filled by the server feed;
// static words are only labels ("KILLS", "MATCH STARTS IN", ...). Scenes are 1920x1080.
import Foundation

enum AdvancedStudioPreset {
    static let name = PresetNames.opusAdvanced

    /// One scene per match journey stage.
    static func makeScenes() -> [JourneyStage: LayerScene] {
        [.preShow: stinger(), .startsIn: startsIn(), .gameplay: gameplay(), .summary: summary(), .winner: winner()]
    }
    /// Be Right Back, Stream Ending / Thanks, AirBattleground Stinger (short transition scene).
    static func extraScenes() -> [LayerScene] { [beRightBack(), streamEnding()] }

    private typealias K = AdvKit
    private static func v(_ k: String) -> String { AdvKit.v(k) }

    private static func scene(_ id: String, _ name: String, _ layers: [Layer], bg: Background = .solid(RGBA(hex: ABG.black))) -> LayerScene {
        LayerScene(id: "opus.adv.\(id)", name: name, background: bg, layers: layers, transitionIn: K.transitionIn, transitionOut: K.transitionOut)
    }

    // MARK: shared pieces

    /// Luxe animated backdrop: art, ghost AB, hex grid, gold smoke, bokeh. Each depth drifts at its own rate (parallax).
    private static func luxeBackdrop(ghost: Bool = true, smoke: Double = 0.55, seed: UInt32 = 1) -> [Layer] {
        var out: [Layer] = [K.img("Backdrop", "adv.bg.luxe", x: -40, y: -24, w: 2000, h: 1128, anims: [K.drift(18, period: 26, dir: 0, scale: 0.015)])]
        if ghost {
            out.append(K.img("Ghost AB", "abg.logo.mark", x: 160, y: 120, w: 1100, opacity: 0.045, anims: [K.drift(36, period: 30, dir: 200, phase: 1)]))
        }
        out.append(K.fx("Hex Grid", .hexGrid, base: .animatedGradient, color: ABG.gold2C, intensity: 0.55, speed: 1, seed: seed, size: 42, thickness: 1.1,
                        blend: .add, opacity: 0.55, anims: [K.drift(10, period: 34, dir: 90, phase: 2)]))
        out.append(K.fx("Gold Smoke", .goldSmoke, base: .smoke, color: RGBA(hex: 0xC8973A), color2: RGBA(hex: 0x3A2A10), intensity: smoke, speed: 0.6, seed: seed, size: 380,
                        blend: .screen, anims: [K.drift(40, period: 40, dir: 10, phase: 3)]))
        out.append(K.fx("Bokeh", .bokeh, base: .embers, color: ABG.gold1C, color2: RGBA(hex: 0xB0782A), intensity: 0.9, speed: 1, count: 46, seed: seed &+ 3, size: 70))
        return out
    }
    private static func finish(grain: Double = 0.22) -> [Layer] {
        [K.classic("Vignette", EffectSpec(.vignette, color: RGBA(0, 0, 0, 1), intensity: 0.8, size: 0.55)),
         K.classic("Film Grain", EffectSpec(.filmGrain, intensity: grain), opacity: 0.7)]
    }
    /// Social strip (icons + handle).
    private static func social(x: Double, y: Double, delay: Double) -> [Layer] {
        [K.img("Social Strip", "adv.social", x: x, y: y, w: 560, h: 64, anims: K.slide(delay, from: 260, dir: 180)),
         K.txt("Handle", TextStyle("airbattleground", font: K.body, size: 30, weight: 600, tracking: 1.5, color: RGBA(hex: 0xF1E6C8),
                                   shadow: Shadow(color: RGBA(0, 0, 0, 0.7), blur: 3, dx: 0, dy: 1), alignment: .left),
               x: x + 228, y: y + 8, w: 300, h: 48, anims: K.slide(delay + 0.08, from: 260, dir: 180))]
    }
    /// Gold divider with a red centre tick.
    private static func divider(cx: Double, y: Double, w: Double, delay: Double) -> [Layer] {
        [K.rect("Divider", x: cx - w / 2, y: y, w: w, h: 2, Fill(gradient: Gradient(stops: [GradientStop(0, ABG.gold2C.with(alpha: 0)), GradientStop(0.5, ABG.gold1C), GradientStop(1, ABG.gold2C.with(alpha: 0))], angle: 0)),
                anims: K.wipe(delay, dir: 0, dur: 0.6)),
         K.rect("Divider Tick", x: cx - 34, y: y - 2, w: 68, h: 6, Fill(ABG.redC), anims: [K.fadeIn(delay + 0.3, 0.3), K.out])]
    }
    /// AB mark with slam reveal, shine, glow + its converge / burst / shockwave / flare entourage (centre cx, cy; mark width w).
    private static func logoReveal(cx: Double, cy: Double, w: Double, at t: Double, word: Bool = true, full: Bool = false) -> [Layer] {
        let id = full ? "abg.logo.full" : "abg.logo.mark"
        let a = BuiltinAssets.asset(id)
        let h = w * Double((a?.size.height ?? 1) / max(1, a?.size.width ?? 1))
        var mark = K.img(full ? "AirBattleground Logo" : "AB Mark", id, x: cx - w / 2, y: cy - h / 2, w: w, h: h, anims: K.slam(t, from: 1.7, dur: 0.38))
        mark.glow = Glow(color: ABG.gold2C, radius: 22, intensity: 0.45)
        mark.shine = Shine(color: RGBA(1, 0.97, 0.86), intensity: 1.1, width: 0.09, angle: 22, duration: 0.95, period: 5, delay: t + 0.7, shimmer: 0.18)
        var out: [Layer] = []
        let cv = K.centred(cx, cy, w * 2.2, w * 1.5)
        out.append(K.fx("Converge", .converge, base: .sparks, color: ABG.gold1C, color2: ABG.gold2C, intensity: 1, speed: 1, count: 300, seed: 7, size: 9,
                        delay: max(0, t - 1.15), x: cv.x, y: cv.y, w: cv.w, h: cv.h))
        let fl = K.centred(cx + w * 0.12, cy - h * 0.38, 1300, 520)
        out.append(K.fx("Lens Flare", .lensFlare, base: .pulsingGlow, color: RGBA(hex: 0xFFD27A), color2: RGBA(hex: 0xE05A1E), intensity: 0.85, speed: 1, size: 34, thickness: 4,
                        x: fl.x, y: fl.y, w: fl.w, h: fl.h, anims: K.flash(at: t, dur: 0.9) + [Animation(trigger: .onShow, kind: .fade, duration: 0.8, delay: t + 0.9, from: 0, to: 0.55)]))
        out.append(mark)
        let sw = K.centred(cx, cy, w * 3.2, w * 3.2)
        out.append(K.fx("Shockwave", .shockwave, base: .pulsingGlow, color: ABG.gold1C, color2: ABG.redC, intensity: 1, speed: 1, size: 22, thickness: 3,
                        delay: t + 0.04, x: sw.x, y: sw.y, w: sw.w, h: sw.h))
        let bu = K.centred(cx, cy, w * 1.8, w * 1.8)
        out.append(K.fx("Burst", .burst, base: .sparks, color: ABG.gold1C, color2: ABG.redC, intensity: 1, speed: 1, count: 340, seed: 11, size: 9,
                        delay: t + 0.02, x: bu.x, y: bu.y, w: bu.w, h: bu.h))
        return out
    }

    // MARK: 1. Match starts in

    static func startsIn() -> LayerScene {
        let land = 1.15
        var cam: [Layer] = []
        // right: gold slab with the countdown dial
        cam.append(K.img("Gold Panel", "adv.panel.gold", x: 960, y: 0, w: 1000, h: 1080,
                         anims: [Animation(trigger: .onShow, kind: .slide, duration: 0.9, delay: 0.05, easing: .easeOut, from: 1100, to: 0, direction: 0), K.out,
                                 K.drift(8, period: 18, dir: 0)]))
        var redSlash = K.rect("Red Slash", x: 1078, y: -60, w: 9, h: 1200, Fill(ABG.redC), rotation: 17,
                              anims: [Animation(trigger: .onShow, kind: .slide, duration: 0.9, delay: 0.12, easing: .easeOut, from: 1100, to: 0, direction: 0), K.out])
        redSlash.glow = Glow(color: ABG.redC, radius: 16, intensity: 0.9)
        cam.append(redSlash)
        cam.append(K.rect("Gold Slash", x: 1030, y: -60, w: 3, h: 1200, Fill(ABG.gold1C), rotation: 17, opacity: 0.8,
                          anims: [Animation(trigger: .onShow, kind: .slide, duration: 0.9, delay: 0.18, easing: .easeOut, from: 1100, to: 0, direction: 0), K.out]))
        cam.append(K.fx("Energy Streaks", .energyStreaks, base: .lightSweep, color: ABG.gold1C, color2: ABG.redC, intensity: 0.9, speed: 1, count: 30, seed: 5,
                        thickness: 2.2, angle: -73, anims: [K.fadeIn(0.4, 0.8), K.out]))
        cam.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE3A0), color2: ABG.gold3C, intensity: 0.75, speed: 1, count: 46, seed: 2,
                        x: 0, y: -40, w: 1100, h: 1000, anims: [K.fadeIn(land - 0.2, 1.2), K.out]))
        // left: logo reveal + match info
        cam += logoReveal(cx: 520, cy: 300, w: 560, at: land)
        var word = K.img("Wordmark", "abg.logo.wordmark", x: 80, y: 470, w: 880, anims: K.wipe(land + 0.25, dir: 0, dur: 0.6))
        word.shine = Shine(intensity: 1.0, width: 0.06, angle: 8, duration: 1.0, period: 5, delay: land + 1.0)
        word.glow = Glow(color: ABG.gold2C, radius: 12, intensity: 0.3)
        cam.append(word)
        cam += divider(cx: 520, y: 590, w: 640, delay: land + 0.5)
        cam.append(K.txt("Match Title", K.white(v(MatchKeys.matchTitle), size: 44, font: K.heavy, tracking: 3), x: 80, y: 608, w: 880, h: 60,
                         anims: K.slide(land + 0.6, from: 40, dir: 90)))
        // map plate + match number block
        cam.append(K.img("Map Plate", AdvancedStudioAssets.plateID(520, 84), x: 120, y: 690, w: 520, h: 84, anims: K.slide(land + 0.75, from: 300, dir: 180)))
        cam.append(K.txt("Map Caption", K.caption("MAP", size: 20, align: .left), x: 156, y: 698, w: 120, h: 24, anims: K.slide(land + 0.8, from: 300, dir: 180)))
        cam.append(K.txt("Map", K.white(v(MatchKeys.map), size: 54, align: .left, tracking: 3), x: 150, y: 714, w: 470, h: 58, anims: K.slide(land + 0.8, from: 300, dir: 180)))
        cam.append(K.img("Match Block", AdvancedStudioAssets.goldPlateID(170, 84), x: 660, y: 690, w: 170, h: 84, anims: K.slide(land + 0.85, from: 300, dir: 180)))
        cam.append(K.txt("Match Caption", K.dark("MATCH", size: 20, font: K.label, tracking: 4), x: 660, y: 696, w: 170, h: 24, anims: K.slide(land + 0.9, from: 300, dir: 180)))
        cam.append(K.txt("Match Number", K.dark(v(MatchKeys.matchNumber), size: 52, font: K.number), x: 660, y: 716, w: 170, h: 56, anims: K.slide(land + 0.9, from: 300, dir: 180)))
        cam += social(x: 120, y: 950, delay: land + 1.1)
        // dial
        cam.append(K.txt("Starts In", TextStyle("MATCH STARTS IN", font: K.display, size: 96, weight: 900, tracking: 2, color: RGBA(hex: 0x0C0A06),
                                                shadow: Shadow(color: RGBA(1, 0.93, 0.7, 0.5), blur: 2, dx: 0, dy: 2), alignment: .center, allCaps: true),
                         x: 1150, y: 70, w: 700, h: 110, anims: K.glitchIn(0.75)))
        cam.append(K.rect("Starts Rule", x: 1190, y: 186, w: 620, h: 3, Fill(RGBA(hex: 0x0C0A06, alpha: 0.85)), anims: K.wipe(0.95, dir: 0, dur: 0.5)))
        cam.append(K.rect("Starts Rule Red", x: 1462, y: 184, w: 76, h: 7, Fill(ABG.redC), anims: [K.fadeIn(1.2, 0.3), K.out]))
        let dc = (x: 1500.0, y: 610.0)
        var face = K.img("Dial Face", "adv.dial.face", x: dc.x - 290, y: dc.y - 290, w: 580, h: 580, anims: K.pop(0.45, from: 0.7, dur: 0.7))
        face.shadow = Shadow(color: RGBA(0.2, 0.12, 0.0, 0.55), blur: 30, dx: 0, dy: 16)
        cam.append(face)
        let hd = K.centred(dc.x, dc.y, 800, 800)
        cam.append(K.fx("HUD Dial", .hudDial, base: .radarSweep, color: RGBA(hex: 0x1A1206), color2: ABG.redC, intensity: 1, speed: 1, count: 0,
                        x: hd.x, y: hd.y, w: hd.w, h: hd.h, blend: .normal, anims: K.pop(0.6, from: 0.85, dur: 0.8)))
        let inner = K.centred(dc.x, dc.y, 640, 640)
        cam.append(K.fx("Dial Ring", .hudDial, base: .radarSweep, color: ABG.gold1C, color2: ABG.redC, intensity: 0.9, speed: -0.6, count: 0,
                        x: inner.x, y: inner.y, w: inner.w, h: inner.h, opacity: 0.8, anims: K.pop(0.7, from: 1.2, dur: 0.8)))
        cam.append(K.txt("Countdown Ghost", K.gold(v(MatchKeys.countdownGhost), size: 200, font: K.number, tracking: 4, stroke: 1, glow: 0), x: dc.x - 260, y: dc.y - 135, w: 520, h: 230,
                         opacity: 0.07, anims: [K.fadeIn(land, 0.6), K.out]))
        var cd = K.txt("Countdown", K.gold(v(MatchKeys.countdown), size: 200, font: K.number, tracking: 4, stroke: 3), x: dc.x - 260, y: dc.y - 135, w: 520, h: 230,
                       anims: K.slam(land + 0.1, from: 1.35, dur: 0.4) + [K.pulse(1.0, 0.012)])
        cd.glow = Glow(color: RGBA(hex: 0xFFC44A), radius: 26, intensity: 0.55)
        cd.shine = Shine(intensity: 0.9, width: 0.1, angle: 70, duration: 0.8, period: 3, delay: land + 0.9)
        cam.append(cd)
        // countdown over, match not started: "PREPARING" (lobby) replaces the digits
        var prep = K.txt("Preparing", K.gold(v(MatchKeys.preparing), size: 92, font: K.number, tracking: 6, stroke: 3), x: dc.x - 270, y: dc.y - 80, w: 540, h: 120,
                         anims: [K.fadeIn(land + 0.1, 0.4), K.pulse(1.4, 0.03), K.out])
        prep.glow = Glow(color: RGBA(hex: 0xFFC44A), radius: 22, intensity: 0.5)
        prep.shine = Shine(intensity: 0.9, width: 0.12, angle: 70, duration: 0.9, period: 2.5, delay: land + 0.5)
        cam.append(prep)
        cam.append(K.txt("Round", K.caption(v(MatchKeys.round), size: 26, color: ABG.gold1C), x: dc.x - 220, y: dc.y + 112, w: 440, h: 34, anims: [K.fadeIn(land + 0.5, 0.5), K.out]))
        cam.append(K.txt("Dial Label", K.caption(v(MatchKeys.countdownLabel), size: 18, color: ABG.gold3C.with(alpha: 0.9)), x: dc.x - 150, y: dc.y - 160, w: 300, h: 24, anims: [K.fadeIn(land + 0.4, 0.5), K.out]))
        cam.append(K.fx("Glints", .glints, base: .sparks, color: ABG.gold1C, intensity: 1, speed: 1, count: 34, seed: 9, size: 30, x: 1000, y: 0, w: 920, h: 1080))
        // flash at the landing
        cam.append(K.rect("Flash", x: 0, y: 0, w: 1920, h: 1080, Fill(RGBA(hex: 0xFFE7A8)), opacity: 0.35, blend: .add, anims: K.flash(at: land, dur: 0.5)))

        var camera = K.group("Camera", cam, anims: [K.shake(18, at: land, dur: 0.6), K.drift(6, period: 14, dir: 45, scale: 0.006)])
        camera.name = "Camera (shake + drift)"
        var layers = luxeBackdrop()
        layers.append(camera)
        layers.append(K.fx("Fire Embers", .fireEmbers, base: .embers, color: RGBA(hex: 0xFFB43A), color2: ABG.redC, intensity: 0.9, speed: 1, count: 140, seed: 4, size: 60,
                           x: 0, y: 640, w: 1920, h: 440, opacity: 0.85))
        layers += finish()
        return scene("startsIn", "Match Starts In", layers)
    }

    // MARK: 2. Gameplay HUD

    static func gameplay() -> LayerScene {
        var l: [Layer] = []
        l.append(Layer.source("Game Feed", .device(id: ""), x: 0, y: 0, w: 1920, h: 1080))
        l.append(K.rect("Top Shade", x: 0, y: 0, w: 1920, h: 150, Fill(gradient: .linear(RGBA(0, 0, 0, 0.55), RGBA(0, 0, 0, 0), angle: 90))))
        l.append(K.rect("Bottom Shade", x: 0, y: 900, w: 1920, h: 180, Fill(gradient: .linear(RGBA(0, 0, 0, 0), RGBA(0, 0, 0, 0.5), angle: 90))))
        // top-centre match bar
        let bx = 550.0, by = 16.0
        var bar: [Layer] = []
        bar.append(K.img("Bar Plate", AdvancedStudioAssets.plateID(820, 70), x: 0, y: 0, w: 820, h: 70))
        bar.append(K.img("Alive Block", AdvancedStudioAssets.goldPlateID(170, 70), x: 0, y: 0, w: 170, h: 70))
        bar.append(K.txt("Alive", K.dark(v(MatchKeys.aliveTeams), size: 46, font: K.number, align: .right), x: 6, y: 4, w: 70, h: 48))
        bar.append(K.rect("Alive Slash", x: 84, y: 10, w: 3, h: 38, Fill(RGBA(hex: 0x0D0B08)), rotation: 18))
        bar.append(K.txt("Teams", K.dark(v(MatchKeys.teamCount), size: 30, font: K.number, align: .left), x: 94, y: 14, w: 64, h: 36))
        bar.append(K.txt("Alive Caption", K.dark("TEAMS ALIVE", size: 13, font: K.label, tracking: 2.5), x: 8, y: 50, w: 154, h: 16))
        bar.append(K.txt("Match Title", K.white(v(MatchKeys.matchTitle), size: 30, font: K.heavy, tracking: 2), x: 186, y: 8, w: 440, h: 36))
        bar.append(K.txt("Map", K.caption(v(MatchKeys.map), size: 18, color: ABG.gold1C), x: 186, y: 44, w: 440, h: 20))
        bar.append(K.rect("Timer Rule", x: 640, y: 12, w: 2, h: 46, Fill(ABG.gold3C)))
        bar.append(K.ellipse("Live Dot", x: 656, y: 29, w: 12, h: 12, Fill(ABG.redC), anims: [K.breathe(1.0, lo: 0.25)]))
        bar.append(K.txt("Elapsed", K.gold(v(MatchKeys.elapsed), size: 38, font: K.number, glow: 0.4), x: 672, y: 10, w: 136, h: 50))
        var barG = K.group("Match Bar", bar, x: bx, y: by, w: 820, h: 70, anims: K.slide(0.2, from: 110, dir: 270, dur: 0.6))
        barG.shine = Shine(intensity: 0.6, width: 0.05, angle: 0, duration: 1.2, period: 8, delay: 1.2)
        l.append(barG)
        // corner bug + LIVE tag
        var bug = K.img("AB Bug", "abg.logo.mark", x: 30, y: 18, w: 150, anims: K.pop(0.3, from: 0.5, dur: 0.6))
        bug.shine = Shine(intensity: 1.2, width: 0.12, angle: 25, duration: 0.9, period: 7, delay: 1.0, shimmer: 0.15)
        bug.glow = Glow(color: ABG.gold2C, radius: 10, intensity: 0.35)
        l.append(bug)
        l.append(K.img("Bug Wordmark", "abg.logo.wordmark", x: 24, y: 102, w: 162, anims: K.wipe(0.6, dir: 0, dur: 0.5)))
        l.append(K.img("LIVE", "adv.live", x: 200, y: 36, w: 120, h: 37, anims: K.slide(0.5, from: 120, dir: 180)))
        var dot = K.ellipse("LIVE Pulse", x: 214, y: 48, w: 13, h: 13, Fill(.white), anims: [K.breathe(0.9, lo: 0.2), K.fadeIn(0.6, 0.3)] + [K.slide(0.5, from: 120, dir: 180)].flatMap { $0 })
        dot.glow = Glow(color: RGBA(1, 0.2, 0.2), radius: 12, intensity: 1)
        l.append(dot)
        // team board docked right (compact, translucent)
        var board = Layer(name: "Team Board", kind: .teamBoard(TeamBoardSpec()), transform: Transform(x: 1662, y: 110, w: 246, h: 760), opacity: 0.94)
        board.animations = K.slide(0.4, from: 300, dir: 0, dur: 0.7)
        l.append(board)
        // lower-third kill-feed dock (bottom-left, away from the crosshair)
        l.append(K.img("Kill Feed Plate", AdvancedStudioAssets.plateID(460, 60), x: 30, y: 990, w: 460, h: 60, opacity: 0.85, anims: K.slide(0.6, from: 200, dir: 180)))
        l.append(K.txt("Kill Feed Caption", K.caption("KILL FEED", size: 18, color: ABG.gold1C, align: .left), x: 62, y: 1000, w: 200, h: 22, anims: K.slide(0.65, from: 200, dir: 180)))
        l.append(K.txt("Kill Feed Round", K.white(v(MatchKeys.round), size: 22, font: K.body, align: .left, tracking: 1.5, color: RGBA(1, 1, 1, 0.85)), x: 62, y: 1020, w: 400, h: 26,
                       anims: K.slide(0.7, from: 200, dir: 180)))
        l.append(K.classic("Kill Feed Brackets", EffectSpec(.hudCornerBrackets, color: ABG.gold2C.with(alpha: 0.7), intensity: 1, size: 22, thickness: 2),
                           x: 24, y: 850, w: 520, h: 210, anims: [K.fadeIn(0.8, 0.5), K.out]))
        return scene("gameplay", "Gameplay HUD", l, bg: .solid(.black))
    }

    // MARK: 3. Match summary

    static func summary() -> LayerScene {
        var l = luxeBackdrop(ghost: false, smoke: 0.45, seed: 3)
        l.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE3A0), color2: ABG.gold3C, intensity: 0.4, speed: 1, count: 40, seed: 6,
                      x: 300, y: -60, w: 1320, h: 900, anims: [K.fadeIn(0.2, 1.2), K.out]))
        // header
        var mark = K.img("AB Mark", "abg.logo.mark", x: 70, y: 40, w: 190, anims: K.pop(0.1, from: 0.5, dur: 0.6))
        mark.shine = Shine(intensity: 1.1, width: 0.1, angle: 22, duration: 0.9, period: 6, delay: 1.0, shimmer: 0.15)
        l.append(mark)
        var title = K.txt("Title", K.gold("MATCH SUMMARY", size: 92, tracking: 3), x: 286, y: 30, w: 900, h: 104, anims: K.glitchIn(0.2))
        title.glow = Glow(color: ABG.gold2C, radius: 16, intensity: 0.35)
        title.shine = Shine(intensity: 0.9, width: 0.06, angle: 10, duration: 1.0, period: 6, delay: 1.2)
        l.append(title)
        l.append(K.txt("Match Title", K.white(v(MatchKeys.matchTitle), size: 32, font: K.heavy, align: .left, tracking: 3), x: 292, y: 130, w: 900, h: 40,
                       anims: K.slide(0.35, from: 80, dir: 180)))
        l.append(K.img("Map Plate", AdvancedStudioAssets.goldPlateID(360, 60), x: 1500, y: 70, w: 360, h: 60, anims: K.slide(0.3, from: 300, dir: 0)))
        l.append(K.txt("Map Caption", K.dark("MAP", size: 18, font: K.label, align: .left, tracking: 4), x: 1530, y: 82, w: 70, h: 40, anims: K.slide(0.35, from: 300, dir: 0)))
        l.append(K.txt("Map", K.dark(v(MatchKeys.map), size: 38, font: K.display, align: .left, tracking: 2), x: 1598, y: 74, w: 250, h: 50, anims: K.slide(0.35, from: 300, dir: 0)))
        l += divider(cx: 960, y: 192, w: 1780, delay: 0.3)
        // MVP card
        l += mvpCard(x: 60, y: 240)
        // standings: 2 columns x 8 rows
        let colX = [620.0, 1250.0], y0 = 262.0, pitch = 80.0
        for (ci, cx) in colX.enumerated() {
            let hy = 222.0
            let hdr: [(String, Double, Double, TextAlign)] = [("#", 0, 80, .center), ("TEAM", 96, 260, .left), ("ELIMS", 380, 70, .center), ("PLACE", 444, 60, .center), ("TOTAL", 500, 96, .center)]
            for (s, dx, w, al) in hdr {
                l.append(K.txt("Header \(s) \(ci + 1)", K.caption(s, size: 18, color: ABG.gold2C, align: al, tracking: 3), x: cx + dx, y: hy, w: w, h: 24, anims: [K.fadeIn(0.45, 0.4), K.out]))
            }
            for r in 0..<8 {
                let n = ci * 8 + r + 1
                l.append(standingsRow(n, x: cx, y: y0 + Double(r) * pitch, delay: 0.55 + Double(n - 1) * 0.06))
            }
        }
        l.append(K.fx("Top3 Glints", .glints, base: .sparks, color: ABG.gold1C, intensity: 1, speed: 1.2, count: 14, seed: 21, size: 26, x: 620, y: 262, w: 600, h: 220))
        l += social(x: 1300, y: 960, delay: 1.6)
        l.append(K.img("Wordmark", "abg.logo.wordmark", x: 1300, y: 900, w: 560, opacity: 0.9, anims: K.wipe(1.5, dir: 0, dur: 0.6)))
        l += finish()
        return scene("summary", "Match Summary", l)
    }

    private static func standingsRow(_ n: Int, x: Double, y: Double, delay: Double) -> Layer {
        let tone = n == 1 ? "gold" : n == 2 ? "silver" : n == 3 ? "bronze" : "dark"
        var kids: [Layer] = [K.img("Row \(n)", "adv.row.\(tone)", x: 0, y: 0, w: 600, h: 64)]
        let top = n <= 3
        kids.append(K.txt("Rank", top ? K.dark("\(n)", size: 42, font: K.number) : K.white("\(n)", size: 38, font: K.number), x: 4, y: 6, w: 74, h: 52))
        kids.append(K.txt("Team", K.white(v(MatchKeys.rankName(n)), size: top ? 32 : 30, font: K.display, align: .left, tracking: 1), x: 96, y: 8, w: 280, h: 48))
        kids.append(K.txt("Kills", K.white(v(MatchKeys.rankKills(n)), size: 30, font: K.number), x: 380, y: 10, w: 70, h: 44))
        kids.append(K.txt("Place", K.white(v(MatchKeys.rankPlacePts(n)), size: 30, font: K.number, color: RGBA(1, 1, 1, 0.8)), x: 444, y: 10, w: 60, h: 44))
        kids.append(K.txt("Total", K.gold(v(MatchKeys.rankTotal(n)), size: 40, font: K.number, glow: 0.4), x: 500, y: 6, w: 96, h: 52))
        var g = K.group("Standing \(n)", kids, x: x, y: y, w: 600, h: 64, anims: K.slide(delay, from: 220, dir: 0, dur: 0.55))
        if top {
            g.shine = Shine(intensity: n == 1 ? 1.0 : 0.75, width: 0.05, angle: 0, duration: 0.9, period: 5, delay: 1.6 + Double(n) * 0.25)
            g.glow = Glow(color: n == 1 ? ABG.gold2C : n == 2 ? RGBA(0.8, 0.85, 0.9) : RGBA(hex: 0xC27A3E), radius: 12, intensity: 0.35)
        }
        return g
    }

    private static func mvpCard(x: Double, y: Double) -> [Layer] {
        let w = 500.0, h = w * 720 / 560
        var kids: [Layer] = []
        var frame = K.img("MVP Frame", "adv.frame.mvp", x: 0, y: 0, w: w, h: h)
        frame.shine = Shine(intensity: 0.8, width: 0.08, angle: 60, duration: 1.2, period: 4.5, delay: 1.4, shimmer: 0.2)
        kids.append(frame)
        var crest = K.img("MVP Crest", "abg.logo.mark", x: w / 2 - 150, y: 70, w: 300)
        crest.glow = Glow(color: ABG.gold2C, radius: 18, intensity: 0.4)
        crest.shine = Shine(intensity: 1.1, width: 0.1, angle: 22, duration: 0.9, period: 4.5, delay: 1.0)
        kids.append(crest)
        kids.append(K.img("MVP Ribbon", AdvancedStudioAssets.goldPlateID(300, 56), x: w / 2 - 150, y: 250, w: 300, h: 56))
        kids.append(K.txt("MVP Label", K.dark("MATCH MVP", size: 32, font: K.display, tracking: 4), x: w / 2 - 150, y: 254, w: 300, h: 48))
        var name = K.txt("MVP Name", K.gold(v(MatchKeys.mvpName), size: 78, tracking: 2), x: 24, y: 318, w: w - 48, h: 92)
        name.glow = Glow(color: ABG.gold2C, radius: 14, intensity: 0.35)
        kids.append(name)
        kids.append(K.txt("MVP Team", K.white(v(MatchKeys.mvpTeam), size: 30, font: K.heavy, tracking: 5, color: RGBA(1, 1, 1, 0.9)), x: 24, y: 408, w: w - 48, h: 38))
        let sy = 470.0
        kids.append(K.txt("MVP Kills", K.white(v(MatchKeys.mvpKills), size: 70, font: K.number), x: 20, y: sy, w: w / 2 - 30, h: 80))
        kids.append(K.txt("MVP Kills Caption", K.caption("KILLS", size: 20), x: 20, y: sy + 80, w: w / 2 - 30, h: 24))
        kids.append(K.txt("MVP Damage", K.white(v(MatchKeys.mvpDamage), size: 70, font: K.number), x: w / 2 + 10, y: sy, w: w / 2 - 30, h: 80))
        kids.append(K.txt("MVP Damage Caption", K.caption("DAMAGE", size: 20), x: w / 2 + 10, y: sy + 80, w: w / 2 - 30, h: 24))
        kids.append(K.classic("MVP Brackets", EffectSpec(.hudCornerBrackets, color: ABG.gold1C, intensity: 1, speed: 1.5, size: 46, thickness: 3), x: 0, y: 0, w: w, h: h))
        kids.append(K.fx("MVP Glints", .glints, base: .sparks, color: ABG.gold1C, intensity: 1, speed: 1, count: 10, seed: 31, size: 28, x: 0, y: 0, w: w, h: h * 0.6))
        var g = K.group("MVP Card", kids, x: x, y: y, w: w, h: h, anims: [Animation(trigger: .onShow, kind: .slide, duration: 0.8, delay: 0.35, easing: .backOut, from: 700, to: 0, direction: 180),
                                                                        K.fadeIn(0.35, 0.4), K.out])
        g.shadow = Shadow(color: RGBA(0, 0, 0, 0.7), blur: 24, dx: 0, dy: 12)
        return [g]
    }

    // MARK: 4. Winner showcase

    static func winner() -> LayerScene {
        let hit = 0.45
        var l: [Layer] = [K.img("Winner Backdrop", "adv.bg.winner", x: -30, y: -20, w: 1980, h: 1114, anims: [K.drift(16, period: 24, dir: 0, scale: 0.02)])]
        l.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE2A0), color2: RGBA(hex: 0xB0761E), intensity: 1.0, speed: 1, count: 64, seed: 12,
                      x: 160, y: -40, w: 1600, h: 1120, anims: [K.fadeIn(hit, 0.9), K.out]))
        l.append(K.fx("Gold Smoke", .goldSmoke, base: .smoke, color: RGBA(hex: 0xC8973A), color2: RGBA(hex: 0x3A1A0A), intensity: 0.5, speed: 0.7, seed: 8, size: 360,
                      blend: .screen, anims: [K.drift(30, period: 30, dir: 0)]))
        l.append(K.fx("Bokeh", .bokeh, base: .embers, color: ABG.gold1C, color2: ABG.redC, intensity: 0.8, speed: 1, count: 40, seed: 14, size: 64))
        var cam: [Layer] = []
        let cy = 380.0
        let fl = K.centred(960, cy, 1700, 600)
        cam.append(K.fx("Lens Flare", .lensFlare, base: .pulsingGlow, color: RGBA(hex: 0xFFD98A), color2: RGBA(hex: 0xE04A1E), intensity: 1.0, speed: 1, size: 48, thickness: 6,
                        x: fl.x, y: fl.y, w: fl.w, h: fl.h, anims: K.flash(at: hit, dur: 1.1) + [Animation(trigger: .onShow, kind: .fade, duration: 1, delay: hit + 1.1, from: 0, to: 0.45)]))
        let sw = K.centred(960, cy, 2000, 2000)
        cam.append(K.fx("Shockwave", .shockwave, base: .pulsingGlow, color: ABG.gold1C, color2: ABG.redC, intensity: 1.1, speed: 0.9, size: 34, thickness: 4,
                        delay: hit, x: sw.x, y: sw.y, w: sw.w, h: sw.h))
        let sw2 = K.centred(960, cy, 1300, 1300)
        cam.append(K.fx("Shockwave Red", .shockwave, base: .pulsingGlow, color: RGBA(hex: 0xFF5A2A), color2: ABG.redC, intensity: 0.8, speed: 1.1, size: 22, thickness: 3,
                        delay: hit + 0.22, x: sw2.x, y: sw2.y, w: sw2.w, h: sw2.h))
        let bu = K.centred(960, cy, 1500, 1200)
        cam.append(K.fx("Burst", .burst, base: .sparks, color: ABG.gold1C, color2: ABG.redC, intensity: 1, speed: 1, count: 600, seed: 17, size: 11,
                        delay: hit - 0.02, x: bu.x, y: bu.y, w: bu.w, h: bu.h))
        var crown = K.img("Crown", "adv.crown", x: 960 - 125, y: 36, w: 250, anims: K.pop(hit + 0.5, from: 0.3, dur: 0.7) + [.float(period: 3, amplitude: 6)])
        crown.shine = Shine(intensity: 1.2, width: 0.12, angle: 30, duration: 0.8, period: 3.5, delay: hit + 1.3, shimmer: 0.25)
        crown.glow = Glow(color: ABG.gold2C, radius: 26, intensity: 0.6)
        cam.append(crown)
        var wwcd = K.txt("WWCD", TextStyle("WINNER WINNER CHICKEN DINNER", font: K.display, size: 54, weight: 900, tracking: 8, color: .white,
                                           stroke: Stroke(width: 1.5, color: RGBA(hex: 0x3A0A06)), shadow: Shadow(color: RGBA(0.9, 0.08, 0.1, 0.85), blur: 14, dx: 0, dy: 0),
                                           alignment: .center, allCaps: true),
                         x: 260, y: 206, w: 1400, h: 66, anims: K.glitchIn(hit + 0.15, dur: 0.7))
        wwcd.glow = Glow(color: ABG.redC, radius: 18, intensity: 0.5)
        cam.append(wwcd)
        var name = K.txt("Winner Name", K.gold(v(MatchKeys.winnerName), size: 190, tracking: 4, stroke: 4, glow: 0.7), x: 330, y: 268, w: 1260, h: 210,
                         anims: K.slam(hit, from: 2.2, dur: 0.38))
        name.glow = Glow(color: RGBA(hex: 0xFFC045), radius: 34, intensity: 0.6)
        name.shine = Shine(intensity: 1.2, width: 0.07, angle: 15, duration: 1.0, period: 4, delay: hit + 0.9, shimmer: 0.2)
        cam.append(name)
        // logo slot (left) + rank #1 (right)
        var slot = K.img("Team Logo Slot", "adv.hex.slot", x: 90, y: 250, w: 230, anims: K.slide(hit + 0.35, from: 400, dir: 180, dur: 0.7, easing: .backOut))
        slot.shine = Shine(intensity: 0.9, width: 0.1, angle: 40, duration: 0.9, period: 5, delay: hit + 1.4)
        cam.append(slot)
        cam.append(K.img("Slot Mark", "abg.logo.mark", x: 125, y: 315, w: 160, anims: K.slide(hit + 0.4, from: 400, dir: 180, dur: 0.7, easing: .backOut)))
        cam.append(K.img("Rank Slot", "adv.hex.slot", x: 1600, y: 250, w: 230, anims: K.slide(hit + 0.35, from: 400, dir: 0, dur: 0.7, easing: .backOut)))
        var one = K.txt("Rank One", K.gold("#1", size: 110, font: K.number, stroke: 3), x: 1620, y: 300, w: 190, h: 130,
                        anims: K.slide(hit + 0.4, from: 400, dir: 0, dur: 0.7, easing: .backOut))
        one.glow = Glow(color: ABG.gold2C, radius: 18, intensity: 0.5)
        cam.append(one)
        // totals
        let tY = 488.0
        cam.append(K.img("Kills Plate", AdvancedStudioAssets.plateID(330, 64), x: 600, y: tY, w: 330, h: 64, anims: K.slide(hit + 0.7, from: 200, dir: 180)))
        cam.append(K.txt("Kills Value", K.gold(v(MatchKeys.winnerKills), size: 46, font: K.number, align: .right), x: 620, y: tY + 7, w: 130, h: 50, anims: K.slide(hit + 0.75, from: 200, dir: 180)))
        cam.append(K.txt("Kills Caption", K.caption("TOTAL KILLS", size: 22, color: .white, align: .left), x: 764, y: tY + 20, w: 160, h: 26, anims: K.slide(hit + 0.75, from: 200, dir: 180)))
        cam.append(K.img("Points Plate", AdvancedStudioAssets.goldPlateID(330, 64), x: 990, y: tY, w: 330, h: 64, anims: K.slide(hit + 0.7, from: 200, dir: 0)))
        cam.append(K.txt("Points Value", K.dark(v(MatchKeys.winnerTotal), size: 46, font: K.number, align: .right), x: 1010, y: tY + 7, w: 130, h: 50, anims: K.slide(hit + 0.75, from: 200, dir: 0)))
        cam.append(K.txt("Points Caption", K.dark("TOTAL POINTS", size: 22, font: K.label, align: .left, tracking: 3), x: 1154, y: tY + 20, w: 160, h: 26, anims: K.slide(hit + 0.75, from: 200, dir: 0)))
        // player cards
        let cw = 300.0, ch = cw * 430 / 340, gap = 44.0
        let x0 = 960 - (cw * 4 + gap * 3) / 2
        for i in 0..<4 {
            cam.append(playerCard(i + 1, x: x0 + Double(i) * (cw + gap), y: 588, w: cw, h: ch, delay: hit + 0.95 + Double(i) * 0.12))
        }
        cam.append(K.fx("Glints", .glints, base: .sparks, color: ABG.gold1C, intensity: 1, speed: 1, count: 26, seed: 19, size: 34, x: 300, y: 40, w: 1320, h: 480))
        cam.append(K.rect("Flash", x: 0, y: 0, w: 1920, h: 1080, Fill(RGBA(hex: 0xFFE7A8)), opacity: 0.55, blend: .add, anims: K.flash(at: hit, dur: 0.6)))
        l.append(K.group("Camera", cam, anims: [K.shake(26, at: hit, dur: 0.75), K.drift(5, period: 12, dir: 30, scale: 0.006)]))
        l.append(K.fx("Fire Embers", .fireEmbers, base: .embers, color: RGBA(hex: 0xFFB43A), color2: ABG.redC, intensity: 1, speed: 1, count: 220, seed: 23, size: 70,
                      x: 0, y: 560, w: 1920, h: 520, anims: [K.fadeIn(hit, 0.6), K.out]))
        l.append(K.fx("Confetti", .confetti, base: .sparks, color: ABG.gold2C, color2: ABG.redC, intensity: 1, speed: 1, count: 240, seed: 29, size: 13,
                      delay: hit + 0.35, blend: .normal))
        l += finish(grain: 0.18)
        return scene("winner", "Winner Showcase", l)
    }

    private static func playerCard(_ n: Int, x: Double, y: Double, w: Double, h: Double, delay: Double) -> Layer {
        let s = w / 340
        var kids: [Layer] = [K.img("Card", "adv.card.player", x: 0, y: 0, w: w, h: h)]
        kids.append(K.txt("Player No", K.caption("PLAYER \(n)", size: 18 * s / 0.88, color: ABG.gold2C), x: 0, y: 30 * s, w: w, h: 24 * s))
        var nm = K.txt("Player", K.gold(v(MatchKeys.winnerPlayer(n)), size: 58 * s, tracking: 1), x: 14 * s, y: 196 * s, w: w - 28 * s, h: 74 * s)
        nm.glow = Glow(color: ABG.gold2C, radius: 10, intensity: 0.3)
        kids.append(nm)
        kids.append(K.txt("Kills", K.white(v(MatchKeys.winnerPlayerKills(n)), size: 54 * s, font: K.number), x: 14 * s, y: 316 * s, w: 150 * s, h: 62 * s))
        kids.append(K.txt("Kills Caption", K.caption("KILLS", size: 17 * s / 0.88), x: 14 * s, y: 378 * s, w: 150 * s, h: 22 * s))
        kids.append(K.txt("Damage", K.white(v(MatchKeys.winnerPlayerDamage(n)), size: 54 * s, font: K.number), x: 176 * s, y: 316 * s, w: 150 * s, h: 62 * s))
        kids.append(K.txt("Damage Caption", K.caption("DAMAGE", size: 17 * s / 0.88), x: 176 * s, y: 378 * s, w: 150 * s, h: 22 * s))
        var crest = K.img("Crest", "abg.logo.mark", x: w / 2 - 90 * s, y: 70 * s, w: 180 * s, opacity: 0.9)
        crest.shine = Shine(intensity: 1, width: 0.12, angle: 25, duration: 0.8, period: 5, delay: delay + 1.0 + Double(n) * 0.2)
        kids.append(crest)
        var g = K.group("Player Card \(n)", kids, x: x, y: y, w: w, h: h,
                        anims: [Animation(trigger: .onShow, kind: .slide, duration: 0.75, delay: delay, easing: .backOut, from: 520, to: 0, direction: 90),
                                Animation(trigger: .onShow, kind: .rotate, duration: 0.75, delay: delay, easing: .backOut, from: Double(n % 2 == 0 ? 8 : -8), to: 0),
                                K.fadeIn(delay, 0.3), K.out])
        g.shadow = Shadow(color: RGBA(0, 0, 0, 0.75), blur: 22, dx: 0, dy: 14)
        g.shine = Shine(intensity: 0.5, width: 0.08, angle: 60, duration: 1, period: 6, delay: delay + 1.2)
        return g
    }

    // MARK: extras

    static func beRightBack() -> LayerScene {
        var l = luxeBackdrop(ghost: false, smoke: 0.6, seed: 5)
        l.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE3A0), color2: ABG.gold3C, intensity: 0.7, speed: 0.8, count: 50, seed: 4,
                      x: 260, y: -60, w: 1400, h: 1000, anims: [K.fadeIn(0.3, 1.2), K.out]))
        l.append(K.fx("Energy Streaks", .energyStreaks, base: .lightSweep, color: ABG.gold1C, color2: ABG.redC, intensity: 0.7, speed: 0.8, count: 24, seed: 8, thickness: 2, angle: -20))
        let dl = K.centred(960, 400, 900, 900)
        l.append(K.fx("Halo Dial", .hudDial, base: .radarSweep, color: ABG.gold2C, color2: ABG.redC, intensity: 0.8, speed: 0.6, count: 0,
                      x: dl.x, y: dl.y, w: dl.w, h: dl.h, blend: .add, opacity: 0.5, anims: K.pop(0.3, from: 0.8, dur: 0.9)))
        l += logoReveal(cx: 960, cy: 400, w: 820, at: 0.9, full: true)
        var brb = K.txt("BRB", K.gold("BE RIGHT BACK", size: 130, tracking: 6, stroke: 3), x: 260, y: 640, w: 1400, h: 150, anims: K.glitchIn(1.4, dur: 0.6))
        brb.glow = Glow(color: ABG.gold2C, radius: 22, intensity: 0.45)
        brb.shine = Shine(intensity: 1, width: 0.05, angle: 10, duration: 1.1, period: 5, delay: 2.2)
        l.append(brb)
        l += divider(cx: 960, y: 800, w: 900, delay: 1.7)
        l.append(K.txt("Match Title", K.white(v(MatchKeys.matchTitle), size: 38, font: K.heavy, tracking: 6), x: 360, y: 816, w: 1200, h: 50, anims: K.slide(1.8, from: 40, dir: 90)))
        l += social(x: 680, y: 960, delay: 2.0)
        l.append(K.fx("Fire Embers", .fireEmbers, base: .embers, color: RGBA(hex: 0xFFB43A), color2: ABG.redC, intensity: 0.8, speed: 0.8, count: 120, seed: 41, size: 60,
                      x: 0, y: 620, w: 1920, h: 460, opacity: 0.8))
        l += finish()
        return scene("brb", "Be Right Back", l)
    }

    static func streamEnding() -> LayerScene {
        var l = luxeBackdrop(ghost: true, smoke: 0.6, seed: 9)
        l.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE3A0), color2: ABG.gold3C, intensity: 0.6, speed: 0.7, count: 44, seed: 10,
                      x: 260, y: -60, w: 1400, h: 1000, anims: [K.fadeIn(0.3, 1.2), K.out]))
        l += logoReveal(cx: 960, cy: 300, w: 700, at: 0.8, full: true)
        var thanks = K.txt("Thanks", K.gold("THANKS FOR WATCHING", size: 112, tracking: 5, stroke: 3), x: 160, y: 500, w: 1600, h: 130, anims: K.glitchIn(1.3, dur: 0.6))
        thanks.glow = Glow(color: ABG.gold2C, radius: 20, intensity: 0.4)
        thanks.shine = Shine(intensity: 1, width: 0.05, angle: 10, duration: 1.1, period: 5, delay: 2.2)
        l.append(thanks)
        l += divider(cx: 960, y: 644, w: 1000, delay: 1.6)
        l.append(K.txt("Round", K.caption(v(MatchKeys.round), size: 30, color: ABG.gold1C), x: 460, y: 664, w: 1000, h: 40, anims: K.slide(1.7, from: 40, dir: 90)))
        l.append(K.img("Winner Plate", AdvancedStudioAssets.plateID(700, 90), x: 610, y: 730, w: 700, h: 90, anims: K.slide(1.9, from: 300, dir: 180)))
        l.append(K.txt("Winner Caption", K.caption("MATCH WINNER", size: 20, color: ABG.gold2C, align: .left), x: 650, y: 740, w: 300, h: 24, anims: K.slide(1.95, from: 300, dir: 180)))
        l.append(K.txt("Winner", K.gold(v(MatchKeys.winnerName), size: 50, align: .left, tracking: 2), x: 648, y: 760, w: 470, h: 56, anims: K.slide(1.95, from: 300, dir: 180)))
        l.append(K.txt("Winner Pts", K.white(v(MatchKeys.winnerTotal), size: 52, font: K.number, align: .right), x: 1130, y: 748, w: 110, h: 60, anims: K.slide(2.0, from: 300, dir: 180)))
        l.append(K.txt("Pts Caption", K.caption("PTS", size: 20), x: 1244, y: 774, w: 50, h: 24, anims: K.slide(2.0, from: 300, dir: 180)))
        l += social(x: 680, y: 900, delay: 2.2)
        l.append(K.fx("Confetti", .confetti, base: .sparks, color: ABG.gold2C, color2: ABG.redC, intensity: 1, speed: 0.7, count: 90, seed: 33, size: 11, delay: 1.0, blend: .normal, opacity: 0.85))
        l += finish()
        return scene("ending", "Stream Ending / Thanks", l)
    }

    /// ~1.8 s branded transition: gold light wipe, logo slam with burst + shockwave, wipe out.
    static func stinger() -> LayerScene {
        var content: [Layer] = [K.img("Backdrop", "adv.bg.luxe", x: 0, y: 0, w: 1920, h: 1080)]
        content.append(K.fx("Energy Streaks", .energyStreaks, base: .lightSweep, color: ABG.gold1C, color2: ABG.redC, intensity: 1.2, speed: 2.5, count: 40, seed: 3, thickness: 2.5, angle: -20))
        content += logoReveal(cx: 960, cy: 520, w: 900, at: 0.42, full: true)
        // revealed behind the first gold band, hidden behind the second (the wipe edges ride the band centres)
        var l: [Layer] = [K.group("Stinger Content", content, anims: [
            Animation(trigger: .onShow, kind: .wipe, duration: 0.625, delay: 0, easing: .easeInOut, from: -0.2, to: 1.2, direction: -20),
            Animation(trigger: .onShow, kind: .wipe, duration: 0.625, delay: 1.2, easing: .easeInOut, from: 1.2, to: -0.2, direction: 160)])]
        l.append(K.fx("Light Wipe In", .lightWipe, base: .lightSweep, color: ABG.gold2C, color2: RGBA(hex: 0x8A4A10), intensity: 1, speed: 1.6, size: 220, angle: -20, blend: .normal))
        l.append(K.fx("Light Wipe Out", .lightWipe, base: .lightSweep, color: ABG.gold2C, color2: RGBA(hex: 0x8A4A10), intensity: 1, speed: 1.6, size: 220, angle: -20, delay: 1.2, blend: .normal))
        l += finish(grain: 0.15)
        var s = scene("stinger", "AirBattleground Stinger", l)
        s.transitionIn = SceneTransition(.cut, duration: 0)
        s.transitionOut = SceneTransition(.lightWipe, duration: 0.6, direction: 200)
        return s
    }
    /// Length of the stinger scene (seconds) -- take the next scene after this.
    static let stingerDuration = 1.8
}
