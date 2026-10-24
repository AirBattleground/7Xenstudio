// Layer / style / animation builders for the OPUS Advanced Studio scenes (SceneModel API only).
import Foundation

enum AdvKit {
    // MARK: fonts (installed on every macOS 14+; SpriteRaster accepts PostScript names)
    static let display = "AvenirNextCondensed-HeavyItalic"
    static let number = "Futura-CondensedExtraBold"
    static let label = "DINCondensed-Bold"
    static let body = "AvenirNextCondensed-DemiBold"
    static let heavy = "AvenirNextCondensed-Heavy"

    /// {{key}} binding.
    static func v(_ key: String) -> String { "{{\(key)}}" }

    // MARK: text styles
    static let metalGradient = Gradient(stops: ABG.metal.map { GradientStop(Double($0.0), RGBA(hex: $0.1)) }, angle: 90)
    static let silverGradient = Gradient(stops: [GradientStop(0, RGBA(hex: 0xFFFFFF)), GradientStop(0.5, RGBA(hex: 0xE4E8EE)), GradientStop(0.53, RGBA(hex: 0xA9B1BC)), GradientStop(1, RGBA(hex: 0xDCE0E6))], angle: 90)

    static func gold(_ s: String, size: Double, font: String = display, align: TextAlign = .center, tracking: Double = 0, stroke: Double? = nil, glow: Double = 0.55) -> TextStyle {
        TextStyle(s, font: font, size: size, weight: 900, tracking: tracking, color: ABG.gold2C, gradient: metalGradient,
                  stroke: Stroke(width: stroke ?? max(1, size * 0.018), color: RGBA(hex: 0x2A1A04)),
                  shadow: Shadow(color: RGBA(0, 0, 0, glow), blur: size * 0.07, dx: 0, dy: size * 0.035), alignment: align, allCaps: true)
    }
    static func white(_ s: String, size: Double, font: String = display, align: TextAlign = .center, tracking: Double = 0, color: RGBA = .white) -> TextStyle {
        TextStyle(s, font: font, size: size, weight: 800, tracking: tracking, color: color,
                  shadow: Shadow(color: RGBA(0, 0, 0, 0.8), blur: max(3, size * 0.08), dx: 0, dy: max(1, size * 0.04)), alignment: align, allCaps: true)
    }
    static func dark(_ s: String, size: Double, font: String = display, align: TextAlign = .center, tracking: Double = 0) -> TextStyle {
        TextStyle(s, font: font, size: size, weight: 900, tracking: tracking, color: RGBA(hex: 0x0D0B08),
                  shadow: Shadow(color: RGBA(1, 0.95, 0.75, 0.35), blur: 2, dx: 0, dy: 1), alignment: align, allCaps: true)
    }
    static func caption(_ s: String, size: Double = 20, color: RGBA = ABG.gold2C, align: TextAlign = .center, tracking: Double? = nil) -> TextStyle {
        TextStyle(s, font: label, size: size, weight: 700, tracking: tracking ?? size * 0.18, color: color,
                  shadow: Shadow(color: RGBA(0, 0, 0, 0.7), blur: 3, dx: 0, dy: 1), alignment: align, allCaps: true)
    }

    // MARK: layers
    static func img(_ name: String, _ id: String, x: Double, y: Double, w: Double, h: Double? = nil, opacity: Double = 1, blend: BlendMode = .normal, anims: [Animation] = []) -> Layer {
        var hh = h ?? w
        if h == nil, let a = BuiltinAssets.asset(id) { hh = w * Double(a.size.height / a.size.width) }
        var l = Layer(name: name, kind: .image(ImageSpec(builtin: id, fit: .stretch)), transform: Transform(x: x, y: y, w: w, h: hh), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    static func txt(_ name: String, _ style: TextStyle, x: Double, y: Double, w: Double, h: Double, opacity: Double = 1, anims: [Animation] = []) -> Layer {
        var l = Layer(name: name, kind: .text(style), transform: Transform(x: x, y: y, w: w, h: h), opacity: opacity); l.animations = anims; return l
    }
    static func rect(_ name: String, x: Double, y: Double, w: Double, h: Double, _ fill: Fill, rotation: Double = 0, opacity: Double = 1, blend: BlendMode = .normal, anims: [Animation] = []) -> Layer {
        var l = Layer(name: name, kind: .shape(ShapeSpec(.rect, fill: fill)), transform: Transform(x: x, y: y, w: w, h: h, rotation: rotation), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    static func ellipse(_ name: String, x: Double, y: Double, w: Double, h: Double, _ fill: Fill, opacity: Double = 1, blend: BlendMode = .normal, anims: [Animation] = []) -> Layer {
        var l = Layer(name: name, kind: .shape(ShapeSpec(.ellipse, fill: fill)), transform: Transform(x: x, y: y, w: w, h: h), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    /// Advanced GPU effect layer. `base` is the classic fallback kind older readers show.
    static func fx(_ name: String, _ kind: AdvancedFX, base: EffectKind = .pulsingGlow, color: RGBA = ABG.gold1C, color2: RGBA = ABG.gold3C,
                   intensity: Double = 1, speed: Double = 1, count: Int = 100, seed: UInt32 = 1, size: Double = 24, thickness: Double = 3, angle: Double = 0,
                   delay: Double = 0, period: Double = 0, x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080,
                   blend: BlendMode = .add, opacity: Double = 1, anims: [Animation] = []) -> Layer {
        var spec = EffectSpec(base, color: color, color2: color2, intensity: intensity, speed: speed, count: count, seed: seed, size: size, thickness: thickness, angle: angle)
        spec.advanced = kind; spec.delay = delay; spec.period = period
        var l = Layer(name: name, kind: .effect(spec), transform: Transform(x: x, y: y, w: w, h: h), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    static func classic(_ name: String, _ spec: EffectSpec, x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080, blend: BlendMode = .normal, opacity: Double = 1, anims: [Animation] = []) -> Layer {
        var l = Layer(name: name, kind: .effect(spec), transform: Transform(x: x, y: y, w: w, h: h), opacity: opacity, blend: blend)
        l.animations = anims; return l
    }
    static func group(_ name: String, _ kids: [Layer], x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080, anims: [Animation] = []) -> Layer {
        var g = Layer(name: name, kind: .group(kids), transform: Transform(x: x, y: y, w: w, h: h)); g.animations = anims; return g
    }
    /// Box of size w x h centred on (cx, cy).
    static func centred(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> (x: Double, y: Double, w: Double, h: Double) { (cx - w / 2, cy - h / 2, w, h) }

    // MARK: animation recipes
    static func fadeIn(_ delay: Double, _ dur: Double = 0.4) -> Animation { .fadeIn(dur, delay: delay) }
    static let out: Animation = .fadeOut(0.35)
    /// Hidden until `at`, then visible (step) -- pairs with a decaying fade for flashes.
    static func appear(at: Double) -> Animation { Animation(trigger: .onShow, kind: .fade, duration: 0.001, delay: at, easing: .linear, from: 0, to: 1) }
    static func slam(_ delay: Double, from: Double = 1.6, dur: Double = 0.42) -> [Animation] {
        [Animation(trigger: .onShow, kind: .scale, duration: dur, delay: delay, easing: .easeOut, from: from, to: 1), .fadeIn(dur * 0.45, delay: delay), out]
    }
    static func pop(_ delay: Double, from: Double = 0.6, dur: Double = 0.6) -> [Animation] {
        [Animation(trigger: .onShow, kind: .scale, duration: dur, delay: delay, easing: .backOut, from: from, to: 1), .fadeIn(dur * 0.5, delay: delay), out]
    }
    static func slide(_ delay: Double, from px: Double, dir: Double, dur: Double = 0.65, easing: Easing = .easeOut) -> [Animation] {
        [Animation(trigger: .onShow, kind: .slide, duration: dur, delay: delay, easing: easing, from: px, to: 0, direction: dir), .fadeIn(dur * 0.5, delay: delay),
         Animation(trigger: .onHide, kind: .slide, duration: 0.35, easing: .easeIn, from: 0, to: px * 0.5, direction: dir), out]
    }
    static func wipe(_ delay: Double, dir: Double = 0, dur: Double = 0.7) -> [Animation] {
        [Animation(trigger: .onShow, kind: .wipe, duration: dur, delay: delay, easing: .easeInOut, from: 0, to: 1, direction: dir), .fadeIn(0.2, delay: delay), out]
    }
    static func glitchIn(_ delay: Double, dur: Double = 0.55) -> [Animation] {
        [Animation(trigger: .onShow, kind: .glitch, duration: dur, delay: delay, easing: .easeOut, from: 1, to: 0), .fadeIn(0.12, delay: delay),
         Animation(trigger: .onShow, kind: .slide, duration: dur, delay: delay, easing: .easeOut, from: 26, to: 0, direction: 180), out]
    }
    static func drift(_ px: Double, period: Double, dir: Double = 0, scale: Double = 0, phase: Double = 0) -> Animation {
        Animation(trigger: .loop, kind: .drift, duration: period, delay: phase, easing: .linear, from: scale, to: px, direction: dir)
    }
    static func shake(_ amp: Double, at: Double, dur: Double = 0.65) -> Animation {
        Animation(trigger: .onShow, kind: .shake, duration: dur, delay: at, easing: .easeOut, from: amp, to: 0)
    }
    static func pulse(_ period: Double = 1.0, _ amount: Double = 0.02) -> Animation { .pulse(period: period, amount: amount) }
    static func breathe(_ period: Double, lo: Double, hi: Double = 1) -> Animation {
        Animation(trigger: .loop, kind: .fade, duration: period, easing: .easeInOut, from: lo, to: hi)
    }
    /// A one-shot flash: hidden, jumps to full at `at`, decays over `dur`.
    static func flash(at: Double, dur: Double = 0.55) -> [Animation] {
        [appear(at: at), Animation(trigger: .onShow, kind: .fade, duration: dur, delay: at + 0.001, easing: .easeOut, from: 1, to: 0)]
    }

    static let transitionIn = SceneTransition(.lightWipe, duration: 0.9, direction: 200)
    static let transitionOut = SceneTransition(.lightWipe, duration: 0.8, direction: 200)
    static let canvasW = 1920.0, canvasH = 1080.0
}
