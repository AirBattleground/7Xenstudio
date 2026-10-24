// Text + effect presets for the Battleground Pro pack. Built only from the SceneModel API.
import Foundation

extension PropTheme {
    var primaryRGBA: RGBA { RGBA(hex: primary) }
    var hotRGBA: RGBA { RGBA(hex: hot) }
    var glowRGBA: RGBA { RGBA(hex: glow) }
}

/// Installed-font aware text styles (Impact / DIN Condensed / Avenir Next Condensed / Menlo) with fallbacks resolved at call time.
enum TextPresets {
    static var headlineFont: String { PFont.resolve(PFont.headline) }
    static var tagFont: String { PFont.resolve(PFont.tag) }
    static var italicFont: String { PFont.resolve(PFont.italic) }
    static var monoFont: String { PFont.resolve(PFont.mono) }
    static var bodyFont: String { PFont.resolve(PFont.body) }

    /// Big stencil-style headline with a white to warm gradient and accent glow.
    static func headline(_ t: PropTheme = .ember, size: Double = 120, string: String = "HEADLINE", align: TextAlign = .center) -> TextStyle {
        TextStyle(string, font: headlineFont, size: size, weight: 900, tracking: size * 0.03, color: .white,
                  gradient: Gradient.linear(.white, RGBA(hex: t.glow), angle: 90),
                  shadow: Shadow(color: t.primaryRGBA.with(alpha: 0.9), blur: size * 0.16, dx: 0, dy: 0), alignment: align, allCaps: true)
    }
    /// Scores, timers, counters (monospaced numerals).
    static func number(_ t: PropTheme = .ember, size: Double = 72, string: String = "{{score1}}") -> TextStyle {
        TextStyle(string, font: monoFont, size: size, weight: 900, color: .white,
                  shadow: Shadow(color: t.primaryRGBA.with(alpha: 0.8), blur: size * 0.12), alignment: .center)
    }
    /// Small condensed accent label ("NEXT MATCH", "SQUAD").
    static func tag(_ t: PropTheme = .ember, size: Double = 30, string: String = "TAG", color: RGBA? = nil, align: TextAlign = .center) -> TextStyle {
        TextStyle(string, font: tagFont, size: size, weight: 800, tracking: size * 0.12, color: color ?? t.primaryRGBA,
                  shadow: Shadow(color: RGBA(0, 0, 0, 0.7), blur: 4, dx: 0, dy: 2), alignment: align, allCaps: true)
    }
    /// Player / team names on plates.
    static func name(_ t: PropTheme = .ember, size: Double = 34, string: String = "{{playerName}}", align: TextAlign = .left) -> TextStyle {
        TextStyle(string, font: italicFont, size: size, weight: 800, italic: false, tracking: size * 0.04, color: .white,
                  shadow: Shadow(color: RGBA(0, 0, 0, 0.75), blur: 5, dx: 0, dy: 2), alignment: align, allCaps: true)
    }
    static func ticker(_ t: PropTheme = .ember, size: Double = 30, string: String = "") -> TextStyle {
        TextStyle(string, font: bodyFont, size: size, weight: 600, tracking: 1, color: .white, alignment: .left, allCaps: true)
    }
    static let all: [(name: String, make: (PropTheme) -> TextStyle)] = [
        ("Headline", { headline($0) }), ("Number", { number($0) }), ("Tag", { tag($0) }), ("Player Name", { name($0) }), ("Ticker", { ticker($0, string: "BREAKING: SQUAD WIPE") })
    ]
}

/// Procedural effect presets (colours / rates / sizes) for the engine's `.effect` layers.
enum EffectPresets {
    static func fire(_ t: PropTheme = .ember, intensity: Double = 1.0) -> EffectSpec {
        EffectSpec(.fireEmitter, color: t.glowRGBA, color2: t.hotRGBA, intensity: intensity, speed: 1.0, count: 700, seed: 7, size: 65)
    }
    static func embers(_ t: PropTheme = .ember, count: Int = 260) -> EffectSpec {
        EffectSpec(.embers, color: t.glowRGBA, color2: t.primaryRGBA, intensity: 1.0, speed: 0.8, count: count, seed: 11, size: 6)
    }
    static func smoke(_ t: PropTheme = .ember) -> EffectSpec {
        EffectSpec(.smoke, color: RGBA(0.62, 0.64, 0.67, 0.5), color2: RGBA(0.12, 0.13, 0.15, 0.4), intensity: 0.7, speed: 0.5, count: 90, seed: 3, size: 160)
    }
    static func sparks(_ t: PropTheme = .ember) -> EffectSpec {
        EffectSpec(.sparks, color: t.glowRGBA, color2: t.primaryRGBA, intensity: 1.0, speed: 1.4, count: 120, seed: 5, size: 3)
    }
    static func lightning(_ t: PropTheme = .ice) -> EffectSpec {
        EffectSpec(.lightning, color: t.glowRGBA, color2: t.primaryRGBA, intensity: 1.0, speed: 0.6, seed: 9, thickness: 3)
    }
    static let scanlines = EffectSpec(.scanlines, color: RGBA(0, 0, 0, 0.35), intensity: 0.5, size: 4)
    static func glitch(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.glitch, color: t.primaryRGBA, color2: RGBA(0, 0.9, 1), intensity: 0.6, speed: 0.8, seed: 4) }
    static let vignette = EffectSpec(.vignette, color: RGBA(0, 0, 0, 1), intensity: 0.75, size: 0.55)
    static func dangerVignette(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.vignette, color: t.hotRGBA, color2: t.hotRGBA, intensity: 0.9, speed: 1, size: 0.5) }
    static let filmGrain = EffectSpec(.filmGrain, intensity: 0.35)
    static func lightSweep(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.lightSweep, color: t.glowRGBA, intensity: 0.5, speed: 0.25, angle: 20) }
    static func pulsingGlow(_ t: PropTheme = .ember, hot: Bool = false) -> EffectSpec { EffectSpec(.pulsingGlow, color: hot ? t.hotRGBA : t.primaryRGBA, intensity: 0.8, speed: 0.8) }
    static func brackets(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.hudCornerBrackets, color: t.primaryRGBA, intensity: 1, size: 80, thickness: 4) }
    static func radar(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.radarSweep, color: t.primaryRGBA, color2: t.hotRGBA, intensity: 1, speed: 0.5) }
    static func animatedGradient(_ t: PropTheme = .ember) -> EffectSpec { EffectSpec(.animatedGradient, color: t.hotRGBA.with(alpha: 0.45), color2: t.primaryRGBA.with(alpha: 0.05), speed: 0.15, angle: 90) }
    static func ticker(_ t: PropTheme = .ember, text: String) -> EffectSpec { EffectSpec(.ticker, color: .white, color2: t.primaryRGBA, speed: 1, text: text, fontSize: 30) }
    static func countdown(_ t: PropTheme = .ember, text: String = "{{timer}}", size: Double = 140) -> EffectSpec { EffectSpec(.countdown, color: .white, color2: t.primaryRGBA, text: text, fontSize: size) }
    static func killfeed(_ t: PropTheme = .ember, text: String) -> EffectSpec { EffectSpec(.killfeedLine, color: .white, color2: t.primaryRGBA, text: text, fontSize: 24) }

    /// Named list for the editor's effect picker (name, spec).
    static func all(_ t: PropTheme = .ember) -> [(name: String, spec: EffectSpec)] {
        [("Ember Fire", fire(t)), ("Roaring Fire", fire(t, intensity: 1.6)), ("Floating Embers", embers(t)), ("Battle Smoke", smoke(t)), ("Spark Shower", sparks(t)),
         ("Lightning", lightning(t)), ("CRT Scanlines", scanlines), ("Glitch Tear", glitch(t)), ("Cinematic Vignette", vignette), ("Danger Vignette", dangerVignette(t)),
         ("Film Grain", filmGrain), ("Light Sweep", lightSweep(t)), ("Pulsing Glow", pulsingGlow(t)), ("Pulsing Danger", pulsingGlow(t, hot: true)),
         ("HUD Corner Brackets", brackets(t)), ("Radar Sweep", radar(t)), ("Animated Gradient", animatedGradient(t))]
    }
}
