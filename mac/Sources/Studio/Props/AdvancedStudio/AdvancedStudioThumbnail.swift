// "YouTube Thumbnail": a still (rendered at 1280x720, entrance animations finished) that the studio uploads as the
// stream's YouTube thumbnail through AirBattleground. Built for a ~168x94 card: one huge gold title, one info plate,
// a red LIVE tag and the AB mark; nothing that only reads at full size. Every data text is a {{MatchKeys}} binding.
import Foundation

extension AdvancedStudioPreset {
    static let thumbnailId = "opus.adv.thumbnail"
    static let thumbnailName = "YouTube Thumbnail"

    /// Not part of the match journey; a member of the OPUS Advanced Studio preset, usable from any preset.
    static func youtubeThumbnail() -> LayerScene {
        typealias K = AdvKit
        let v = AdvKit.v
        var l: [Layer] = []
        // backdrop: luxe art + gold smoke, darkened on the text side for contrast
        l.append(K.img("Backdrop", "adv.bg.luxe", x: 0, y: 0, w: 1920, h: 1080))
        l.append(K.fx("Gold Smoke", .goldSmoke, base: .smoke, color: RGBA(hex: 0xC8973A), color2: RGBA(hex: 0x3A2A10), intensity: 0.5, speed: 0.6, seed: 13, size: 380,
                      blend: .screen))
        l.append(K.rect("Text Shade", x: 0, y: 0, w: 1400, h: 1080,
                        Fill(gradient: Gradient(stops: [GradientStop(0, RGBA(0, 0, 0, 0.82)), GradientStop(0.7, RGBA(0, 0, 0, 0.55)), GradientStop(1, RGBA(0, 0, 0, 0))], angle: 0))))
        // right: god rays + slashes + the AB mark
        l.append(K.fx("God Rays", .godRays, base: .lightSweep, color: RGBA(hex: 0xFFE3A0), color2: ABG.gold3C, intensity: 0.85, speed: 1, count: 48, seed: 2,
                      x: 1060, y: -60, w: 900, h: 1000))
        var red = K.rect("Red Slash", x: 1250, y: -80, w: 14, h: 1240, Fill(ABG.redC), rotation: 14)
        red.glow = Glow(color: ABG.redC, radius: 18, intensity: 0.9)
        l.append(red)
        l.append(K.rect("Gold Slash", x: 1212, y: -80, w: 4, h: 1240, Fill(ABG.gold1C), rotation: 14, opacity: 0.85))
        let markW = 600.0
        let a = BuiltinAssets.asset("abg.logo.mark")
        let markH = markW * Double((a?.size.height ?? 1) / max(1, a?.size.width ?? 1))
        var mark = K.img("AB Mark", "abg.logo.mark", x: 1600 - markW / 2, y: 430 - markH / 2, w: markW, h: markH)
        mark.glow = Glow(color: ABG.gold2C, radius: 30, intensity: 0.6)
        mark.shadow = Shadow(color: RGBA(0, 0, 0, 0.7), blur: 26, dx: 0, dy: 14)
        l.append(mark)
        var word = K.img("Wordmark", "abg.logo.wordmark", x: 1600 - 300, y: 430 + markH / 2 + 30, w: 600)
        word.glow = Glow(color: ABG.gold2C, radius: 10, intensity: 0.3)
        l.append(word)
        // top-left: LIVE + local start time
        l.append(K.img("LIVE", "adv.live", x: 80, y: 64, w: 250, h: 77))
        l.append(K.txt("Starts At", K.white(v(MatchKeys.startsAtLocal), size: 58, font: K.heavy, align: .left, tracking: 2),
                       x: 360, y: 66, w: 880, h: 74))
        // the title: huge gold, at most 2 lines, shrinks to fit
        var ts = K.gold(v(MatchKeys.matchTitle), size: 240, align: .left, tracking: 1, stroke: 5, glow: 0.85)
        ts.maxLines = 2
        var title = K.txt("Match Title", ts, x: 70, y: 168, w: 1180, h: 580)
        title.glow = Glow(color: RGBA(hex: 0xFFC044), radius: 22, intensity: 0.45)
        l.append(title)
        // divider + info plate: {{round}} · MATCH {{matchNumber}} · {{map}}
        l.append(K.rect("Divider", x: 80, y: 782, w: 1120, h: 4,
                        Fill(gradient: Gradient(stops: [GradientStop(0, ABG.gold1C), GradientStop(0.7, ABG.gold2C), GradientStop(1, ABG.gold2C.with(alpha: 0))], angle: 0))))
        l.append(K.rect("Divider Tick", x: 80, y: 778, w: 120, h: 12, Fill(ABG.redC)))
        l.append(K.img("Info Plate", AdvancedStudioAssets.goldPlateID(1120, 130), x: 80, y: 826, w: 1120, h: 130))
        l.append(K.txt("Match Line", K.dark(v(MatchKeys.matchLine), size: 78, font: K.display, align: .left, tracking: 2),
                       x: 120, y: 838, w: 1050, h: 106))
        l += [K.classic("Vignette", EffectSpec(.vignette, color: RGBA(0, 0, 0, 1), intensity: 0.6, size: 0.6))]
        var s = LayerScene(id: thumbnailId, name: thumbnailName, background: .solid(RGBA(hex: ABG.black)), layers: l,
                           transitionIn: K.transitionIn, transitionOut: K.transitionOut)
        // shown when the match has no data yet (never fake match facts)
        s.variableDefaults = [MatchKeys.matchTitle: "LIVE NOW", MatchKeys.matchLine: "AIRBATTLEGROUND", MatchKeys.startsAtLocal: "WATCH LIVE"]
        return s
    }
}
