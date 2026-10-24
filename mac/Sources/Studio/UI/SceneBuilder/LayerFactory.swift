// Factories for new layers: shapes, text, built-in props, sources and FX presets; plus migration of legacy fixed-layout scenes.
import Foundation
import CoreGraphics

struct EffectPreset: Identifiable {
    var id: String
    var name: String
    var symbol: String
    var spec: EffectSpec
    var blend: BlendMode = .normal
    var frame: CGRect?          // nil = full canvas
}

enum LayerFactory {
    static func shape(_ kind: ShapeKind, canvas: CanvasSize) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        var spec = ShapeSpec(kind, fill: .gradient(.linear(RGBA(hex: 0xFF7A1A), RGBA(hex: 0xE5261B), angle: 90)))
        var size = CGSize(width: w * 0.2, height: h * 0.2)
        var name = "Rectangle"
        switch kind {
        case .rect: break
        case .roundedRect: spec.cornerRadius = 24; name = "Rounded Rectangle"
        case .ellipse: size = CGSize(width: h * 0.25, height: h * 0.25); name = "Ellipse"
        case .polygon: spec.sides = 6; size = CGSize(width: h * 0.25, height: h * 0.25); name = "Polygon"
        case .line: spec.lineWidth = 6; size = CGSize(width: w * 0.25, height: 0); name = "Line"; spec.fill = Fill(RGBA.white)
        }
        return Layer(name: name, kind: .shape(spec), transform: Transform(x: (w - size.width) / 2, y: (h - size.height) / 2, w: size.width, h: size.height))
    }
    static func star(canvas: CanvasSize) -> Layer {
        var l = shape(.polygon, canvas: canvas); l.name = "Star"
        if case .shape(var s) = l.kind { s.sides = 5; s.starInset = 0.5; l.kind = .shape(s) }
        return l
    }
    static func text(_ string: String = "YOUR TEXT", canvas: CanvasSize, size: Double = 96) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        var st = TextStyle(string, font: "Helvetica Neue", size: size, weight: 800, color: .white)
        st.shadow = Shadow(color: RGBA(0, 0, 0, 0.6), blur: 10, dx: 0, dy: 4)
        return Layer(name: "Text", kind: .text(st), transform: Transform(x: w * 0.2, y: h * 0.4, w: w * 0.6, h: size * 1.4))
    }
    static func image(builtin id: String, theme: PropTheme = .ember, canvas: CanvasSize) -> Layer {
        let th: String? = theme.isDefault ? nil : theme.id
        let w = Double(canvas.w), h = Double(canvas.h)
        guard let a = BuiltinAssets.asset(id) else { return Layer(name: "Image", kind: .image(ImageSpec(builtin: id, theme: th)), transform: Transform(x: 0, y: 0, w: w * 0.3, h: h * 0.3)) }
        var sz = a.size
        // authored at 1920x1080 design size for full-frame art; otherwise cap to 60 % of the canvas
        if sz.width > w * 0.6 || sz.height > h * 0.6, !(sz.width >= w * 0.9 && sz.height >= h * 0.9) {
            let k = min(w * 0.6 / sz.width, h * 0.6 / sz.height); sz = CGSize(width: sz.width * k, height: sz.height * k)
        }
        if sz.width >= w * 0.9 && sz.height >= h * 0.9 { sz = CGSize(width: w, height: h) }
        return Layer(name: a.name, kind: .image(ImageSpec(builtin: id, theme: th)), transform: Transform(x: (w - sz.width) / 2, y: (h - sz.height) / 2, w: sz.width, h: sz.height))
    }
    static func image(prop id: String, name: String, aspect: Double, canvas: CanvasSize) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        let bw = min(w * 0.5, h * 0.5 * aspect), bh = bw / max(0.1, aspect)
        let kind: LayerKind = isVideoProp(id) ? .source(.prop(id: id), fit: .fit) : .image(ImageSpec(propId: id))
        return Layer(name: name, kind: kind, transform: Transform(x: (w - bw) / 2, y: (h - bh) / 2, w: bw, h: bh))
    }
    /// Videos are added as video sources (they play and are heard); pictures as image layers.
    static var isVideoProp: (String) -> Bool = { _ in false }
    static func source(_ ref: SourceRef, name: String, canvas: CanvasSize, portrait: Bool = false) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        var rect = CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.8)
        if portrait { let bh = h * 0.9, bw = bh * 9 / 16; rect = CGRect(x: (w - bw) / 2, y: (h - bh) / 2, width: bw, height: bh) }
        var l = Layer(name: name, kind: .source(ref, fit: .fill), transform: Transform(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height))
        l.border = Border(width: 4, color: RGBA(hex: 0xFF7A1A))
        return l
    }
    /// Team Status board: right side of the canvas at full height, the reference art's aspect (836 x 1881).
    static func teamBoard(canvas: CanvasSize, spec: TeamBoardSpec = TeamBoardSpec()) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        let bw = (h * TeamBoardLayout.refW / TeamBoardLayout.refH).rounded()
        return Layer(name: "Team Status Board", kind: .teamBoard(spec), transform: Transform(x: w - bw - (w * 0.012).rounded(), y: 0, w: bw, h: h))
    }
    static func effect(_ p: EffectPreset, canvas: CanvasSize) -> Layer {
        let w = Double(canvas.w), h = Double(canvas.h)
        let f = p.frame ?? CGRect(x: 0, y: 0, width: w, height: h)
        return Layer(name: p.name, kind: .effect(p.spec), transform: Transform(x: f.minX, y: f.minY, w: f.width, h: f.height), blend: p.blend)
    }

    // MARK: presets
    static let effectPresets: [EffectPreset] = {
        let ember = RGBA(hex: 0xFF7A1A), hot = RGBA(hex: 0xE5261B)
        return [
            EffectPreset(id: "fire-bottom", name: "Fire (bottom edge)", symbol: "flame.fill", spec: EffectSpec(.fireEmitter, color: ember, color2: hot, intensity: 1.2, count: 260, seed: 7), blend: .add, frame: CGRect(x: 0, y: 700, width: 1920, height: 380)),
            EffectPreset(id: "fire-blue", name: "Blue flame", symbol: "flame", spec: EffectSpec(.fireEmitter, color: RGBA(hex: 0x6FD2FF), color2: RGBA(hex: 0x1E55FF), intensity: 1.0, count: 220, seed: 11), blend: .add, frame: CGRect(x: 0, y: 760, width: 1920, height: 320)),
            EffectPreset(id: "embers", name: "Rising embers", symbol: "sparkles", spec: EffectSpec(.embers, color: RGBA(hex: 0xFFC247), color2: ember, intensity: 1, count: 140, seed: 3), blend: .add),
            EffectPreset(id: "sparks", name: "Sparks", symbol: "bolt.fill", spec: EffectSpec(.sparks, color: RGBA(hex: 0xFFE08A), color2: ember, intensity: 1, count: 90, seed: 5), blend: .add),
            EffectPreset(id: "smoke", name: "Smoke", symbol: "cloud.fill", spec: EffectSpec(.smoke, intensity: 1, count: 40, seed: 2), frame: CGRect(x: 0, y: 540, width: 1920, height: 540)),
            EffectPreset(id: "lightning", name: "Lightning", symbol: "bolt.horizontal.fill", spec: EffectSpec(.lightning, color: RGBA(hex: 0xBFF0FF), speed: 0.6, seed: 9), blend: .add),
            EffectPreset(id: "scanlines", name: "Scanlines", symbol: "line.3.horizontal", spec: EffectSpec(.scanlines, intensity: 1, size: 4)),
            EffectPreset(id: "glitch", name: "Glitch bands", symbol: "waveform.path.ecg", spec: EffectSpec(.glitch, intensity: 1, seed: 4), blend: .add),
            EffectPreset(id: "vignette", name: "Vignette", symbol: "circle.dashed", spec: EffectSpec(.vignette, intensity: 0.9, size: 40)),
            EffectPreset(id: "grain", name: "Film grain", symbol: "circle.grid.3x3.fill", spec: EffectSpec(.filmGrain, intensity: 1)),
            EffectPreset(id: "sweep", name: "Light sweep", symbol: "rays", spec: EffectSpec(.lightSweep, intensity: 1, speed: 1), blend: .add),
            EffectPreset(id: "pulse", name: "Pulsing glow", symbol: "circle.hexagongrid.fill", spec: EffectSpec(.pulsingGlow, color: ember, color2: hot, intensity: 1), blend: .add),
            EffectPreset(id: "brackets", name: "HUD corner brackets", symbol: "viewfinder", spec: EffectSpec(.hudCornerBrackets, color: ember, size: 90, thickness: 4)),
            EffectPreset(id: "radar", name: "Radar sweep", symbol: "dot.radiowaves.left.and.right", spec: EffectSpec(.radarSweep, color: RGBA(hex: 0x7CFF2B), thickness: 2), blend: .add, frame: CGRect(x: 40, y: 40, width: 300, height: 300)),
            EffectPreset(id: "gradient", name: "Animated gradient", symbol: "slider.horizontal.below.rectangle", spec: EffectSpec(.animatedGradient, color: RGBA(hex: 0x1A0A05), color2: RGBA(hex: 0x4A1208), speed: 0.5, angle: 45)),
            EffectPreset(id: "ticker", name: "Ticker", symbol: "text.line.first.and.arrowtriangle.forward", spec: EffectSpec(.ticker, text: "{{matchTitle}}  ·  {{team1}} vs {{team2}}", fontSize: 36), frame: CGRect(x: 0, y: 1000, width: 1920, height: 60)),
            EffectPreset(id: "countdown", name: "Countdown / timer", symbol: "timer", spec: EffectSpec(.countdown, text: "{{timer}}", fontSize: 96), frame: CGRect(x: 760, y: 40, width: 400, height: 120)),
            EffectPreset(id: "killfeed", name: "Kill-feed line", symbol: "text.alignleft", spec: EffectSpec(.killfeedLine, color: ember, text: "{{team1}}  eliminated  {{team2}}", fontSize: 30), frame: CGRect(x: 1400, y: 60, width: 480, height: 56)),
        ]
    }()

    /// Fire-themed look-and-feel in one click (applied to the selected layer).
    struct StylePreset: Identifiable { var id: String; var name: String; var apply: (inout Layer) -> Void }
    static let stylePresets: [StylePreset] = [
        StylePreset(id: "hot-glow", name: "Hot glow") { $0.glow = Glow(color: RGBA(hex: 0xFF7A1A), radius: 24, intensity: 1) },
        StylePreset(id: "neon", name: "Neon edge") { $0.border = Border(width: 3, color: RGBA(hex: 0x35B6FF)); $0.glow = Glow(color: RGBA(hex: 0x35B6FF), radius: 18, intensity: 1) },
        StylePreset(id: "steel", name: "Steel frame") { $0.border = Border(width: 6, gradient: .linear(RGBA(hex: 0xC8CED6), RGBA(hex: 0x4A5058), angle: 90)); $0.shadow = Shadow(color: RGBA(0, 0, 0, 0.6), blur: 18, dx: 0, dy: 8) },
        StylePreset(id: "gold", name: "Gold trim") { $0.border = Border(width: 5, gradient: .linear(RGBA(hex: 0xFFF1A6), RGBA(hex: 0xD9820A), angle: 45)); $0.shadow = Shadow(color: RGBA(0, 0, 0, 0.5), blur: 14, dx: 0, dy: 6) },
        StylePreset(id: "drop", name: "Drop shadow") { $0.shadow = Shadow(color: RGBA(0, 0, 0, 0.6), blur: 24, dx: 0, dy: 10) },
        StylePreset(id: "clear", name: "Clear styling") { $0.border = Border(); $0.shadow = Shadow(); $0.glow = Glow() },
    ]
}
