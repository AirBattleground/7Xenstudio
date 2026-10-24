// "Battleground Pro" ready-made scenes, composed only from the SceneModel API.
import Foundation
import CoreGraphics

struct PropTemplate: Identifiable {
    let id: String
    let name: String
    let summary: String
    let tags: [String]
    /// Sources the scene expects the operator to assign (placeholders are .slate / .camera / .device("")).
    let slots: [String]
    let build: (PropTheme) -> LayerScene
}

enum Templates {
    static let pack = "Battleground Pro"
    static let defaultVariables: [String: String] = [
        "team1": "ALPHA SQUAD", "team2": "BRAVO SQUAD", "score1": "12", "score2": "9", "matchTitle": "GRAND FINALS", "playerName": "PLAYER ONE",
        "timer": "08:42", "viewers": "1.2K", "countdownTimer": "08:42",
        "phone1": "PLAYER 1", "phone2": "PLAYER 2", "phone3": "PLAYER 3", "phone4": "PLAYER 4",
        "team3": "CHARLIE SQUAD", "team4": "DELTA SQUAD", "team5": "ECHO SQUAD", "team6": "FOXTROT SQUAD", "team7": "GHOST SQUAD", "team8": "HAVOC SQUAD",
        "score3": "7", "score4": "6", "score5": "5", "score6": "4", "score7": "3", "score8": "2",
        "total1": "40", "total2": "36", "total3": "32", "total4": "28", "total5": "24", "total6": "20", "total7": "16", "total8": "12",
    ]
    static var all: [PropTemplate] { TemplateDefs.all }
    static func template(_ id: String) -> PropTemplate? { all.first { $0.id == id } }
    /// Builds a fresh scene (new layer ids) for the template in `theme`; `variables` are merged into the scene's variableDefaults.
    static func make(_ id: String, theme: PropTheme = .ember, variables: SceneVariables? = nil) -> LayerScene? {
        guard let t = template(id) else { return nil }
        var s = t.build(theme)
        s.id = UUID().uuidString
        s.layers = reID(s.layers)
        s.variableDefaults = defaultVariables.merging(variables?.values ?? [:]) { _, new in new }
        return s
    }
    private static func reID(_ ls: [Layer]) -> [Layer] {
        ls.map { var l = $0; l.id = UUID().uuidString
            if case .group(let c) = l.kind { l.kind = .group(reID(c)) }
            return l }
    }
    /// Every {{key}} used by text styles / effects in the scene.
    static func placeholders(in scene: LayerScene) -> Set<String> {
        var keys = Set<String>()
        func scan(_ s: String) {
            var rest = Substring(s)
            while let a = rest.range(of: "{{"), let b = rest.range(of: "}}", range: a.upperBound..<rest.endIndex) {
                keys.insert(rest[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)); rest = rest[b.upperBound...] }
        }
        scene.forEachLayer { l in
            switch l.kind { case .text(let t): scan(t.string); case .effect(let e): scan(e.text); default: break }
        }
        return keys
    }
}

/// Layer builder bound to one theme.
struct TB {
    let t: PropTheme
    var pri: RGBA { t.primaryRGBA }
    var hot: RGBA { t.hotRGBA }
    var glw: RGBA { t.glowRGBA }

    func asset(_ id: String) -> BuiltinAsset { PropsCatalog.byID[id]! }
    /// Image layer for a built-in asset. If `h` is nil the box keeps the asset aspect ratio.
    func img(_ name: String, _ id: String, x: Double, y: Double, w: Double, h: Double? = nil, opacity: Double = 1, blend: BlendMode = .normal, anims: [Animation] = []) -> Layer {
        let a = asset(id); let hh = h ?? w * Double(a.size.height / a.size.width)
        var l = Layer(name: name, kind: .image(ImageSpec(builtin: id, theme: t.id, fit: .stretch)), transform: Transform(x: x, y: y, w: w, h: hh), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    func full(_ name: String, _ id: String, opacity: Double = 1, blend: BlendMode = .normal) -> Layer { img(name, id, x: 0, y: 0, w: 1920, h: 1080, opacity: opacity, blend: blend) }
    func txt(_ name: String, _ s: String, x: Double, y: Double, w: Double, h: Double, _ style: TextStyle, anims: [Animation] = []) -> Layer {
        var l = Layer.text(name, s, x: x, y: y, w: w, h: h, style: style); l.animations = anims; return l
    }
    func fx(_ name: String, _ spec: EffectSpec, x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080, blend: BlendMode = .normal, opacity: Double = 1, anims: [Animation] = []) -> Layer {
        var l = Layer.effect(name, spec, x: x, y: y, w: w, h: h, blend: blend); l.opacity = opacity; l.animations = anims; return l
    }
    func src(_ name: String, _ ref: SourceRef, x: Double, y: Double, w: Double, h: Double, mask: Mask = Mask()) -> Layer {
        var l = Layer.source(name, ref, x: x, y: y, w: w, h: h); l.mask = mask; return l
    }
    func rect(_ name: String, x: Double, y: Double, w: Double, h: Double, _ fill: Fill, opacity: Double = 1) -> Layer {
        var l = Layer.rect(name, x: x, y: y, w: w, h: h, fill: fill); l.opacity = opacity; return l
    }
    func group(_ name: String, _ ls: [Layer], anims: [Animation] = []) -> Layer { var g = Layer.group(name, ls); g.animations = anims; return g }

    // animation recipes
    func slideIn(_ dir: Double, _ px: Double = 420, delay: Double = 0, dur: Double = 0.7) -> [Animation] {
        [.slideIn(from: px, direction: dir, dur: dur, delay: delay), .fadeIn(0.3, delay: delay),
         Animation(trigger: .onHide, kind: .slide, duration: 0.4, easing: .easeIn, from: 0, to: px, direction: dir + 180), .fadeOut(0.35)]
    }
    func fadeInOut(delay: Double = 0, dur: Double = 0.6) -> [Animation] { [.fadeIn(dur, delay: delay), .fadeOut(0.4)] }
    func glitchIn(delay: Double = 0) -> [Animation] {
        [Animation(trigger: .onShow, kind: .glitch, duration: 0.7, delay: delay, easing: .easeOut, from: 1, to: 0), .fadeIn(0.15, delay: delay), .fadeOut(0.3)]
    }
    func fireIn(delay: Double = 0) -> [Animation] {
        [Animation(trigger: .onShow, kind: .wipe, duration: 0.8, delay: delay, easing: .easeOut, from: 0, to: 1, direction: 0), .fadeIn(0.2, delay: delay), .fadeOut(0.35)]
    }
    func scaleIn(delay: Double = 0, dur: Double = 0.6) -> [Animation] {
        [Animation(trigger: .onShow, kind: .scale, duration: dur, delay: delay, easing: .backOut, from: 0.6, to: 1), .fadeIn(0.25, delay: delay), .fadeOut(0.3)]
    }
    var pulse: Animation { .pulse(period: 1.4, amount: 0.04) }
    /// Fire stinger that sweeps left over the screen on show, revealing the scene behind it.
    func fireReveal(delay: Double = 0.0) -> Layer {
        var l = img("Fire Stinger", "stinger.firewipe", x: -500, y: 0, w: 3840, h: 1080)
        l.animations = [Animation(trigger: .onShow, kind: .slide, duration: 1.5, delay: delay, easing: .easeInOut, from: 0, to: 3900, direction: 180)]
        return l
    }
    func hazardBars() -> [Layer] {
        [img("Hazard Top", "tex.hazardtape", x: 0, y: 0, w: 1920, h: 90 * 0.5, anims: slideIn(270, 80)),
         img("Hazard Bottom", "tex.hazardtape", x: 0, y: 1080 - 45, w: 1920, h: 45, anims: slideIn(90, 80))]
    }
    func finish() -> [Layer] {
        [fx("Vignette", EffectPresets.vignette), fx("Film Grain", EffectPresets.filmGrain, opacity: 0.6), fx("Scanlines", EffectPresets.scanlines, opacity: 0.35)]
    }
    func scene(_ id: String, _ name: String, bg: Background = .solid(RGBA(hex: 0x07090B)), _ layers: [Layer], inT: SceneTransition? = .init(.fade, duration: 0.5), outT: SceneTransition? = .init(.fade, duration: 0.4)) -> LayerScene {
        LayerScene(id: id, name: name, background: bg, layers: layers, transitionIn: inT, transitionOut: outT)
    }
}

enum TemplateDefs {
    static let all: [PropTemplate] = [
        .init(id: "bgp.startingsoon", name: "Starting Soon", summary: "Animated embers, flame bed, big title and countdown.", tags: ["intro", "countdown"], slots: [], build: startingSoon),
        .init(id: "bgp.maingame", name: "Main Game + Facecam", summary: "Full-bleed gameplay, angular facecam, name plate, LIVE tag, social bar, kill-feed area.", tags: ["gameplay", "facecam"], slots: ["Gameplay", "Facecam"], build: mainGame),
        .init(id: "bgp.squad4", name: "Squad 4-Phone Grid", summary: "Four portrait phone feeds in angular frames with name plates and health bars.", tags: ["squad", "phones"], slots: ["Phone 1", "Phone 2", "Phone 3", "Phone 4"], build: squad4),
        .init(id: "bgp.duo", name: "Duo Spectator + Commentary", summary: "Two spectator feeds side by side with a circular commentary cam.", tags: ["duo", "commentary"], slots: ["Player 1", "Player 2", "Commentary"], build: duo),
        .init(id: "bgp.matchintro", name: "Match Intro", summary: "Team VS bar, map name and a fire stinger reveal.", tags: ["intro", "versus"], slots: [], build: matchIntro),
        .init(id: "bgp.scoreboard", name: "Scoreboard / Standings", summary: "Tactical standings table bound to team and score variables.", tags: ["standings", "scores"], slots: [], build: scoreboard),
        .init(id: "bgp.winner", name: "Chicken Dinner / Winner", summary: "Winner winner end screen with sparks, trophy and chicken.", tags: ["end", "win"], slots: [], build: winner),
        .init(id: "bgp.brb", name: "BRB", summary: "Smoky fire BRB banner with a break timer.", tags: ["break"], slots: [], build: brb),
        .init(id: "bgp.finalcircle", name: "Final Circle", summary: "Gameplay with a pulsing red tension vignette and zone timer.", tags: ["gameplay", "tension"], slots: ["Gameplay"], build: finalCircle),
        .init(id: "bgp.berightback", name: "Be Right Back (Minimal)", summary: "Calm hex-armour backdrop with a centred clock.", tags: ["break", "minimal"], slots: [], build: beRightBack),
        .init(id: "bgp.thanks", name: "Thanks For Watching", summary: "End card with socials, subscribe / like / follow buttons.", tags: ["outro", "social"], slots: [], build: thanks),
    ]

    static func startingSoon(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Ember Backdrop", "bg.ember"), b.fx("Animated Gradient", EffectPresets.animatedGradient(t), blend: .add, opacity: 0.7)]
        L.append(b.fx("Smoke", EffectPresets.smoke(t), y: 300, h: 780, opacity: 0.8))
        L.append(b.img("Fire Bed", "fire.bed", x: -20, y: 650, w: 1960, h: 430, blend: .add, anims: [.float(period: 2.4, amplitude: 6), .fadeIn(1.0)]))
        L.append(b.fx("Fire", EffectPresets.fire(t), x: 0, y: 700, w: 1920, h: 380, blend: .add))
        L.append(b.fx("Embers", EffectPresets.embers(t, count: 320), blend: .add))
        L += b.hazardBars()
        L.append(b.fx("HUD Brackets", EffectPresets.brackets(t), x: 60, y: 90, w: 1800, h: 900, opacity: 0.8))
        L.append(b.txt("Kicker", "{{matchTitle}}", x: 360, y: 190, w: 1200, h: 60, TextPresets.tag(t, size: 42), anims: b.slideIn(270, 80, delay: 0.3)))
        L.append(b.txt("Title", "STARTING SOON", x: 160, y: 270, w: 1600, h: 240, TextPresets.headline(t, size: 210), anims: b.glitchIn(delay: 0.2) + [Animation(trigger: .loop, kind: .pulse, duration: 2.4, easing: .easeInOut, from: 0, to: 0.015)]))
        L.append(b.fx("Countdown", EffectPresets.countdown(t, text: "{{countdownTimer}}", size: 160), x: 560, y: 540, w: 800, h: 200, anims: b.fadeInOut(delay: 0.8)))
        L.append(b.txt("Sub", "STAND BY  -  DROP INCOMING", x: 360, y: 760, w: 1200, h: 60, TextPresets.tag(t, size: 34, color: .white), anims: b.fadeInOut(delay: 1.0)))
        L.append(b.fx("Light Sweep", EffectPresets.lightSweep(t), blend: .add, opacity: 0.6))
        L += b.finish()
        return b.scene("bgp.startingsoon", "Starting Soon", L, inT: .init(.wipe, duration: 0.8))
    }

    static func mainGame(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.src("Gameplay", .slate, x: 0, y: 0, w: 1920, h: 1080)]
        L.append(b.fx("Vignette", EffectPresets.vignette, opacity: 0.45))
        // facecam bottom-right (frame.cam43 is 480x360, inner 22..458 x 22..338)
        let fx0 = 1410.0, fy0 = 640.0
        var cam = b.group("Facecam", [
            b.src("Facecam Source", .camera, x: fx0 + 22, y: fy0 + 22, w: 436, h: 316),
            b.img("Cam Frame", "frame.cam43", x: fx0, y: fy0, w: 480, h: 360),
            b.img("Name Plate", "banner.nameplate.slim", x: fx0 - 10, y: fy0 + 354, w: 500),
            b.txt("Player Name", "{{playerName}}", x: fx0 + 40, y: fy0 + 360, w: 400, h: 44, TextPresets.name(t, size: 30)),
        ])
        cam.animations = b.slideIn(0, -520, delay: 0.1)
        cam.animations = [.slideIn(from: 520, direction: 0, dur: 0.7), .fadeIn(0.3), Animation(trigger: .onHide, kind: .slide, duration: 0.4, easing: .easeIn, from: 0, to: 520, direction: 0), .fadeOut(0.35)]
        L.append(cam)
        L.append(b.group("Live Tag", [b.img("LIVE", "banner.live", x: 50, y: 40, w: 190), ], anims: b.slideIn(180, 300, delay: 0.2)))
        L.append(b.group("Social Bar", [
            b.img("Social Plate", "social.youtube", x: 30, y: 985, w: 420),
            b.txt("Handle", "@7XENSTUDIO", x: 130, y: 1002, w: 290, h: 40, TextPresets.name(t, size: 28, string: "@7XENSTUDIO")),
        ], anims: b.slideIn(180, 500, delay: 0.4)))
        // kill-feed area top-right
        var feed: [Layer] = []
        for i in 0..<3 {
            let y = 36.0 + Double(i) * 54
            feed.append(b.img("Kill Row \(i + 1)", ["hud.killfeed.friend", "hud.killfeed.enemy", "hud.killfeed.friend"][i], x: 1380, y: y, w: 520, opacity: i == 0 ? 1 : 0.9))
            // attacker left of the weapon icon (x 214...306 in the row), victim right of it; text box height = row plate (38) so it centres on the plate
            feed.append(b.txt("Killer \(i + 1)", i == 0 ? "{{playerName}}" : "TEAMMATE", x: 1404, y: y + 4, w: 180, h: 38, TextPresets.name(t, size: 21, align: .left)))
            feed.append(b.txt("Victim \(i + 1)", "ENEMY", x: 1700, y: y + 4, w: 150, h: 38, TextPresets.name(t, size: 21, align: .left)))
        }
        L.append(b.group("Kill Feed", feed, anims: b.slideIn(0, -400, delay: 0.3)))
        L.append(b.group("Score Strip", [b.img("Match Plate", "banner.mapname", x: 700, y: 24, w: 520),
                                         b.txt("Title", "{{matchTitle}}  -  {{timer}}", x: 740, y: 36, w: 440, h: 40, TextPresets.tag(t, size: 28, color: .white))], anims: b.slideIn(270, 100, delay: 0.5)))
        return b.scene("bgp.maingame", "Main Game + Facecam", L, inT: .init(.fade, duration: 0.4))
    }

    static func squad4(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Gunmetal", "bg.gunmetal"), b.fx("Embers", EffectPresets.embers(t, count: 120), blend: .add, opacity: 0.6)]
        L.append(b.group("Title", [b.img("Title Banner", "banner.matchtitle", x: 440, y: 0, w: 1040), b.txt("Match Title", "{{matchTitle}}", x: 540, y: 28, w: 840, h: 70, TextPresets.headline(t, size: 60))], anims: b.slideIn(270, 200)))
        for i in 0..<4 {
            let x = 105.0 + Double(i) * 450, y = 150.0
            L.append(b.group("Phone \(i + 1)", [
                b.src("Phone \(i + 1) Source", .device(id: ""), x: x + 22, y: y + 22, w: 316, h: 596),
                b.img("Frame", "frame.phone", x: x, y: y, w: 360, h: 640),
                b.img("Name Plate", "banner.nameplate.slim", x: x - 10, y: y + 650, w: 380),
                b.txt("Name", "{{phone\(i + 1)}}", x: x + 36, y: y + 654, w: 290, h: 42, TextPresets.name(t, size: 26, string: "{{phone\(i + 1)}}")),
                b.img("Health", "hud.health", x: x + 6, y: y + 716, w: 340, opacity: 0.95),
                b.img("Armor", "hud.armor", x: x + 6, y: y + 760, w: 340, opacity: 0.95),
            ], anims: b.slideIn(i % 2 == 0 ? 90 : 270, 260, delay: 0.15 * Double(i))))
        }
        L.append(b.img("Live", "banner.live", x: 40, y: 20, w: 170, anims: b.glitchIn(delay: 0.6)))
        L += b.finish()
        return b.scene("bgp.squad4", "Squad 4-Phone Grid", L)
    }

    static func duo(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Backdrop", "bg.nightraid"), b.fx("Vignette", EffectPresets.vignette)]
        L.append(b.group("Title", [b.img("Banner", "banner.matchtitle", x: 440, y: 0, w: 1040), b.txt("Title", "{{matchTitle}}", x: 540, y: 28, w: 840, h: 70, TextPresets.headline(t, size: 60))], anims: b.slideIn(270, 200)))
        let k = 1.4
        for (i, x) in [30.0, 994.0].enumerated() {
            let y = 140.0
            L.append(b.group("Spectator \(i + 1)", [
                b.src("Spectator \(i + 1) Source", .device(id: ""), x: x + 24 * k, y: y + 24 * k, w: 592 * k, h: 312 * k),
                b.img("Frame", "frame.cornercut", x: x, y: y, w: 640 * k - 2, h: 360 * k),
                b.img("Plate", "banner.nameplate.slim", x: x + 20, y: y + 360 * k - 8, w: 520),
                b.txt("Name", i == 0 ? "{{team1}}" : "{{team2}}", x: x + 80, y: y + 360 * k - 2, w: 400, h: 44, TextPresets.name(t, size: 30)),
                b.txt("Score", i == 0 ? "{{score1}}" : "{{score2}}", x: x + 700, y: y + 360 * k - 8, w: 140, h: 60, TextPresets.number(t, size: 48)),
            ], anims: b.slideIn(i == 0 ? 0 : 180, i == 0 ? -700 : -700, delay: 0.15 * Double(i))))
        }
        L.append(b.group("Commentary", [
            b.src("Commentary Source", .camera, x: 820 + 21, y: 740 + 21, w: 238, h: 238, mask: Mask(.circle)),
            b.img("Ring", "frame.circle", x: 820, y: 740, w: 280, h: 280),
        ], anims: b.scaleIn(delay: 0.4)))
        L.append(b.img("VS", "banner.vsbadge", x: 880, y: 400, w: 160, anims: b.scaleIn(delay: 0.6)))
        L.append(b.txt("Commentary Tag", "COMMENTARY", x: 1110, y: 880, w: 300, h: 40, TextPresets.tag(t, size: 28, string: "COMMENTARY")))
        L.append(b.img("Live", "banner.live", x: 40, y: 20, w: 170))
        L += b.finish()
        return b.scene("bgp.duo", "Duo Spectator + Commentary", L)
    }

    static func matchIntro(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Dusk", "bg.dusk"), b.fx("Smoke", EffectPresets.smoke(t), y: 400, h: 680, opacity: 0.7), b.fx("Embers", EffectPresets.embers(t), blend: .add)]
        L.append(b.img("Map Strip", "banner.mapname", x: 700, y: 250, w: 520, anims: b.slideIn(270, 200, delay: 1.0)))
        L.append(b.txt("Map", "{{matchTitle}}", x: 740, y: 262, w: 440, h: 40, TextPresets.tag(t, size: 30, color: .white), anims: b.fadeInOut(delay: 1.3)))
        L.append(b.group("Teams", [
            b.img("VS Bar", "banner.vs", x: 60, y: 420, w: 1800),
            b.txt("Team 1", "{{team1}}", x: 170, y: 460, w: 650, h: 120, TextPresets.headline(t, size: 90, align: .left)),
            b.txt("Team 2", "{{team2}}", x: 1100, y: 460, w: 650, h: 120, TextPresets.headline(t, size: 90, align: .right)),
        ], anims: b.glitchIn(delay: 1.1)))
        L.append(b.txt("Round", "MATCH 01  -  {{score1}} : {{score2}}", x: 560, y: 700, w: 800, h: 60, TextPresets.tag(t, size: 40, color: .white), anims: b.fadeInOut(delay: 1.6)))
        L.append(b.fx("Spark Shower", EffectPresets.sparks(t), y: 500, h: 580, blend: .add, opacity: 0.8))
        L += b.finish()
        L.append(b.fireReveal())
        return b.scene("bgp.matchintro", "Match Intro", L, inT: .init(.cut, duration: 0))
    }

    static func scoreboard(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Tactical", "bg.tactical")]
        L.append(b.txt("Title", "{{matchTitle}}", x: 360, y: 40, w: 1200, h: 100, TextPresets.headline(t, size: 90), anims: b.slideIn(270, 160)))
        L.append(b.img("Header", "banner.scorehead", x: 470, y: 150, w: 980, anims: b.slideIn(180, 600)))
        let names = (1...8).map { "{{team\($0)}}" }
        let scores = (1...8).map { "{{score\($0)}}" }
        for i in 0..<8 {
            let y = 244.0 + Double(i) * 66
            let row: [Layer] = [
                b.img("Row", i % 2 == 0 ? "banner.scorerow" : "banner.scorerow.alt", x: 470, y: y, w: 980),
                b.txt("Rank", "\(i + 1)", x: 476, y: y + 8, w: 64, h: 46, TextPresets.number(t, size: 34, string: "\(i + 1)")),
                b.txt("Team", names[i], x: 620, y: y + 8, w: 460, h: 46, TextPresets.name(t, size: 32, string: names[i])),
                b.txt("Kills", scores[i], x: 1050, y: y + 8, w: 120, h: 46, TextPresets.number(t, size: 32, string: scores[i])),
                b.txt("Place", "#\(i + 1)", x: 1170, y: y + 8, w: 120, h: 46, TextPresets.number(t, size: 32, string: "#\(i + 1)")),
                b.txt("Total", "{{total\(i + 1)}}", x: 1310, y: y + 8, w: 120, h: 46, TextPresets.number(t, size: 34, string: "{{total\(i + 1)}}")),
            ]
            L.append(b.group("Row \(i + 1)", row, anims: b.slideIn(180, 700, delay: 0.08 * Double(i) + 0.2)))
        }
        L.append(b.img("Live", "banner.live", x: 40, y: 30, w: 170))
        L += b.finish()
        return b.scene("bgp.scoreboard", "Scoreboard / Standings", L)
    }

    static func winner(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Ember", "bg.dusk"), b.fx("Gradient", EffectPresets.animatedGradient(t), blend: .add)]
        L.append(b.fx("Light Sweep", EffectPresets.lightSweep(t), blend: .add))
        L.append(b.img("Sparks Left", "tex.sparks", x: 0, y: 0, w: 1920, h: 1080, opacity: 0.4, blend: .add))
        L.append(b.img("Trophy", "icon.trophy", x: 30, y: 300, w: 300, anims: b.scaleIn(delay: 0.3) + [.float(period: 3, amplitude: 10)]))
        L.append(b.img("Chicken", "icon.chicken", x: 1590, y: 300, w: 300, anims: b.scaleIn(delay: 0.5) + [.float(period: 3.4, amplitude: 10)]))
        L.append(b.img("Banner", "banner.chickendinner", x: 340, y: 270, w: 1240, anims: b.scaleIn(delay: 0.1) + [b.pulse]))
        L.append(b.txt("Squad", "{{team1}}", x: 360, y: 620, w: 1200, h: 120, TextPresets.headline(t, size: 100), anims: b.slideIn(90, 200, delay: 0.8)))
        L.append(b.txt("Stats", "KILLS {{score1}}   -   PLACEMENT #1", x: 360, y: 740, w: 1200, h: 60, TextPresets.tag(t, size: 40, color: .white), anims: b.fadeInOut(delay: 1.1)))
        L.append(b.img("Crown", "icon.crown", x: 860, y: 90, w: 200, anims: b.scaleIn(delay: 0.9)))
        L.append(b.fx("Sparks", EffectPresets.sparks(t), blend: .add))
        L.append(b.fx("Embers", EffectPresets.embers(t, count: 300), blend: .add))
        L += b.finish()
        return b.scene("bgp.winner", "Chicken Dinner / Winner", L, inT: .init(.zoom, duration: 0.6))
    }

    static func brb(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Smoke Fire", "bg.smokefire"), b.fx("Smoke", EffectPresets.smoke(t), opacity: 0.8), b.fx("Fire", EffectPresets.fire(t, intensity: 0.9), y: 760, h: 320, blend: .add)]
        L.append(b.img("Banner", "banner.brb", x: 360, y: 260, w: 1200, anims: b.slideIn(270, 300) + [.float(period: 3.2, amplitude: 8)]))
        L.append(b.fx("Timer", EffectPresets.countdown(t, text: "{{countdownTimer}}", size: 120), x: 560, y: 620, w: 800, h: 160, anims: b.fadeInOut(delay: 0.6)))
        L.append(b.txt("Sub", "BACK IN A MOMENT", x: 460, y: 770, w: 1000, h: 60, TextPresets.tag(t, size: 36, color: .white)))
        L.append(b.fx("Embers", EffectPresets.embers(t), blend: .add))
        L += b.hazardBars(); L += b.finish()
        return b.scene("bgp.brb", "BRB", L)
    }

    static func finalCircle(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.src("Gameplay", .slate, x: 0, y: 0, w: 1920, h: 1080)]
        L.append(b.img("Danger Vignette", "tex.vignette.hot", x: 0, y: 0, w: 1920, h: 1080, anims: [.fadeIn(0.8), Animation(trigger: .loop, kind: .fade, duration: 1.6, easing: .easeInOut, from: 0.3, to: 0.75)]))
        L.append(b.fx("Danger Pulse", EffectPresets.pulsingGlow(t, hot: true), opacity: 0.5))
        L.append(b.group("Zone Timer", [
            b.img("Zone", "hud.zone", x: 810, y: 20, w: 300),
            b.fx("Zone Countdown", EffectPresets.countdown(t, text: "{{timer}}", size: 54), x: 860, y: 128, w: 200, h: 80),
        ], anims: b.scaleIn(delay: 0.1) + [b.pulse]))
        L.append(b.txt("Label", "FINAL CIRCLE", x: 560, y: 330, w: 800, h: 110, TextPresets.headline(t, size: 100), anims: [Animation(trigger: .onShow, kind: .glitch, duration: 0.8, from: 1, to: 0), Animation(trigger: .onShow, kind: .fade, duration: 0.4, from: 0, to: 1), Animation(trigger: .onShow, kind: .fade, duration: 0.6, delay: 3.0, from: 1, to: 0)]))
        L.append(b.img("Live", "banner.live", x: 40, y: 30, w: 190))
        L.append(b.group("Cam", [b.src("Facecam", .camera, x: 1432, y: 784, w: 436, h: 262), b.img("Cam Frame", "frame.cam43", x: 1410, y: 762, w: 480, h: 306)], anims: b.slideIn(0, -520, delay: 0.2)))
        L.append(b.fx("Scanlines", EffectPresets.scanlines, opacity: 0.2))
        return b.scene("bgp.finalcircle", "Final Circle", L)
    }

    static func beRightBack(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Hex", "bg.hex"), b.fx("Smoke", EffectPresets.smoke(t), opacity: 0.5), b.fx("Embers", EffectPresets.embers(t, count: 90), blend: .add, opacity: 0.8)]
        L.append(b.img("Ring", "frame.circle", x: 760, y: 190, w: 400, anims: b.scaleIn() + [.spin(period: 40, degrees: 360)]))
        L.append(b.txt("Title", "BE RIGHT BACK", x: 260, y: 640, w: 1400, h: 150, TextPresets.headline(t, size: 130), anims: b.fadeInOut(delay: 0.2)))
        L.append(b.fx("Clock", EffectPresets.countdown(t, text: "{{countdownTimer}}", size: 120), x: 760, y: 280, w: 400, h: 200))
        L.append(b.txt("Sub", "{{matchTitle}}", x: 460, y: 800, w: 1000, h: 50, TextPresets.tag(t, size: 34, color: .white)))
        L += b.finish()
        return b.scene("bgp.berightback", "Be Right Back (Minimal)", L)
    }

    static func thanks(_ t: PropTheme) -> LayerScene {
        let b = TB(t: t)
        var L: [Layer] = [b.full("Dusk", "bg.dusk"), b.fx("Embers", EffectPresets.embers(t), blend: .add), b.fx("Smoke", EffectPresets.smoke(t), y: 400, h: 680, opacity: 0.6)]
        L.append(b.txt("Thanks", "THANKS FOR WATCHING", x: 160, y: 130, w: 1600, h: 200, TextPresets.headline(t, size: 170), anims: b.glitchIn(delay: 0.1)))
        L.append(b.txt("Sub", "SEE YOU ON THE NEXT DROP", x: 460, y: 330, w: 1000, h: 60, TextPresets.tag(t, size: 40, color: .white), anims: b.fadeInOut(delay: 0.6)))
        for (i, s) in ["youtube", "instagram", "discord", "twitch"].enumerated() {
            let x = 260.0 + Double(i % 2) * 720, y = 470.0 + Double(i / 2) * 110
            L.append(b.group(s.capitalized, [b.img("Bar", "social.\(s)", x: x, y: y, w: 640), b.txt("Handle", "@7XENSTUDIO", x: x + 150, y: y + 18, w: 440, h: 56, TextPresets.name(t, size: 34, string: "@7XENSTUDIO"))], anims: b.slideIn(i % 2 == 0 ? 0 : 180, -600, delay: 0.2 * Double(i) + 0.6)))
        }
        L.append(b.img("Subscribe", "button.subscribe", x: 460, y: 760, w: 380, anims: b.scaleIn(delay: 1.6) + [b.pulse]))
        L.append(b.img("Like", "button.like", x: 870, y: 760, w: 240, anims: b.scaleIn(delay: 1.8)))
        L.append(b.img("Follow", "button.follow", x: 1140, y: 760, w: 300, anims: b.scaleIn(delay: 2.0)))
        L.append(b.img("Next", "banner.next", x: 610, y: 930, w: 700, anims: b.slideIn(90, 200, delay: 2.2)))
        L.append(b.txt("Next Text", "{{matchTitle}}", x: 900, y: 945, w: 380, h: 40, TextPresets.tag(t, size: 28, color: .white, align: .left)))
        L += b.finish()
        return b.scene("bgp.thanks", "Thanks For Watching", L)
    }
}
