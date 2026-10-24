// "Triggers": one-shot on-air animations (kill pop-up, headshot, squad wipe, ...) fired over whatever scene is on Program.
import Foundation
import CoreGraphics

struct TriggerDef: Identifiable, Hashable {
    let id: String
    let name: String
    let key: String            // hotkey (single character, no modifiers)
    let icon: String           // SF Symbol
    let accent: UInt32
    var id_: String { id }
}

enum StudioTriggers {
    static let all: [TriggerDef] = [
        TriggerDef(id: "kill", name: "Kill", key: "k", icon: "scope", accent: 0xFF5A1F),
        TriggerDef(id: "headshot", name: "Headshot", key: "h", icon: "target", accent: 0xFFC21A),
        TriggerDef(id: "squadwipe", name: "Squad Wipe", key: "w", icon: "person.3.fill", accent: 0xE5261B),
        TriggerDef(id: "chicken", name: "Chicken Dinner", key: "c", icon: "trophy.fill", accent: 0xFFC21A),
        TriggerDef(id: "eliminated", name: "Eliminated", key: "e", icon: "xmark.octagon.fill", accent: 0xA80016),
        TriggerDef(id: "flash", name: "Flash", key: "f", icon: "bolt.fill", accent: 0xFFFFFF),
        TriggerDef(id: "countdown", name: "Countdown 10s", key: "g", icon: "timer", accent: 0x35B6FF),
    ]
    static func def(forKey k: String) -> TriggerDef? { all.first { $0.key == k.lowercased() } }

    /// Variable keys the triggers use.
    static let killCountKey = "killCount", countdownKey = "countdown"

    static func make(_ id: String, theme t: PropTheme = .ember) -> StudioEngine.Trigger? {
        let b = TB(t: t)
        func flash(_ peak: Double, _ dur: Double, _ c: RGBA = .white) -> Layer {
            var l = b.rect("Flash", x: 0, y: 0, w: 1920, h: 1080, Fill(c))
            l.animations = [Animation(trigger: .onShow, kind: .fade, duration: dur, easing: .easeOut, from: peak, to: 0)]
            return l
        }
        func popText(_ name: String, _ s: String, y: Double, size: Double, h: Double? = nil, delay: Double = 0) -> Layer {
            var l = b.txt(name, s, x: 160, y: y, w: 1600, h: h ?? size * 1.35, TextPresets.headline(t, size: size))
            l.animations = [Animation(trigger: .onShow, kind: .scale, duration: 0.45, delay: delay, easing: .backOut, from: 1.7, to: 1),
                            .fadeIn(0.12, delay: delay), .fadeOut(0.35)]
            return l
        }
        switch id {
        case "kill":
            let L: [Layer] = [
                flash(0.38, 0.22, RGBA(hex: t.glow)),
                b.fx("Impact Sparks", EffectPresets.sparks(t), x: 460, y: 560, w: 1000, h: 400, blend: .add, anims: [.fadeOut(0.4)]),
                b.img("Kill Marker", "hud.hit.kill", x: 872, y: 330, w: 176, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.3, easing: .backOut, from: 2.0, to: 1), .fadeIn(0.08), .fadeOut(0.3)]),
                popText("Kill Text", "KILL ×{{\(killCountKey)}}", y: 520, size: 190),
            ]
            return .init(id: id, layers: L, duration: 2.2, shake: 14, shakeDuration: 0.4)
        case "headshot":
            let L: [Layer] = [
                flash(0.3, 0.2, RGBA(hex: t.glow)),
                b.img("Headshot Marker", "hud.hit.head", x: 860, y: 300, w: 200, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.3, easing: .backOut, from: 2.2, to: 1), .fadeIn(0.08), .fadeOut(0.3)]),
                popText("Headshot Text", "HEADSHOT!", y: 520, size: 190),
                b.fx("Impact Sparks", EffectPresets.sparks(t), x: 460, y: 560, w: 1000, h: 400, blend: .add, anims: [.fadeOut(0.4)]),
            ]
            return .init(id: id, layers: L, duration: 2.2, shake: 10, shakeDuration: 0.35)
        case "squadwipe":
            let L: [Layer] = [
                flash(0.55, 0.5, RGBA(hex: t.hot)),
                b.img("Danger Vignette", "tex.vignette.hot", x: 0, y: 0, w: 1920, h: 1080, anims: [.fadeIn(0.2), .fadeOut(0.6)]),
                b.img("Squad Wipe Banner", "banner.squadwipe", x: 360, y: 300, w: 1200, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.5, easing: .backOut, from: 1.8, to: 1), .fadeIn(0.12), .fadeOut(0.5), Animation(trigger: .onShow, kind: .glitch, duration: 0.6, from: 1, to: 0)]),
                b.fx("Explosion Sparks", EffectPresets.sparks(t), blend: .add, anims: [.fadeOut(0.6)]),
                b.fx("Embers", EffectPresets.embers(t, count: 300), blend: .add, anims: [.fadeIn(0.5), .fadeOut(0.6)]),
            ]
            return .init(id: id, layers: L, duration: 4.0, hideLead: 0.7, shake: 30, shakeDuration: 0.8)
        case "chicken":
            let L: [Layer] = [
                flash(0.5, 0.5, RGBA(hex: t.glow)),
                b.img("Chicken Dinner", "banner.chickendinner", x: 280, y: 290, w: 1360, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.7, easing: .backOut, from: 0.5, to: 1), .fadeIn(0.2), .fadeOut(0.6), b.pulse]),
                b.img("Trophy", "icon.trophy", x: 80, y: 340, w: 280, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.6, delay: 0.25, easing: .backOut, from: 0.4, to: 1), .fadeIn(0.2, delay: 0.25), .fadeOut(0.5), .float(period: 3, amplitude: 8)]),
                b.img("Chicken", "icon.chicken", x: 1560, y: 340, w: 280, anims: [Animation(trigger: .onShow, kind: .scale, duration: 0.6, delay: 0.4, easing: .backOut, from: 0.4, to: 1), .fadeIn(0.2, delay: 0.4), .fadeOut(0.5), .float(period: 3.4, amplitude: 8)]),
                b.fx("Sparks", EffectPresets.sparks(t), blend: .add, anims: [.fadeOut(0.6)]),
                b.fx("Embers", EffectPresets.embers(t, count: 400), blend: .add, anims: [.fadeIn(0.4), .fadeOut(0.6)]),
            ]
            return .init(id: id, layers: L, duration: 6.5, hideLead: 0.8, shake: 12, shakeDuration: 0.4)
        case "eliminated":
            var banner = b.img("Eliminated", "banner.eliminated", x: 400, y: 340, w: 1120, anims: [Animation(trigger: .onShow, kind: .glitch, duration: 0.7, from: 1, to: 0), .fadeIn(0.12), .fadeOut(0.5), Animation(trigger: .onShow, kind: .scale, duration: 0.4, easing: .easeOut, from: 1.25, to: 1)])
            banner.effects = [Effect(.chromaticAberration, amount: 0.25)]
            let L: [Layer] = [
                flash(0.35, 0.4, RGBA(hex: t.hot)),
                b.fx("Red Tint", EffectPresets.dangerVignette(t), anims: [.fadeIn(0.2), .fadeOut(0.5)]),
                banner,
                b.fx("Scanlines", EffectPresets.scanlines, opacity: 0.5, anims: [.fadeOut(0.4)]),
            ]
            return .init(id: id, layers: L, duration: 3.2, shake: 18, shakeDuration: 0.5)
        case "flash":
            return .init(id: id, layers: [flash(0.9, 0.35)], duration: 0.5, hideLead: 0.1)
        case "countdown":
            var n = b.txt("Countdown Number", "{{\(countdownKey)}}", x: 560, y: 300, w: 800, h: 460, TextPresets.headline(t, size: 400))
            n.animations = [.fadeIn(0.2), .fadeOut(0.4), Animation(trigger: .loop, kind: .pulse, duration: 1, easing: .easeOut, from: 0.12, to: 0)]
            let cap = b.txt("Countdown Caption", "GET READY", x: 460, y: 220, w: 1000, h: 80, TextPresets.tag(t, size: 56, color: .white), anims: [.fadeIn(0.3), .fadeOut(0.3)])
            let ring = b.fx("Pulse", EffectPresets.pulsingGlow(t), opacity: 0.4)
            return .init(id: id, layers: [ring, cap, n], duration: 10.8, hideLead: 0.5)
        default: return nil
        }
    }
}
