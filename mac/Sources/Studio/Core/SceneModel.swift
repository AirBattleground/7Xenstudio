// Layer-based scene model (Photoshop / After Effects / OBS style). All types are Codable with LENIENT decoding:
// missing or unknown keys fall back to defaults, so stored scenes from older versions keep loading.
//
// Coordinates: canvas pixels, origin top-left, y down, default canvas 1920x1080. Layer order: layers[0] is the BOTTOM
// (drawn first), the last element is on top (Photoshop-style: later = higher z).
// Transform: (x, y, w, h) is the UNROTATED box in the parent's space (canvas, or group-local space for children of a group).
// `anchor` is a normalised point (0...1) inside the box; rotation / scale animation pivot around it.
// Group children are positioned in group-local space: (0,0) is the group box's top-left; the group is rendered into an
// offscreen w x h surface and composited with the group's own transform / opacity / blend / effects.
import Foundation
import CoreGraphics

// MARK: - lenient decoding helpers

extension KeyedDecodingContainer {
    /// Decode with default on missing key OR type mismatch.
    func lenient<T: Decodable>(_ k: Key, _ d: T) -> T { ((try? decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d }
    func lenientOpt<T: Decodable>(_ k: Key) -> T? { ((try? decodeIfPresent(T.self, forKey: k)) ?? nil) }
}

// MARK: - colour, gradient, fill

struct RGBA: Codable, Hashable {
    var r = 0.0, g = 0.0, b = 0.0, a = 1.0
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// 0xRRGGBB (alpha separate).
    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255, alpha)
    }
    /// "#RRGGBB", "RRGGBB" or "#RRGGBBAA".
    init?(hexString s: String) {
        var t = s.trimmingCharacters(in: .whitespaces); if t.hasPrefix("#") { t.removeFirst() }
        guard let v = UInt64(t, radix: 16) else { return nil }
        if t.count == 6 { self.init(hex: UInt32(v)) }
        else if t.count == 8 { self.init(hex: UInt32(v >> 8), alpha: Double(v & 255) / 255) }
        else { return nil }
    }
    func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0), clear = RGBA(0, 0, 0, 0)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        r = c.lenient(.r, 0); g = c.lenient(.g, 0); b = c.lenient(.b, 0); a = c.lenient(.a, 1)
    }
    private enum K: String, CodingKey { case r, g, b, a }
}

struct GradientStop: Codable, Hashable {
    var pos = 0.0; var color = RGBA.white
    init(_ pos: Double, _ color: RGBA) { self.pos = pos; self.color = color }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); pos = c.lenient(.pos, 0); color = c.lenient(.color, .white)
    }
    private enum K: String, CodingKey { case pos, color }
}
/// Linear (angle in degrees, 0 = left->right, 90 = top->bottom) or radial (centre cx,cy normalised, radius normalised to box half-diagonal).
struct Gradient: Codable, Hashable {
    var stops: [GradientStop] = [GradientStop(0, .black), GradientStop(1, .white)]
    var angle = 90.0
    var radial = false
    var cx = 0.5, cy = 0.5, radius = 0.75
    init(stops: [GradientStop], angle: Double = 90, radial: Bool = false, cx: Double = 0.5, cy: Double = 0.5, radius: Double = 0.75) {
        self.stops = stops; self.angle = angle; self.radial = radial; self.cx = cx; self.cy = cy; self.radius = radius
    }
    static func linear(_ a: RGBA, _ b: RGBA, angle: Double = 90) -> Gradient { Gradient(stops: [GradientStop(0, a), GradientStop(1, b)], angle: angle) }
    static func radial(_ a: RGBA, _ b: RGBA, radius: Double = 0.75) -> Gradient { Gradient(stops: [GradientStop(0, a), GradientStop(1, b)], radial: true, radius: radius) }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        stops = c.lenient(.stops, stops); if stops.isEmpty { stops = [GradientStop(0, .black), GradientStop(1, .white)] }
        angle = c.lenient(.angle, 90); radial = c.lenient(.radial, false)
        cx = c.lenient(.cx, 0.5); cy = c.lenient(.cy, 0.5); radius = c.lenient(.radius, 0.75)
    }
    private enum K: String, CodingKey { case stops, angle, radial, cx, cy, radius }
}
/// Solid colour or gradient.
struct Fill: Codable, Hashable {
    var color = RGBA.white
    var gradient: Gradient? = nil
    init(_ color: RGBA) { self.color = color }
    init(gradient: Gradient) { self.gradient = gradient; self.color = gradient.stops.first?.color ?? .white }
    static func solid(_ c: RGBA) -> Fill { Fill(c) }
    static func gradient(_ g: Gradient) -> Fill { Fill(gradient: g) }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); color = c.lenient(.color, .white); gradient = c.lenientOpt(.gradient)
    }
    private enum K: String, CodingKey { case color, gradient }
}

// MARK: - background

enum BackgroundKind: String, Codable, CaseIterable { case solid, linearGradient, radialGradient, image, video, source }
struct Background: Codable, Hashable {
    var kind = BackgroundKind.solid
    var color = RGBA(hex: 0x06090C)
    var gradient: Gradient? = nil
    var propId: String? = nil           // image / video prop
    var source: SourceRef? = nil        // live source as background
    var fit = SourceFit.fill
    var dim = 0.0                       // 0...1 darken for image/video/source backgrounds
    var blur = 0.0                      // 0...1 gaussian-ish blur amount for image/video/source backgrounds
    init() {}
    static func solid(_ c: RGBA) -> Background { var b = Background(); b.color = c; return b }
    static func linear(_ g: Gradient) -> Background { var b = Background(); b.kind = .linearGradient; b.gradient = g; return b }
    static func radial(_ g: Gradient) -> Background { var b = Background(); b.kind = .radialGradient; b.gradient = g; return b }
    static func image(_ propId: String, dim: Double = 0) -> Background { var b = Background(); b.kind = .image; b.propId = propId; b.dim = dim; return b }
    static func video(_ propId: String, dim: Double = 0) -> Background { var b = Background(); b.kind = .video; b.propId = propId; b.dim = dim; return b }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .solid); color = c.lenient(.color, RGBA(hex: 0x06090C)); gradient = c.lenientOpt(.gradient)
        propId = c.lenientOpt(.propId); source = c.lenientOpt(.source); fit = c.lenient(.fit, .fill)
        dim = c.lenient(.dim, 0); blur = c.lenient(.blur, 0)
    }
    private enum K: String, CodingKey { case kind, color, gradient, propId, source, fit, dim, blur }
}

enum SourceFit: String, Codable, CaseIterable { case fill, fit, stretch }

// MARK: - transform & per-layer styling

struct Transform: Codable, Hashable {
    var x = 0.0, y = 0.0, w = 1920.0, h = 1080.0
    var rotation = 0.0                    // degrees, clockwise
    var anchorX = 0.5, anchorY = 0.5      // normalised pivot inside the box
    var flipX = false, flipY = false
    init(x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080, rotation: Double = 0,
         anchorX: Double = 0.5, anchorY: Double = 0.5, flipX: Bool = false, flipY: Bool = false) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.rotation = rotation
        self.anchorX = anchorX; self.anchorY = anchorY; self.flipX = flipX; self.flipY = flipY
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        x = c.lenient(.x, 0); y = c.lenient(.y, 0); w = c.lenient(.w, 1920); h = c.lenient(.h, 1080); rotation = c.lenient(.rotation, 0)
        anchorX = c.lenient(.anchorX, 0.5); anchorY = c.lenient(.anchorY, 0.5); flipX = c.lenient(.flipX, false); flipY = c.lenient(.flipY, false)
    }
    private enum K: String, CodingKey { case x, y, w, h, rotation, anchorX, anchorY, flipX, flipY }
}
enum BlendMode: String, Codable, CaseIterable { case normal, add, screen, multiply, overlay }
/// Fractions (0...1) of the layer's content trimmed from each side.
struct Crop: Codable, Hashable {
    var l = 0.0, t = 0.0, r = 0.0, b = 0.0
    init(l: Double = 0, t: Double = 0, r: Double = 0, b: Double = 0) { self.l = l; self.t = t; self.r = r; self.b = b }
    var isZero: Bool { l == 0 && t == 0 && r == 0 && b == 0 }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); l = c.lenient(.l, 0); t = c.lenient(.t, 0); r = c.lenient(.r, 0); b = c.lenient(.b, 0)
    }
    private enum K: String, CodingKey { case l, t, r, b }
}
enum MaskKind: String, Codable, CaseIterable { case none, roundedRect, circle, hexagon, parallelogram, image }
struct Mask: Codable, Hashable {
    var kind = MaskKind.none
    var propId: String? = nil          // .image mask: luminance*alpha of this prop image
    var skew = 0.2                     // parallelogram: horizontal shear as a fraction of height
    var feather = 0.0                  // px of edge softness
    var invert = false
    init(_ kind: MaskKind = .none, propId: String? = nil, skew: Double = 0.2, feather: Double = 0, invert: Bool = false) {
        self.kind = kind; self.propId = propId; self.skew = skew; self.feather = feather; self.invert = invert
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .none); propId = c.lenientOpt(.propId); skew = c.lenient(.skew, 0.2); feather = c.lenient(.feather, 0); invert = c.lenient(.invert, false)
    }
    private enum K: String, CodingKey { case kind, propId, skew, feather, invert }
}
struct Border: Codable, Hashable {
    var width = 0.0                    // px, drawn inside the mask edge
    var color = RGBA.white
    var gradient: Gradient? = nil
    init(width: Double = 0, color: RGBA = .white, gradient: Gradient? = nil) { self.width = width; self.color = color; self.gradient = gradient }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); width = c.lenient(.width, 0); color = c.lenient(.color, .white); gradient = c.lenientOpt(.gradient)
    }
    private enum K: String, CodingKey { case width, color, gradient }
}
struct Shadow: Codable, Hashable {
    var color = RGBA(0, 0, 0, 0.6)
    var blur = 0.0, dx = 0.0, dy = 0.0   // blur = 0 disables
    init(color: RGBA = RGBA(0, 0, 0, 0.6), blur: Double = 0, dx: Double = 0, dy: Double = 0) { self.color = color; self.blur = blur; self.dx = dx; self.dy = dy }
    var isOn: Bool { blur > 0 && color.a > 0 }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        color = c.lenient(.color, RGBA(0, 0, 0, 0.6)); blur = c.lenient(.blur, 0); dx = c.lenient(.dx, 0); dy = c.lenient(.dy, 0)
    }
    private enum K: String, CodingKey { case color, blur, dx, dy }
}
/// Outer glow around the layer's alpha silhouette (additive).
struct Glow: Codable, Hashable {
    var color = RGBA(1, 0.5, 0.1)
    var radius = 0.0                    // px; 0 disables
    var intensity = 1.0
    init(color: RGBA = RGBA(1, 0.5, 0.1), radius: Double = 0, intensity: Double = 1) { self.color = color; self.radius = radius; self.intensity = intensity }
    var isOn: Bool { radius > 0 && intensity > 0 }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); color = c.lenient(.color, RGBA(1, 0.5, 0.1)); radius = c.lenient(.radius, 0); intensity = c.lenient(.intensity, 1)
    }
    private enum K: String, CodingKey { case color, radius, intensity }
}
struct ColorAdjust: Codable, Hashable {
    var brightness = 0.0      // -1...1
    var contrast = 0.0        // -1...1
    var saturation = 0.0      // -1...1  (-1 = greyscale)
    var hue = 0.0             // degrees
    var tint: RGBA? = nil     // multiplicative tint (alpha = strength)
    init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0, hue: Double = 0, tint: RGBA? = nil) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.hue = hue; self.tint = tint
    }
    var isIdentity: Bool { brightness == 0 && contrast == 0 && saturation == 0 && hue == 0 && (tint?.a ?? 0) == 0 }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        brightness = c.lenient(.brightness, 0); contrast = c.lenient(.contrast, 0); saturation = c.lenient(.saturation, 0); hue = c.lenient(.hue, 0); tint = c.lenientOpt(.tint)
    }
    private enum K: String, CodingKey { case brightness, contrast, saturation, hue, tint }
}
struct ChromaKey: Codable, Hashable {
    var color = RGBA(0, 1, 0)
    var similarity = 0.35, smoothness = 0.08, spill = 0.3
    init(color: RGBA = RGBA(0, 1, 0), similarity: Double = 0.35, smoothness: Double = 0.08, spill: Double = 0.3) {
        self.color = color; self.similarity = similarity; self.smoothness = smoothness; self.spill = spill
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        color = c.lenient(.color, RGBA(0, 1, 0)); similarity = c.lenient(.similarity, 0.35); smoothness = c.lenient(.smoothness, 0.08); spill = c.lenient(.spill, 0.3)
    }
    private enum K: String, CodingKey { case color, similarity, smoothness, spill }
}

/// Per-layer post effects applied to the layer's pixels.
enum LayerEffectKind: String, Codable, CaseIterable { case blur, chromaticAberration, glitch, scanlines, pixelate, flicker, shake }
struct Effect: Codable, Hashable {
    var kind = LayerEffectKind.blur
    var amount = 0.5          // 0...1 strength
    var speed = 1.0
    var enabled = true
    init(_ kind: LayerEffectKind, amount: Double = 0.5, speed: Double = 1, enabled: Bool = true) { self.kind = kind; self.amount = amount; self.speed = speed; self.enabled = enabled }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .blur); amount = c.lenient(.amount, 0.5); speed = c.lenient(.speed, 1); enabled = c.lenient(.enabled, true)
    }
    private enum K: String, CodingKey { case kind, amount, speed, enabled }
}

// MARK: - animation

enum AnimTrigger: String, Codable, CaseIterable { case onShow, onHide, loop, onTake }
enum AnimKind: String, Codable, CaseIterable { case fade, slide, scale, wipe, glitch, pulse, float, rotate, typewriter, shake, drift }
enum Easing: String, Codable, CaseIterable { case linear, easeIn, easeOut, easeInOut, backOut, bounce, elastic }
/// Loops with pingPong=false restart (sawtooth) -- e.g. rotate 0->360 as a spinner.
/// Tween semantics (value goes `from` -> `to` over `duration` after `delay`):
///  fade: opacity multiplier | slide: offset in px along `direction` (deg; 0 = right, 90 = down), e.g. from 200 to 0 slides in
///  scale: scale factor | rotate: extra degrees | wipe: revealed fraction 0...1 (reveal direction = `direction`)
///  glitch: intensity 0...1 (jitter + RGB split) | pulse: scale/opacity throb, `to` = amplitude (0.1 = +-10 %), loops
///  float: bob amplitude px (vertical, `direction` rotates it), loops | typewriter: revealed character fraction 0...1
///  shake: camera-shake amplitude px (e.g. 30 -> 0 over 0.7 s on show: a decaying jolt; deterministic noise of the local time)
///  drift: slow parallax drift, loops: `to` = travel px along `direction` (+ a smaller perpendicular sway), `from` = scale breathing (0.02 = +2 %),
///    `duration` = period. Give background layers different amplitudes for a camera-like parallax.
/// Triggers: onShow = scene (or layer) becomes visible; onHide = while leaving; loop = continuous (duration = period);
/// onTake = replays each time the scene is taken to program.
struct Animation: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var trigger = AnimTrigger.onShow
    var kind = AnimKind.fade
    var duration = 0.5          // seconds (loop: period)
    var delay = 0.0
    var easing = Easing.easeOut
    var from = 0.0, to = 1.0
    var direction = 0.0         // degrees, for slide / wipe / float
    var pingPong = true         // loop triggers: ease back and forth rather than restart
    init(trigger: AnimTrigger = .onShow, kind: AnimKind = .fade, duration: Double = 0.5, delay: Double = 0, easing: Easing = .easeOut,
         from: Double = 0, to: Double = 1, direction: Double = 0, pingPong: Bool = true) {
        self.trigger = trigger; self.kind = kind; self.duration = duration; self.delay = delay; self.easing = easing
        self.from = from; self.to = to; self.direction = direction; self.pingPong = pingPong
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.lenient(.id, UUID().uuidString); trigger = c.lenient(.trigger, .onShow); kind = c.lenient(.kind, .fade)
        duration = c.lenient(.duration, 0.5); delay = c.lenient(.delay, 0); easing = c.lenient(.easing, .easeOut)
        from = c.lenient(.from, 0); to = c.lenient(.to, 1); direction = c.lenient(.direction, 0); pingPong = c.lenient(.pingPong, true)
    }
    private enum K: String, CodingKey { case id, trigger, kind, duration, delay, easing, from, to, direction, pingPong }
    // Convenience builders
    static func fadeIn(_ dur: Double = 0.5, delay: Double = 0) -> Animation { Animation(trigger: .onShow, kind: .fade, duration: dur, delay: delay, from: 0, to: 1) }
    static func fadeOut(_ dur: Double = 0.4) -> Animation { Animation(trigger: .onHide, kind: .fade, duration: dur, easing: .easeIn, from: 1, to: 0) }
    static func slideIn(from px: Double = 300, direction: Double = 180, dur: Double = 0.6, delay: Double = 0) -> Animation {
        Animation(trigger: .onShow, kind: .slide, duration: dur, delay: delay, easing: .backOut, from: px, to: 0, direction: direction)
    }
    static func pulse(period: Double = 1.2, amount: Double = 0.06) -> Animation { Animation(trigger: .loop, kind: .pulse, duration: period, easing: .easeInOut, from: 0, to: amount) }
    static func float(period: Double = 3, amplitude: Double = 8) -> Animation { Animation(trigger: .loop, kind: .float, duration: period, easing: .easeInOut, from: -amplitude, to: amplitude, direction: 90) }
    static func spin(period: Double = 8, degrees: Double = 360) -> Animation { Animation(trigger: .loop, kind: .rotate, duration: period, easing: .linear, from: 0, to: degrees, pingPong: false) }
}

// MARK: - layer kinds

enum ShapeKind: String, Codable, CaseIterable { case rect, roundedRect, ellipse, polygon, line }
struct Stroke: Codable, Hashable {
    var width = 0.0
    var color = RGBA.white
    var gradient: Gradient? = nil
    init(width: Double = 0, color: RGBA = .white, gradient: Gradient? = nil) { self.width = width; self.color = color; self.gradient = gradient }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); width = c.lenient(.width, 0); color = c.lenient(.color, .white); gradient = c.lenientOpt(.gradient)
    }
    private enum K: String, CodingKey { case width, color, gradient }
}
struct ShapeSpec: Codable, Hashable {
    var kind = ShapeKind.rect
    var fill = Fill(.white)
    var stroke = Stroke()
    var cornerRadius = 0.0       // roundedRect
    var sides = 6                // polygon (>= 3)
    var starInset = 0.0          // polygon: 0 = regular polygon, 0.5 = star
    var lineWidth = 4.0          // line: thickness, drawn along the box's top-left -> bottom-right diagonal (or horizontal if h == 0)
    init(_ kind: ShapeKind = .rect, fill: Fill = Fill(.white), stroke: Stroke = Stroke(), cornerRadius: Double = 0, sides: Int = 6, starInset: Double = 0, lineWidth: Double = 4) {
        self.kind = kind; self.fill = fill; self.stroke = stroke; self.cornerRadius = cornerRadius; self.sides = sides; self.starInset = starInset; self.lineWidth = lineWidth
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .rect); fill = c.lenient(.fill, Fill(.white)); stroke = c.lenient(.stroke, Stroke()); cornerRadius = c.lenient(.cornerRadius, 0)
        sides = max(3, c.lenient(.sides, 6)); starInset = c.lenient(.starInset, 0); lineWidth = c.lenient(.lineWidth, 4)
    }
    private enum K: String, CodingKey { case kind, fill, stroke, cornerRadius, sides, starInset, lineWidth }
}
enum TextAlign: String, Codable, CaseIterable { case left, center, right }
/// `string` may contain {{variable}} bindings: team1, team2, score1, score2, matchTitle, timer, viewers (and any operator key).
struct TextStyle: Codable, Hashable {
    var string = "Text"
    var font = "Helvetica Neue"          // family or PostScript name; falls back to the system font
    var size = 64.0                      // px at 1080p
    var weight = 700.0                   // 100...900
    var italic = false
    var tracking = 0.0                   // px of extra letter spacing
    var lineSpacing = 0.0
    var color = RGBA.white
    var gradient: Gradient? = nil        // overrides colour when set
    var stroke = Stroke()
    var shadow = Shadow()
    var alignment = TextAlign.center
    var allCaps = false
    /// additive: at most this many lines; the text shrinks until it fits (nil = as many as the box height allows)
    var maxLines: Int? = nil
    init(_ string: String = "Text", font: String = "Helvetica Neue", size: Double = 64, weight: Double = 700, italic: Bool = false, tracking: Double = 0,
         lineSpacing: Double = 0, color: RGBA = .white, gradient: Gradient? = nil, stroke: Stroke = Stroke(), shadow: Shadow = Shadow(),
         alignment: TextAlign = .center, allCaps: Bool = false) {
        self.string = string; self.font = font; self.size = size; self.weight = weight; self.italic = italic; self.tracking = tracking
        self.lineSpacing = lineSpacing; self.color = color; self.gradient = gradient; self.stroke = stroke; self.shadow = shadow
        self.alignment = alignment; self.allCaps = allCaps
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        string = c.lenient(.string, "Text"); font = c.lenient(.font, "Helvetica Neue"); size = c.lenient(.size, 64); weight = c.lenient(.weight, 700)
        italic = c.lenient(.italic, false); tracking = c.lenient(.tracking, 0); lineSpacing = c.lenient(.lineSpacing, 0)
        color = c.lenient(.color, .white); gradient = c.lenientOpt(.gradient); stroke = c.lenient(.stroke, Stroke()); shadow = c.lenient(.shadow, Shadow())
        alignment = c.lenient(.alignment, .center); allCaps = c.lenient(.allCaps, false); maxLines = c.lenientOpt(.maxLines)
    }
    private enum K: String, CodingKey { case string, font, size, weight, italic, tracking, lineSpacing, color, gradient, stroke, shadow, alignment, allCaps, maxLines }
}
struct ImageSpec: Codable, Hashable {
    var propId: String? = nil           // a prop in the library (image; gif/video props play)
    var builtin: String? = nil          // id of a built-in asset (BuiltinAssets / PropsCatalog id)
    var theme: String? = nil            // PropTheme id for themed built-in assets (nil = ember)
    var fit: SourceFit? = nil           // nil / .fit = whole image inside the box; .fill = cover (cropped); .stretch
    init(propId: String? = nil, builtin: String? = nil, theme: String? = nil, fit: SourceFit? = nil) { self.propId = propId; self.builtin = builtin; self.theme = theme; self.fit = fit }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); propId = c.lenientOpt(.propId); builtin = c.lenientOpt(.builtin); theme = c.lenientOpt(.theme); fit = c.lenientOpt(.fit)
    }
    private enum K: String, CodingKey { case propId, builtin, theme, fit }
}

/// Procedural effect layers (GPU-rendered, never rasterised on the CPU).
enum EffectKind: String, Codable, CaseIterable {
    case fireEmitter, embers, smoke, sparks, lightning, scanlines, glitch, vignette, filmGrain, lightSweep, pulsingGlow,
         hudCornerBrackets, radarSweep, animatedGradient, ticker, countdown, killfeedLine
}
/// Parameters shared by all effects (each effect reads the ones it needs).
///  fireEmitter/embers/smoke/sparks: the layer box is the emitter area (particles spawn along its bottom edge for fire/smoke/embers; centre for sparks),
///    `count` particles, `intensity` size/brightness, `speed`, `seed` makes the simulation deterministic; color/color2 = core/outer tint.
///  lightning: bolt from top to bottom of the box, `speed` = strikes per second | scanlines: line spacing = `size` px
///  glitch: tearing bands | vignette: `intensity` darkness, `size` falloff (0..1) | filmGrain: `intensity`
///  lightSweep: diagonal shine, `speed` sweeps/sec | pulsingGlow: radial glow breathing | hudCornerBrackets: `size` bracket length px, `thickness`
///  radarSweep: rotating sweep wedge with rings | animatedGradient: color->color2 gradient drifting at `speed`, `angle`
///  ticker: scrolling `text` (bindings allowed) | countdown: `text` is a format, e.g. "{{timer}}" or fixed "00:30"; `fontSize` | killfeedLine: `text` line with accent bar
struct EffectSpec: Codable, Hashable {
    var kind = EffectKind.fireEmitter
    var color = RGBA(1, 0.55, 0.1)
    var color2 = RGBA(1, 0.1, 0.0)
    var intensity = 1.0
    var speed = 1.0
    var count = 600
    var seed: UInt32 = 1
    var size = 24.0
    var thickness = 3.0
    var angle = 0.0
    var text = ""
    var fontSize = 48.0
    /// Advanced (OPUS) effect drawn instead of `kind` when set (see AdvancedFX). `kind` stays a sensible fallback for older readers.
    var advanced: AdvancedFX? = nil
    /// One-shot effects (shockwave, burst, converge, light wipe, ...): seconds after the scene's show / take before it fires;
    /// `period` > 0 re-fires it every `period` seconds.
    var delay = 0.0
    var period = 0.0
    init(_ kind: EffectKind, color: RGBA = RGBA(1, 0.55, 0.1), color2: RGBA = RGBA(1, 0.1, 0), intensity: Double = 1, speed: Double = 1,
         count: Int = 600, seed: UInt32 = 1, size: Double = 24, thickness: Double = 3, angle: Double = 0, text: String = "", fontSize: Double = 48) {
        self.kind = kind; self.color = color; self.color2 = color2; self.intensity = intensity; self.speed = speed; self.count = count
        self.seed = seed; self.size = size; self.thickness = thickness; self.angle = angle; self.text = text; self.fontSize = fontSize
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .fireEmitter); color = c.lenient(.color, RGBA(1, 0.55, 0.1)); color2 = c.lenient(.color2, RGBA(1, 0.1, 0))
        intensity = c.lenient(.intensity, 1); speed = c.lenient(.speed, 1); count = c.lenient(.count, 600); seed = c.lenient(.seed, 1)
        size = c.lenient(.size, 24); thickness = c.lenient(.thickness, 3); angle = c.lenient(.angle, 0); text = c.lenient(.text, ""); fontSize = c.lenient(.fontSize, 48)
        advanced = c.lenientOpt(.advanced); delay = c.lenient(.delay, 0); period = c.lenient(.period, 0)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind); try c.encode(color, forKey: .color); try c.encode(color2, forKey: .color2); try c.encode(intensity, forKey: .intensity)
        try c.encode(speed, forKey: .speed); try c.encode(count, forKey: .count); try c.encode(seed, forKey: .seed); try c.encode(size, forKey: .size)
        try c.encode(thickness, forKey: .thickness); try c.encode(angle, forKey: .angle); try c.encode(text, forKey: .text); try c.encode(fontSize, forKey: .fontSize)
        try c.encodeIfPresent(advanced, forKey: .advanced)
        if delay != 0 { try c.encode(delay, forKey: .delay) }
        if period != 0 { try c.encode(period, forKey: .period) }
    }
    private enum K: String, CodingKey { case kind, color, color2, intensity, speed, count, seed, size, thickness, angle, text, fontSize, advanced, delay, period }
}

enum LayerKind: Hashable {
    case source(SourceRef, fit: SourceFit)
    case image(ImageSpec)
    case shape(ShapeSpec)
    case text(TextStyle)
    case group([Layer])
    case effect(EffectSpec)
    /// Dynamic Team Status board (TeamBoard.swift): data from a manual list, a polled JSON URL or mock data.
    case teamBoard(TeamBoardSpec)
}
extension LayerKind: Codable {
    private enum K: String, CodingKey { case type, source, fit, image, shape, text, children, effect, board }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let t: String = c.lenient(.type, "group")
        switch t {
        case "source": self = .source(c.lenient(.source, SourceRef.slate), fit: c.lenient(.fit, .fill))
        case "image": self = .image(c.lenient(.image, ImageSpec()))
        case "shape": self = .shape(c.lenient(.shape, ShapeSpec()))
        case "text": self = .text(c.lenient(.text, TextStyle()))
        case "effect": self = .effect(c.lenient(.effect, EffectSpec(.vignette)))
        case "teamBoard": self = .teamBoard(c.lenient(.board, TeamBoardSpec()))
        default: self = .group(c.lenient(.children, [Layer]()))
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case .source(let r, let f): try c.encode("source", forKey: .type); try c.encode(r, forKey: .source); try c.encode(f, forKey: .fit)
        case .image(let i): try c.encode("image", forKey: .type); try c.encode(i, forKey: .image)
        case .shape(let s): try c.encode("shape", forKey: .type); try c.encode(s, forKey: .shape)
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .group(let l): try c.encode("group", forKey: .type); try c.encode(l, forKey: .children)
        case .effect(let x): try c.encode("effect", forKey: .type); try c.encode(x, forKey: .effect)
        case .teamBoard(let b): try c.encode("teamBoard", forKey: .type); try c.encode(b, forKey: .board)
        }
    }
    var typeName: String {
        switch self { case .source: return "source"; case .image: return "image"; case .shape: return "shape"; case .text: return "text"; case .group: return "group"; case .effect: return "effect"; case .teamBoard: return "team board" }
    }
}

// MARK: - layer

struct Layer: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "Layer"
    var visible = true
    var locked = false
    var kind: LayerKind = .shape(ShapeSpec())
    var transform = Transform()
    var opacity = 1.0
    var blend = BlendMode.normal
    var crop = Crop()
    var cornerRadius = 0.0
    var mask = Mask()
    var border = Border()
    var shadow = Shadow()
    var glow = Glow()
    var colorAdjust = ColorAdjust()
    var chromaKey: ChromaKey? = nil
    var effects: [Effect] = []
    var animations: [Animation] = []
    /// Specular light sweep / metallic shimmer over the layer's own pixels (nil = none). See `Shine`.
    var shine: Shine? = nil

    init(id: String = UUID().uuidString, name: String = "Layer", kind: LayerKind, transform: Transform = Transform(), opacity: Double = 1,
         blend: BlendMode = .normal, visible: Bool = true, locked: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.transform = transform; self.opacity = opacity; self.blend = blend
        self.visible = visible; self.locked = locked
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.lenient(.id, UUID().uuidString); name = c.lenient(.name, "Layer"); visible = c.lenient(.visible, true); locked = c.lenient(.locked, false)
        kind = c.lenient(.kind, LayerKind.shape(ShapeSpec())); transform = c.lenient(.transform, Transform())
        opacity = c.lenient(.opacity, 1); blend = c.lenient(.blend, .normal); crop = c.lenient(.crop, Crop()); cornerRadius = c.lenient(.cornerRadius, 0)
        mask = c.lenient(.mask, Mask()); border = c.lenient(.border, Border()); shadow = c.lenient(.shadow, Shadow()); glow = c.lenient(.glow, Glow())
        colorAdjust = c.lenient(.colorAdjust, ColorAdjust()); chromaKey = c.lenientOpt(.chromaKey)
        effects = c.lenient(.effects, [Effect]()); animations = c.lenient(.animations, [Animation]())
        shine = c.lenientOpt(.shine)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(visible, forKey: .visible); try c.encode(locked, forKey: .locked)
        try c.encode(kind, forKey: .kind); try c.encode(transform, forKey: .transform); try c.encode(opacity, forKey: .opacity); try c.encode(blend, forKey: .blend)
        try c.encode(crop, forKey: .crop); try c.encode(cornerRadius, forKey: .cornerRadius); try c.encode(mask, forKey: .mask); try c.encode(border, forKey: .border)
        try c.encode(shadow, forKey: .shadow); try c.encode(glow, forKey: .glow); try c.encode(colorAdjust, forKey: .colorAdjust)
        try c.encodeIfPresent(chromaKey, forKey: .chromaKey); try c.encode(effects, forKey: .effects); try c.encode(animations, forKey: .animations)
        try c.encodeIfPresent(shine, forKey: .shine)
    }
    private enum K: String, CodingKey {
        case id, name, visible, locked, kind, transform, opacity, blend, crop, cornerRadius, mask, border, shadow, glow, colorAdjust, chromaKey, effects, animations, shine
    }
    var children: [Layer] { if case .group(let l) = kind { return l }; return [] }
}

// MARK: - transitions & scene

/// lightWipe: a gold light band sweeps across along `direction`, the new scene is revealed behind it (no video needed).
enum SceneTransitionKind: String, Codable, CaseIterable { case cut, fade, slide, zoom, wipe, stinger, lightWipe }
struct SceneTransition: Codable, Hashable {
    var kind = SceneTransitionKind.fade
    var duration = 0.3            // seconds
    var direction = 180.0         // degrees the *motion* heads (slide/wipe); 180 = new scene enters from the right
    var stingerPropId: String? = nil   // video prop played over the cut (cuts at `cutPoint` of its duration)
    var cutPoint = 0.5
    init(_ kind: SceneTransitionKind = .fade, duration: Double = 0.3, direction: Double = 180, stingerPropId: String? = nil, cutPoint: Double = 0.5) {
        self.kind = kind; self.duration = duration; self.direction = direction; self.stingerPropId = stingerPropId; self.cutPoint = cutPoint
    }
    static let cut = SceneTransition(.cut, duration: 0)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = c.lenient(.kind, .fade); duration = c.lenient(.duration, 0.3); direction = c.lenient(.direction, 180)
        stingerPropId = c.lenientOpt(.stingerPropId); cutPoint = c.lenient(.cutPoint, 0.5)
    }
    private enum K: String, CodingKey { case kind, duration, direction, stingerPropId, cutPoint }
}
struct CanvasSize: Codable, Hashable {
    var w = 1920, h = 1080
    init(w: Int = 1920, h: Int = 1080) { self.w = w; self.h = h }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); w = c.lenient(.w, 1920); h = c.lenient(.h, 1080)
    }
    private enum K: String, CodingKey { case w, h }
}

struct LayerScene: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var canvas = CanvasSize()
    var background = Background()
    /// Bottom -> top. The last layer is drawn last (on top).
    var layers: [Layer] = []
    var transitionIn: SceneTransition? = nil     // used when this scene goes to program; nil = engine default
    var transitionOut: SceneTransition? = nil
    /// Id of the old fixed-layout Scene this was migrated from (so the UI can keep selection / audio mapping in sync); nil for native scenes.
    var migratedFrom: String? = nil
    /// Default values for {{bindings}} used when the live variable set has no value.
    var variableDefaults: [String: String] = [:]

    init(id: String = UUID().uuidString, name: String = "Scene", background: Background = Background(), layers: [Layer] = [],
         transitionIn: SceneTransition? = nil, transitionOut: SceneTransition? = nil, canvas: CanvasSize = CanvasSize()) {
        self.id = id; self.name = name; self.background = background; self.layers = layers
        self.transitionIn = transitionIn; self.transitionOut = transitionOut; self.canvas = canvas
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.lenient(.id, UUID().uuidString); name = c.lenient(.name, "Scene"); canvas = c.lenient(.canvas, CanvasSize())
        background = c.lenient(.background, Background()); layers = c.lenient(.layers, [Layer]())
        transitionIn = c.lenientOpt(.transitionIn); transitionOut = c.lenientOpt(.transitionOut)
        migratedFrom = c.lenientOpt(.migratedFrom); variableDefaults = c.lenient(.variableDefaults, [String: String]())
    }
    private enum K: String, CodingKey { case id, name, canvas, background, layers, transitionIn, transitionOut, migratedFrom, variableDefaults }

    /// Every live source referenced by the scene (including the background and group children).
    var sourceRefs: Set<SourceRef> {
        var s = Set<SourceRef>()
        if let r = background.source, background.kind == .source { s.insert(r) }
        if background.kind == .video, let id = background.propId { s.insert(.prop(id: id)) }
        func walk(_ ls: [Layer]) {
            for l in ls where l.visible {
                switch l.kind {
                case .source(let r, _): s.insert(r)
                case .group(let c): walk(c)
                default: break
                }
            }
        }
        walk(layers)
        return s
    }
    /// Depth-first visit of all layers.
    func forEachLayer(_ f: (Layer) -> Void) {
        func walk(_ ls: [Layer]) { for l in ls { f(l); if case .group(let c) = l.kind { walk(c) } } }
        walk(layers)
    }
}

// MARK: - variables / bindings

/// Live values for {{bindings}} in text layers and text effects. Keys are case-sensitive.
struct SceneVariables: Equatable {
    var values: [String: String] = [:]
    init(_ v: [String: String] = [:]) { values = v }
    subscript(key: String) -> String? { get { values[key] } set { values[key] = newValue } }
    static let standardKeys = ["team1", "team2", "score1", "score2", "matchTitle", "timer", "viewers"]
    /// Sample values for editor previews and thumbnails.
    static let sample = SceneVariables(["team1": "ALPHA", "team2": "BRAVO", "score1": "12", "score2": "9", "matchTitle": "GRAND FINALS", "timer": "08:42", "viewers": "1.2K"])
    /// Replace every {{key}} (whitespace tolerant) with its value; unknown keys use `defaults`, then the empty string.
    func resolve(_ s: String, defaults: [String: String] = [:]) -> String {
        guard s.contains("{{") else { return s }
        var out = ""; var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("{{"), let close = s.range(of: "}}", range: s.index(i, offsetBy: 2)..<s.endIndex) {
                let key = s[s.index(i, offsetBy: 2)..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                out += values[key] ?? defaults[key] ?? ""
                i = close.upperBound
            } else { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }
}

// MARK: - animation evaluation (pure, testable)

/// Resolved animation state of a layer at an instant.
struct AnimState: Equatable {
    var opacity = 1.0
    var dx = 0.0, dy = 0.0
    var scale = 1.0
    var rotation = 0.0          // degrees added
    var wipe = 1.0              // revealed fraction
    var wipeAngle = 0.0
    var glitch = 0.0
    var typewriter = 1.0        // revealed character fraction
    static let identity = AnimState()
}
/// Timing of a layer: seconds since the scene became visible / since the last Take, and seconds since hide began (nil = not hiding).
struct AnimClock {
    var sinceShow = 0.0
    var sinceTake = 0.0
    var sinceHide: Double? = nil
    var time = 0.0            // absolute seconds, used by loops
    init(sinceShow: Double = 0, sinceTake: Double? = nil, sinceHide: Double? = nil, time: Double? = nil) {
        self.sinceShow = sinceShow; self.sinceTake = sinceTake ?? sinceShow; self.sinceHide = sinceHide; self.time = time ?? sinceShow
    }
}
enum Tween {
    static func ease(_ e: Easing, _ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch e {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: let u = 1 - x; return 1 - u * u * u
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .backOut: let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        case .bounce:
            let n1 = 7.5625, d1 = 2.75
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { let y = x - 1.5 / d1; return n1 * y * y + 0.75 }
            if x < 2.5 / d1 { let y = x - 2.25 / d1; return n1 * y * y + 0.9375 }
            let y = x - 2.625 / d1; return n1 * y * y + 0.984375
        case .elastic:
            if x == 0 || x == 1 { return x }
            return pow(2, -10 * x) * sin((x * 10 - 0.75) * (2 * Double.pi / 3)) + 1
        }
    }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    /// Smooth deterministic 2-D noise in -1...1 for camera shake (value noise of `x`, interpolated between integer knots).
    static func shakeNoise(_ x: Double) -> (Double, Double) {
        func h(_ i: Double, _ k: Double) -> Double { let v = sin(i * 12.9898 + k * 78.233) * 43758.5453; return (v - floor(v)) * 2 - 1 }
        let i = floor(x), f = x - i, u = f * f * (3 - 2 * f)
        return (lerp(h(i, 1), h(i + 1, 1), u), lerp(h(i, 7), h(i + 1, 7), u))
    }
    /// Value of one animation at local time `t` (seconds since its trigger) -- nil when it does not apply yet (before delay for non-loops is clamped to `from`).
    static func value(_ a: Animation, localTime t: Double) -> Double {
        if a.trigger == .loop {
            let period = max(0.0001, a.duration)
            let ph = (max(0, t - a.delay) / period).truncatingRemainder(dividingBy: 1)
            let p: Double = a.pingPong ? (ph < 0.5 ? ph * 2 : (1 - ph) * 2) : ph
            return lerp(a.from, a.to, ease(a.easing, p))
        }
        let p = a.duration <= 0 ? (t >= a.delay ? 1 : 0) : (t - a.delay) / a.duration
        return lerp(a.from, a.to, ease(a.easing, p))
    }
}
extension Layer {
    /// Combined animation state. onShow / onTake tweens hold their `to` value afterwards; onHide tweens apply only while hiding;
    /// loops run continuously. Multiple animations of the same kind multiply (opacity/scale) or add (offsets/rotation).
    func animState(_ clock: AnimClock) -> AnimState {
        var s = AnimState()
        for a in animations {
            let t: Double
            switch a.trigger {
            case .onShow: t = clock.sinceShow
            case .onTake: t = clock.sinceTake
            case .loop: t = clock.time
            case .onHide: guard let h = clock.sinceHide else { continue }; t = h
            }
            let v = Tween.value(a, localTime: t)
            let rad = a.direction * .pi / 180
            switch a.kind {
            case .fade: s.opacity *= v
            case .slide: s.dx += cos(rad) * v; s.dy += sin(rad) * v
            case .scale: s.scale *= v
            case .rotate:
                s.rotation += v
            case .wipe: let c = max(0, min(1, v)); if c < s.wipe { s.wipe = c; s.wipeAngle = a.direction }   // the most-hiding wipe sets the edge
            case .glitch: s.glitch = max(s.glitch, max(0, min(1, v)))
            case .pulse: s.scale *= 1 + v
            case .float: s.dx += cos(rad) * v; s.dy += sin(rad) * v
            case .typewriter: s.typewriter = min(s.typewriter, max(0, min(1, v)))
            case .shake:
                let amp = a.trigger == .loop ? a.to : v          // loops shake steadily at `to`
                if amp != 0 && (a.trigger == .loop || t >= a.delay) {
                    let (nx, ny) = Tween.shakeNoise(t * 32)
                    s.dx += nx * amp; s.dy += ny * amp
                }
            case .drift:
                let ph = 2 * Double.pi * t / max(0.001, a.duration)
                let along = sin(ph + a.delay) * a.to, across = sin(2 * ph + 1.3 + a.delay) * a.to * 0.3
                s.dx += cos(rad) * along - sin(rad) * across; s.dy += sin(rad) * along + cos(rad) * across
                s.scale *= 1 + a.from * 0.5 * (1 + sin(ph * 0.5 + 0.7))
            }
        }
        s.opacity = max(0, s.opacity)
        return s
    }
}

// MARK: - small helpers for template authors

extension Layer {
    static func rect(_ name: String = "Rect", x: Double, y: Double, w: Double, h: Double, fill: Fill = Fill(.white), cornerRadius: Double = 0) -> Layer {
        Layer(name: name, kind: .shape(ShapeSpec(cornerRadius > 0 ? .roundedRect : .rect, fill: fill, cornerRadius: cornerRadius)), transform: Transform(x: x, y: y, w: w, h: h))
    }
    static func text(_ name: String = "Text", _ string: String, x: Double, y: Double, w: Double, h: Double, style: TextStyle? = nil) -> Layer {
        var st = style ?? TextStyle(string); st.string = string
        return Layer(name: name, kind: .text(st), transform: Transform(x: x, y: y, w: w, h: h))
    }
    static func source(_ name: String = "Source", _ ref: SourceRef, x: Double, y: Double, w: Double, h: Double, fit: SourceFit = .fill) -> Layer {
        Layer(name: name, kind: .source(ref, fit: fit), transform: Transform(x: x, y: y, w: w, h: h))
    }
    static func image(_ name: String = "Image", propId: String, x: Double, y: Double, w: Double, h: Double) -> Layer {
        Layer(name: name, kind: .image(ImageSpec(propId: propId)), transform: Transform(x: x, y: y, w: w, h: h))
    }
    static func effect(_ name: String = "Effect", _ spec: EffectSpec, x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080, blend: BlendMode = .normal) -> Layer {
        Layer(name: name, kind: .effect(spec), transform: Transform(x: x, y: y, w: w, h: h), blend: blend)
    }
    static func group(_ name: String = "Group", _ children: [Layer], x: Double = 0, y: Double = 0, w: Double = 1920, h: Double = 1080) -> Layer {
        Layer(name: name, kind: .group(children), transform: Transform(x: x, y: y, w: w, h: h))
    }
}


func isVideoFile(_ u: URL) -> Bool { ["mp4", "m4v", "mov", "webm"].contains(u.pathExtension.lowercased()) }

extension LayerScene {
    /// Image layers whose prop is a video become `.source(.prop(id))` layers (same box, opacity, effects...).
    func videoImagesAsSources(isVideo: (String) -> Bool) -> LayerScene {
        func fix(_ l: Layer) -> Layer {
            var l = l
            switch l.kind {
            case .image(let spec):
                if let id = spec.propId, isVideo(id) { l.kind = .source(.prop(id: id), fit: spec.fit ?? .fit) }
            case .group(let kids): l.kind = .group(kids.map(fix))
            default: break
            }
            return l
        }
        var s = self; s.layers = s.layers.map(fix); return s
    }
}

extension LayerScene {
    /// Source layers with an unassigned phone (`.device(id: "")`, e.g. a built-in preset's game feed) use `id`.
    func fillingEmptyDevices(with id: String?) -> LayerScene {
        guard let id, !id.isEmpty else { return self }
        func fix(_ l: Layer) -> Layer {
            var l = l
            switch l.kind {
            case .source(.device(let d), let fit) where d.isEmpty: l.kind = .source(.device(id: id), fit: fit)
            case .group(let kids): l.kind = .group(kids.map(fix))
            default: break
            }
            return l
        }
        var s = self; s.layers = s.layers.map(fix); return s
    }
}
