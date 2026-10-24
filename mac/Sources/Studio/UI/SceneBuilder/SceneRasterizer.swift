// Lightweight CoreGraphics/CoreText rasteriser of a LayerScene, used for the editor canvas, layer thumbnails and
// template gallery when the Metal engine's `renderStill` is not available. It approximates the GPU renderer
// (blend modes, masks, borders, shadow/glow, procedural FX); live video sources are drawn as labelled placeholders
// unless the environment supplies a frame.
import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Everything the rasteriser needs from the app. All closures must be thread-safe (render happens off the main thread).
struct RasterEnv: @unchecked Sendable {
    var variables = SceneVariables.sample
    var variableDefaults: [String: String] = [:]
    /// seconds, drives procedural FX phase; fixed value = still frame
    var time = 0.8
    /// seconds since the scene appeared (drives onShow animations); nil = animations already settled
    var showClock: Double? = nil
    var propImages: [String: CGImage] = [:]
    var sourceNames: [SourceRef: String] = [:]
    var sourceFrames: [SourceRef: CGImage] = [:]
    var theme: PropTheme = .ember
    /// hide a layer id (e.g. while it is being edited elsewhere); nil = draw all
    var skip: Set<String> = []
}

enum SceneRasterizer {
    static func render(_ scene: LayerScene, width: Int, env: RasterEnv = RasterEnv(), only layer: Layer? = nil) -> CGImage? {
        let aspect = Double(scene.canvas.h) / Double(max(1, scene.canvas.w))
        let w = max(8, width), h = max(8, Int((Double(w) * aspect).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)             // y-down
        let s = CGFloat(w) / CGFloat(scene.canvas.w)
        ctx.scaleBy(x: s, y: s)
        ctx.interpolationQuality = .high
        let size = CGSize(width: scene.canvas.w, height: scene.canvas.h)
        if let layer {
            var l = layer; l.transform.x = 0; l.transform.y = 0
            drawLayer(l, ctx, env, canvas: size)
        } else {
            drawBackground(scene.background, ctx, size, env)
            var e = env; e.variableDefaults = scene.variableDefaults
            for l in scene.layers where l.visible && !env.skip.contains(l.id) { drawLayer(l, ctx, e, canvas: size) }
        }
        return ctx.makeImage()
    }

    /// Thumbnail of a single layer fitted into a square.
    static func layerThumbnail(_ layer: Layer, size: Int, env: RasterEnv = RasterEnv()) -> CGImage? {
        let w = max(1, layer.transform.w), h = max(1, layer.transform.h)
        let k = Double(size) / max(w, h)
        var scene = LayerScene(name: "t", canvas: CanvasSize(w: Int(w.rounded()), h: Int(h.rounded())))
        var l = layer; l.transform.rotation = 0; l.transform.x = 0; l.transform.y = 0; l.visible = true; l.opacity = 1
        l.animations = []
        scene.layers = [l]
        scene.background = Background.solid(RGBA(0.08, 0.085, 0.1))
        return render(scene, width: max(8, Int((w * k).rounded())), env: env)
    }

    // MARK: background
    static func drawBackground(_ b: Background, _ ctx: CGContext, _ size: CGSize, _ env: RasterEnv) {
        let r = CGRect(origin: .zero, size: size)
        switch b.kind {
        case .solid: ctx.setFillColor(b.color.cgColor); ctx.fill(r)
        case .linearGradient, .radialGradient:
            ctx.setFillColor(b.color.cgColor); ctx.fill(r)
            if let g = b.gradient { var gg = g; gg.radial = b.kind == .radialGradient; fillGradient(gg, ctx, r) }
        case .image, .video:
            ctx.setFillColor(RGBA(0.05, 0.05, 0.06).cgColor); ctx.fill(r)
            if let id = b.propId, let img = env.propImages[id] { drawImage(img, ctx, r, fit: b.fit) }
        case .source:
            ctx.setFillColor(RGBA(0.05, 0.06, 0.08).cgColor); ctx.fill(r)
            if let s = b.source { drawSourcePlaceholder(s, ctx, r, env, fit: b.fit) }
        }
        if b.dim > 0 { ctx.setFillColor(CGColor(gray: 0, alpha: b.dim)); ctx.fill(r) }
    }

    // MARK: layers
    static func blendMode(_ b: BlendMode) -> CGBlendMode {
        switch b { case .normal: .normal; case .add: .plusLighter; case .screen: .screen; case .multiply: .multiply; case .overlay: .overlay }
    }

    static func path(for layer: Layer, box: CGRect) -> CGPath {
        let m = layer.mask
        switch m.kind {
        case .circle: return CGPath(ellipseIn: box, transform: nil)
        case .hexagon:
            let p = CGMutablePath(); let cx = box.midX, cy = box.midY, rx = box.width / 2, ry = box.height / 2
            for i in 0..<6 { let a = Double(i) * .pi / 3; let pt = CGPoint(x: cx + CGFloat(cos(a)) * rx, y: cy + CGFloat(sin(a)) * ry); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
            p.closeSubpath(); return p
        case .parallelogram:
            let k = box.height * CGFloat(m.skew); let p = CGMutablePath()
            p.move(to: CGPoint(x: box.minX + k, y: box.minY)); p.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            p.addLine(to: CGPoint(x: box.maxX - k, y: box.maxY)); p.addLine(to: CGPoint(x: box.minX, y: box.maxY)); p.closeSubpath(); return p
        case .roundedRect:
            let r = min(CGFloat(layer.cornerRadius > 0 ? layer.cornerRadius : min(box.width, box.height) * 0.15), min(box.width, box.height) / 2)
            return CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        default:
            if layer.cornerRadius > 0 {
                let r = min(CGFloat(layer.cornerRadius), min(box.width, box.height) / 2)
                return CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
            }
            return CGPath(rect: box, transform: nil)
        }
    }

    static func drawLayer(_ layer: Layer, _ ctx: CGContext, _ env: RasterEnv, canvas: CGSize) {
        guard layer.visible else { return }
        let t = layer.transform
        let anim = layer.animState(AnimClock(sinceShow: env.showClock ?? (env.time + 60), time: env.time))
        ctx.saveGState()
        let cx = t.x + t.w * t.anchorX + anim.dx, cy = t.y + t.h * t.anchorY + anim.dy
        ctx.translateBy(x: cx, y: cy)
        let rot = (t.rotation + anim.rotation) * .pi / 180
        if rot != 0 { ctx.rotate(by: CGFloat(rot)) }
        if anim.scale != 1 { ctx.scaleBy(x: anim.scale, y: anim.scale) }
        ctx.scaleBy(x: t.flipX ? -1 : 1, y: t.flipY ? -1 : 1)
        let box = CGRect(x: -t.w * t.anchorX, y: -t.h * t.anchorY, width: t.w, height: t.h)
        ctx.setAlpha(CGFloat(max(0, min(1, layer.opacity * anim.opacity))))
        ctx.setBlendMode(blendMode(layer.blend))

        let needsGroup = layer.shadow.isOn || layer.glow.isOn
        if layer.glow.isOn {
            ctx.setShadow(offset: .zero, blur: CGFloat(layer.glow.radius), color: layer.glow.color.withAlpha(min(1, layer.glow.intensity)).cgColor)
        } else if layer.shadow.isOn {
            ctx.setShadow(offset: CGSize(width: layer.shadow.dx, height: layer.shadow.dy), blur: CGFloat(layer.shadow.blur), color: layer.shadow.color.cgColor)
        }
        if needsGroup { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        drawContent(layer, ctx, box, env, canvas: canvas, anim: anim)
        if layer.border.width > 0 { drawBorder(layer, ctx, box) }
        if needsGroup { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    static func drawContent(_ layer: Layer, _ ctx: CGContext, _ box: CGRect, _ env: RasterEnv, canvas: CGSize, anim: AnimState) {
        ctx.saveGState()
        let clipPath = path(for: layer, box: box)
        let masked = layer.mask.kind != .none || layer.cornerRadius > 0
        if masked { ctx.addPath(clipPath); ctx.clip() }
        var inner = box
        if !layer.crop.isZero {
            inner = CGRect(x: box.minX + box.width * CGFloat(layer.crop.l), y: box.minY + box.height * CGFloat(layer.crop.t),
                           width: box.width * CGFloat(1 - layer.crop.l - layer.crop.r), height: box.height * CGFloat(1 - layer.crop.t - layer.crop.b))
            ctx.clip(to: inner)
        }
        if anim.wipe < 1 { ctx.clip(to: CGRect(x: box.minX, y: box.minY, width: box.width * CGFloat(anim.wipe), height: box.height)) }
        switch layer.kind {
        case .shape(let spec): drawShape(spec, ctx, box)
        case .text(let st): drawText(st, ctx, box, env, reveal: anim.typewriter)
        case .image(let spec):
            var img: CGImage? = nil
            if let b = spec.builtin { img = BuiltinAssets.asset(b)?.image(scale: 1, theme: spec.theme.map { PropTheme.named($0) } ?? env.theme) }
            else if let p = spec.propId { img = env.propImages[p] }
            if let img { drawImage(img, ctx, box, fit: spec.fit ?? .fit) } else { placeholder(ctx, box, "photo") }
        case .source(let ref, let fit): drawSourcePlaceholder(ref, ctx, box, env, fit: fit)
        case .group(let kids):
            ctx.saveGState(); ctx.clip(to: box); ctx.translateBy(x: box.minX, y: box.minY)
            for k in kids where k.visible && !env.skip.contains(k.id) { drawLayer(k, ctx, env, canvas: CGSize(width: box.width, height: box.height)) }
            ctx.restoreGState()
        case .effect(let spec): drawEffect(spec, ctx, box, env)
        case .teamBoard(let spec):
            let k = max(1, min(2, 1080 / max(1, box.height)))
            if let img = TeamBoardArt.composite(spec, vars: env.variables, defaults: env.variableDefaults, w: max(8, Int(box.width * k)), h: max(8, Int(box.height * k)), time: env.time) {
                drawImage(img, ctx, box, fit: .stretch)
            }
        }
        // colour adjust (approximate): tint + brightness overlays
        if !layer.colorAdjust.isIdentity {
            let ca = layer.colorAdjust
            if let tint = ca.tint, tint.a > 0 { ctx.setBlendMode(.multiply); ctx.setFillColor(tint.withAlpha(tint.a).cgColor); ctx.fill(box) }
            if ca.brightness > 0 { ctx.setBlendMode(.plusLighter); ctx.setFillColor(CGColor(gray: 1, alpha: ca.brightness * 0.5)); ctx.fill(box) }
            else if ca.brightness < 0 { ctx.setBlendMode(.multiply); ctx.setFillColor(CGColor(gray: 0, alpha: -ca.brightness * 0.7)); ctx.fill(box) }
            if ca.saturation <= -0.99 { ctx.setBlendMode(.saturation); ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(box) }
        }
        ctx.restoreGState()
    }

    static func drawBorder(_ layer: Layer, _ ctx: CGContext, _ box: CGRect) {
        let w = CGFloat(layer.border.width)
        ctx.saveGState()
        let p = path(for: layer, box: box)
        ctx.addPath(p); ctx.clip()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let inset = path(for: layer, box: box.insetBy(dx: w / 2, dy: w / 2))
        ctx.addPath(inset); ctx.setLineWidth(w)
        if let g = layer.border.gradient {
            ctx.replacePathWithStrokedPath(); ctx.clip()
            fillGradient(g, ctx, box)
        } else { ctx.setStrokeColor(layer.border.color.cgColor); ctx.strokePath() }
        ctx.restoreGState()
    }

    // MARK: shapes
    static func shapePath(_ s: ShapeSpec, _ box: CGRect) -> CGPath {
        switch s.kind {
        case .rect: return CGPath(rect: box, transform: nil)
        case .roundedRect:
            let r = min(CGFloat(s.cornerRadius), min(box.width, box.height) / 2); return CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        case .ellipse: return CGPath(ellipseIn: box, transform: nil)
        case .polygon:
            let p = CGMutablePath(); let n = max(3, s.sides); let star = s.starInset > 0
            let count = star ? n * 2 : n
            for i in 0..<count {
                let a = -Double.pi / 2 + Double(i) * 2 * .pi / Double(count)
                let k = star && i % 2 == 1 ? (1 - s.starInset) : 1
                let pt = CGPoint(x: box.midX + CGFloat(cos(a) * k) * box.width / 2, y: box.midY + CGFloat(sin(a) * k) * box.height / 2)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath(); return p
        case .line:
            let p = CGMutablePath()
            if box.height < 1 { p.move(to: CGPoint(x: box.minX, y: box.midY)); p.addLine(to: CGPoint(x: box.maxX, y: box.midY)) }
            else { p.move(to: CGPoint(x: box.minX, y: box.minY)); p.addLine(to: CGPoint(x: box.maxX, y: box.maxY)) }
            return p
        }
    }
    static func drawShape(_ s: ShapeSpec, _ ctx: CGContext, _ box: CGRect) {
        let p = shapePath(s, box)
        if s.kind == .line {
            ctx.addPath(p); ctx.setLineWidth(CGFloat(s.lineWidth)); ctx.setLineCap(.round)
            ctx.setStrokeColor(s.fill.color.cgColor); ctx.strokePath(); return
        }
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        ctx.setFillColor(s.fill.color.cgColor); ctx.fill(box)
        if let g = s.fill.gradient { fillGradient(g, ctx, box) }
        ctx.restoreGState()
        if s.stroke.width > 0 {
            ctx.saveGState()
            ctx.addPath(p); ctx.setLineWidth(CGFloat(s.stroke.width))
            if let g = s.stroke.gradient { ctx.replacePathWithStrokedPath(); ctx.clip(); fillGradient(g, ctx, box) }
            else { ctx.setStrokeColor(s.stroke.color.cgColor); ctx.strokePath() }
            ctx.restoreGState()
        }
    }

    static func cgGradient(_ g: Gradient) -> CGGradient? {
        let stops = g.stops.sorted { $0.pos < $1.pos }
        return CGGradient(colorSpace: sRGBSpace, colorComponents: stops.flatMap { [CGFloat($0.color.r), CGFloat($0.color.g), CGFloat($0.color.b), CGFloat($0.color.a)] },
                          locations: stops.map { CGFloat($0.pos) }, count: stops.count)
    }
    static func fillGradient(_ g: Gradient, _ ctx: CGContext, _ r: CGRect) {
        guard let cg = cgGradient(g) else { return }
        ctx.saveGState(); ctx.clip(to: r)
        if g.radial {
            let c = CGPoint(x: r.minX + r.width * CGFloat(g.cx), y: r.minY + r.height * CGFloat(g.cy))
            let rad = CGFloat(g.radius) * hypot(r.width, r.height) / 2
            ctx.drawRadialGradient(cg, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(1, rad), options: [.drawsAfterEndLocation])
        } else {
            let a = g.angle * .pi / 180
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            let half = (abs(dx) * r.width + abs(dy) * r.height) / 2
            let c = CGPoint(x: r.midX, y: r.midY)
            ctx.drawLinearGradient(cg, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half), end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    // MARK: images
    static func drawImage(_ img: CGImage, _ ctx: CGContext, _ r: CGRect, fit: SourceFit) {
        ctx.saveGState()
        ctx.clip(to: r)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        var dst = r
        switch fit {
        case .stretch: break
        case .fill: let k = max(r.width / iw, r.height / ih); dst = CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k)
        case .fit: let k = min(r.width / iw, r.height / ih); dst = CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k)
        }
        // our context is y-down: flip locally so the image is upright
        ctx.translateBy(x: dst.minX, y: dst.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: dst.width, height: dst.height))
        ctx.restoreGState()
    }
    static func placeholder(_ ctx: CGContext, _ r: CGRect, _ symbol: String) {
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(r)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.2)); ctx.setLineWidth(2); ctx.stroke(r.insetBy(dx: 1, dy: 1))
    }
    static func drawSourcePlaceholder(_ ref: SourceRef, _ ctx: CGContext, _ r: CGRect, _ env: RasterEnv, fit: SourceFit) {
        if let f = env.sourceFrames[ref] { drawImage(f, ctx, r, fit: fit); return }
        ctx.saveGState(); ctx.clip(to: r)
        let g = CGGradient(colorSpace: sRGBSpace, colorComponents: [0.13, 0.17, 0.26, 1, 0.05, 0.07, 0.12, 1], locations: [0, 1], count: 2)!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        // diagonal hatch so it reads as "video goes here"
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.04)); ctx.setLineWidth(max(2, r.width / 160))
        var x = r.minX - r.height
        while x < r.maxX { ctx.move(to: CGPoint(x: x, y: r.maxY)); ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY)); x += max(14, r.width / 24) }
        ctx.strokePath()
        // camera glyph
        let s = min(r.width, r.height) * 0.22
        let body = CGRect(x: r.midX - s * 0.8, y: r.midY - s * 0.55 - s * 0.15, width: s * 1.6, height: s * 1.1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.14, cornerHeight: s * 0.14, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5)); ctx.fillEllipse(in: CGRect(x: body.midX - s * 0.32, y: body.midY - s * 0.32, width: s * 0.64, height: s * 0.64))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.45)); ctx.fillEllipse(in: CGRect(x: body.midX - s * 0.2, y: body.midY - s * 0.2, width: s * 0.4, height: s * 0.4))
        let name = env.sourceNames[ref] ?? defaultName(ref)
        var st = TextStyle(name, font: "Helvetica Neue", size: max(12, min(r.height * 0.09, 44)), weight: 600, color: RGBA(1, 1, 1, 0.85))
        st.alignment = .center
        drawText(st, ctx, CGRect(x: r.minX, y: body.maxY + s * 0.2, width: r.width, height: s * 0.7), env, reveal: 1)
        ctx.restoreGState()
    }
    static func defaultName(_ r: SourceRef) -> String {
        switch r { case .device: "Phone"; case .camera: "Webcam"; case .prop: "Video"; case .slate: "Slate"; case .image: "Image"; case .web: "Web image" }
    }

    // MARK: text
    static func makeFont(_ st: TextStyle) -> CTFont {
        let w = max(100, min(900, st.weight))
        let nsw: NSFont.Weight = w < 200 ? .ultraLight : w < 300 ? .thin : w < 400 ? .light : w < 500 ? .regular : w < 600 ? .medium : w < 700 ? .semibold : w < 800 ? .bold : w < 900 ? .heavy : .black
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: nsw.rawValue]
        if st.italic { traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue }
        var d = NSFontDescriptor(fontAttributes: [.family: st.font])
        d = d.addingAttributes([.traits: traits])
        if let f = NSFont(descriptor: d, size: CGFloat(st.size)), f.familyName != nil { return f as CTFont }
        return NSFont.systemFont(ofSize: CGFloat(st.size), weight: nsw) as CTFont
    }

    /// Wrapped lines of a text style inside a width.
    static func layoutLines(_ text: String, font: CTFont, tracking: Double, width: CGFloat) -> [CTLine] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        if tracking != 0 { attrs[.kern] = tracking }
        var out: [CTLine] = []
        for para in text.components(separatedBy: "\n") {
            let a = NSAttributedString(string: para.isEmpty ? " " : para, attributes: attrs)
            let ts = CTTypesetterCreateWithAttributedString(a)
            var start = 0
            let len = a.length
            while start < len {
                let n = CTTypesetterSuggestLineBreak(ts, start, Double(max(10, width)))
                let c = max(1, n)
                out.append(CTTypesetterCreateLine(ts, CFRange(location: start, length: c)))
                start += c
            }
        }
        return out
    }

    static func drawText(_ st: TextStyle, _ ctx: CGContext, _ box: CGRect, _ env: RasterEnv, reveal: Double) {
        var s = env.variables.resolve(st.string, defaults: env.variableDefaults)
        if st.allCaps { s = s.uppercased() }
        if reveal < 1 { s = String(s.prefix(Int(Double(s.count) * reveal))) }
        guard !s.isEmpty else { return }
        let font = makeFont(st)
        let lines = layoutLines(s, font: font, tracking: st.tracking, width: box.width)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font), lead = CTFontGetLeading(font)
        let lh = asc + desc + lead + CGFloat(st.lineSpacing)
        let total = lh * CGFloat(lines.count) - CGFloat(st.lineSpacing)
        var y = box.midY - total / 2 + asc
        ctx.saveGState()
        ctx.clip(to: box.insetBy(dx: -box.width, dy: -box.height))      // permissive: text may overflow
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in lines {
            let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x: CGFloat
            switch st.alignment { case .left: x = box.minX; case .center: x = box.midX - lw / 2; case .right: x = box.maxX - lw }
            let lineRect = CGRect(x: x, y: y - asc, width: lw, height: asc + desc)
            ctx.saveGState()
            if st.shadow.isOn {
                ctx.setShadow(offset: CGSize(width: st.shadow.dx, height: st.shadow.dy), blur: CGFloat(st.shadow.blur), color: st.shadow.color.cgColor)
            }
            if st.stroke.width > 0 {
                ctx.setTextDrawingMode(.stroke); ctx.setLineWidth(CGFloat(st.stroke.width) * 2); ctx.setLineJoin(.round)
                ctx.setStrokeColor(st.stroke.color.cgColor)
                ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
            }
            if let g = st.gradient {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setTextDrawingMode(.fill); ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
                ctx.setBlendMode(.sourceIn)
                fillGradient(g, ctx, lineRect)
                ctx.endTransparencyLayer()
            } else {
                ctx.setTextDrawingMode(.fill); ctx.setFillColor(st.color.cgColor)
                ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
            y += lh
        }
        ctx.restoreGState()
    }

    // MARK: procedural effects
    struct RNG {
        var state: UInt64
        init(_ seed: UInt32) { state = UInt64(seed) &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_003) / 1_000_003
        }
    }
    static func glowDot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ inner: RGBA, _ outer: RGBA, alpha: Double) {
        let g = CGGradient(colorSpace: sRGBSpace, colorComponents: [
            CGFloat(inner.r), CGFloat(inner.g), CGFloat(inner.b), CGFloat(alpha),
            CGFloat(outer.r), CGFloat(outer.g), CGFloat(outer.b), CGFloat(alpha * 0.5),
            CGFloat(outer.r), CGFloat(outer.g), CGFloat(outer.b), 0], locations: [0, 0.45, 1], count: 3)!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }
    static func drawEffect(_ e: EffectSpec, _ ctx: CGContext, _ box: CGRect, _ env: RasterEnv) {
        ctx.saveGState(); ctx.clip(to: box)
        var rng = RNG(e.seed)
        let t = env.time * e.speed
        switch e.kind {
        case .fireEmitter:
            ctx.setBlendMode(.plusLighter)
            let n = min(e.count, 260)
            for _ in 0..<n {
                let x = box.minX + CGFloat(rng.next()) * box.width, off = rng.next(), sz = 0.5 + rng.next()
                let ph = (t * 0.55 + off).truncatingRemainder(dividingBy: 1)
                let y = box.maxY - CGFloat(ph) * box.height * 0.9
                let r = CGFloat(e.size * e.intensity * (1 - ph * 0.6) * sz * 1.6) * (box.width / 800 + 0.7)
                let sway = CGFloat(sin(t * 3 + off * 20)) * 14 * CGFloat(ph)
                glowDot(ctx, CGPoint(x: x + sway, y: y), r, ph < 0.4 ? e.color.mixed(.white, 0.35) : e.color, e.color2, alpha: 0.5 * (1 - ph))
            }
        case .embers, .sparks:
            ctx.setBlendMode(.plusLighter)
            for _ in 0..<min(e.count, 200) {
                let x = box.minX + CGFloat(rng.next()) * box.width, off = rng.next()
                let ph = (t * 0.25 + off).truncatingRemainder(dividingBy: 1)
                let y = e.kind == .embers ? box.maxY - CGFloat(ph) * box.height : box.midY + CGFloat(rng.next() - 0.5) * box.height * 0.5
                let r = CGFloat(2 + rng.next() * 4) * CGFloat(e.intensity)
                glowDot(ctx, CGPoint(x: x + CGFloat(sin(t * 2 + off * 9)) * 20, y: y), r * 2.2, e.color.mixed(.white, 0.5), e.color, alpha: 1 - ph)
            }
        case .smoke:
            for _ in 0..<min(e.count, 60) {
                let x = box.minX + CGFloat(rng.next()) * box.width, off = rng.next()
                let ph = (t * 0.12 + off).truncatingRemainder(dividingBy: 1)
                let y = box.maxY - CGFloat(ph) * box.height
                glowDot(ctx, CGPoint(x: x, y: y), CGFloat(60 + ph * 140) * CGFloat(e.intensity), RGBA(0.55, 0.57, 0.6), RGBA(0.3, 0.3, 0.34), alpha: 0.18 * (1 - ph))
            }
        case .lightning:
            ctx.setBlendMode(.plusLighter)
            ctx.setLineJoin(.round)
            var x = box.midX + CGFloat(rng.next() - 0.5) * box.width * 0.5
            var y = box.minY
            let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y))
            while y < box.maxY { x += CGFloat(rng.next() - 0.5) * 70; y += 30 + CGFloat(rng.next()) * 40; p.addLine(to: CGPoint(x: x, y: y)) }
            for (w, a) in [(14.0, 0.15), (7.0, 0.35), (2.5, 1.0)] {
                ctx.addPath(p); ctx.setLineWidth(w); ctx.setStrokeColor(e.color.mixed(.white, w < 3 ? 0.8 : 0.1).withAlpha(a).cgColor); ctx.strokePath()
            }
        case .scanlines:
            let step = max(2, CGFloat(e.size))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.28 * e.intensity))
            var y = box.minY; while y < box.maxY { ctx.fill(CGRect(x: box.minX, y: y, width: box.width, height: step / 2)); y += step }
        case .glitch:
            for _ in 0..<12 {
                let y = box.minY + CGFloat(rng.next()) * box.height, h = 4 + CGFloat(rng.next()) * 28
                let x = box.minX + CGFloat(rng.next()) * box.width * 0.6, w = box.width * CGFloat(0.1 + rng.next() * 0.4)
                ctx.setFillColor((rng.next() > 0.5 ? RGBA(1, 0.1, 0.4) : RGBA(0.1, 0.9, 1)).withAlpha(0.35).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            }
        case .vignette:
            let g = CGGradient(colorSpace: sRGBSpace, colorComponents: [0, 0, 0, 0, 0, 0, 0, CGFloat(min(1, 0.85 * e.intensity))], locations: [CGFloat(max(0.05, 1 - e.size / 100 - 0.2)), 1], count: 2)!
            let c = CGPoint(x: box.midX, y: box.midY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(box.width, box.height) / 2, options: [.drawsAfterEndLocation])
        case .filmGrain:
            for _ in 0..<2500 {
                ctx.setFillColor(CGColor(gray: rng.next() > 0.5 ? 1 : 0, alpha: 0.06 * e.intensity))
                ctx.fill(CGRect(x: box.minX + CGFloat(rng.next()) * box.width, y: box.minY + CGFloat(rng.next()) * box.height, width: 2, height: 2))
            }
        case .lightSweep:
            ctx.setBlendMode(.plusLighter)
            let p = CGFloat((t * 0.4).truncatingRemainder(dividingBy: 1.4) - 0.2)
            let cx = box.minX + box.width * p
            let g = CGGradient(colorSpace: sRGBSpace, colorComponents: [1, 1, 1, 0, 1, 1, 1, CGFloat(0.5 * e.intensity), 1, 1, 1, 0], locations: [0, 0.5, 1], count: 3)!
            ctx.drawLinearGradient(g, start: CGPoint(x: cx - box.height * 0.3 - 80, y: box.minY), end: CGPoint(x: cx + box.height * 0.3 + 80, y: box.maxY), options: [])
        case .pulsingGlow:
            ctx.setBlendMode(.plusLighter)
            let k = 0.75 + 0.25 * sin(t * 2.5)
            glowDot(ctx, CGPoint(x: box.midX, y: box.midY), max(box.width, box.height) * 0.5, e.color, e.color2, alpha: 0.7 * e.intensity * k)
        case .hudCornerBrackets:
            let L = CGFloat(e.size), th = CGFloat(e.thickness)
            ctx.setStrokeColor(e.color.cgColor); ctx.setLineWidth(th); ctx.setLineCap(.square)
            let r = box.insetBy(dx: th, dy: th)
            for (cx, cy, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                ctx.move(to: CGPoint(x: cx + CGFloat(sx) * L, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy + CGFloat(sy) * L))
            }
            ctx.strokePath()
        case .radarSweep:
            let c = CGPoint(x: box.midX, y: box.midY), R = min(box.width, box.height) / 2
            ctx.setStrokeColor(e.color.withAlpha(0.5).cgColor); ctx.setLineWidth(CGFloat(e.thickness))
            for k in 1...3 { ctx.strokeEllipse(in: CGRect(x: c.x - R * CGFloat(k) / 3, y: c.y - R * CGFloat(k) / 3, width: R * 2 * CGFloat(k) / 3, height: R * 2 * CGFloat(k) / 3)) }
            let a = t * 2
            ctx.setFillColor(e.color.withAlpha(0.35).cgColor)
            ctx.move(to: c); ctx.addArc(center: c, radius: R, startAngle: CGFloat(a - 0.7), endAngle: CGFloat(a), clockwise: false); ctx.fillPath()
        case .animatedGradient:
            fillGradient(Gradient.linear(e.color, e.color2, angle: e.angle + t * 20), ctx, box)
        case .ticker, .countdown, .killfeedLine:
            if e.kind == .killfeedLine {
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.55)); ctx.fill(box)
                ctx.setFillColor(e.color.cgColor); ctx.fill(CGRect(x: box.minX, y: box.minY, width: 6, height: box.height))
            }
            var st = TextStyle(e.text, size: e.fontSize, weight: 800, color: .white)
            st.alignment = e.kind == .ticker ? .left : e.kind == .countdown ? .center : .left
            var b = box
            if e.kind == .killfeedLine { b.origin.x += 18 }
            drawText(st, ctx, b, env, reveal: 1)
        }
        ctx.restoreGState()
    }
}

extension RGBA {
    func withAlpha(_ a: Double) -> RGBA { var c = self; c.a = a; return c }
    func mixed(_ o: RGBA, _ t: Double) -> RGBA { RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a) }
}

let sRGBSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
