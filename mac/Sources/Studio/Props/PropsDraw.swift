// Drawing toolkit for the Battleground Pro pack: metal plates, hazard stripes, rivets, glow, flames, stencil type.
import Foundation
import CoreGraphics
import CoreText

struct PRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return s &* 2685821657736338717 }
    mutating func f() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f() }
}

enum PC {
    static let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
    }
    // gunmetal ramp
    static let s0: UInt32 = 0x0B0D10, s1: UInt32 = 0x14171B, s2: UInt32 = 0x1E2227, s3: UInt32 = 0x2B3138
    static let s4: UInt32 = 0x434B55, s5: UInt32 = 0x6B7683, s6: UInt32 = 0xA3AEBB, s7: UInt32 = 0xDDE3EA
    static let white = c(0xFFFFFF), black = c(0x000000), clear = c(0, 0)
}

enum PFont {
    static let headline = ["Impact", "HelveticaNeue-CondensedBlack", "DINCondensed-Bold", "ArialNarrow-Bold", "HelveticaNeue-Bold"]
    static let tag = ["DINCondensed-Bold", "AvenirNextCondensed-Heavy", "HelveticaNeue-CondensedBold", "ArialNarrow-Bold", "HelveticaNeue-Bold"]
    static let italic = ["AvenirNextCondensed-HeavyItalic", "AvenirNextCondensed-BoldItalic", "Impact", "HelveticaNeue-BoldItalic"]
    static let mono = ["Menlo-Bold", "Courier-Bold", "HelveticaNeue-Bold"]
    static let wide = ["Futura-CondensedExtraBold", "AvenirNextCondensed-Heavy", "Impact"]
    static let body = ["AvenirNextCondensed-DemiBold", "HelveticaNeue-Medium", "HelveticaNeue"]
    static func resolve(_ names: [String]) -> String {
        for n in names {
            let f = CTFontCreateWithName(n as CFString, 12, nil)
            if (CTFontCopyPostScriptName(f) as String) == n { return n }
        }
        return "HelveticaNeue-Bold"
    }
    static func make(_ names: [String], _ size: CGFloat) -> CTFont { CTFontCreateWithName(resolve(names) as CFString, size, nil) }
}

enum Align { case left, center, right }

extension PCtx {
    // MARK: paths
    func chamfer(_ r: CGRect, _ tl: CGFloat, _ tr: CGFloat? = nil, _ br: CGFloat? = nil, _ bl: CGFloat? = nil) -> CGPath {
        let tr = tr ?? tl, br = br ?? tl, bl = bl ?? tl
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + tr)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addLine(to: CGPoint(x: r.maxX - br, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - bl)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.closeSubpath(); return p
    }
    func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }
    func poly(_ v: [CGFloat]) -> CGPath {
        var pts: [CGPoint] = []; var i = 0
        while i + 1 < v.count { pts.append(CGPoint(x: v[i], y: v[i + 1])); i += 2 }
        return poly(pts)
    }
    /// Parallelogram leaning right (skew px at top).
    func para(_ r: CGRect, skew: CGFloat) -> CGPath {
        poly([CGPoint(x: r.minX + skew, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - skew, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
    }
    func hexagon(_ r: CGRect, cut: CGFloat) -> CGPath {
        let m = r.midY
        return poly([CGPoint(x: r.minX + cut, y: r.minY), CGPoint(x: r.maxX - cut, y: r.minY), CGPoint(x: r.maxX, y: m),
                     CGPoint(x: r.maxX - cut, y: r.maxY), CGPoint(x: r.minX + cut, y: r.maxY), CGPoint(x: r.minX, y: m)])
    }
    func ringPath(_ outer: CGPath, _ inner: CGPath) -> CGPath {
        let p = CGMutablePath(); p.addPath(outer); p.addPath(inner); return p
    }
    func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
    func rrect(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2), cornerHeight: min(rad, r.height / 2), transform: nil) }

    // MARK: paint
    func fill(_ p: CGPath, _ c: CGColor, evenOdd: Bool = false) {
        g.saveGState(); g.addPath(p); g.setFillColor(c); g.fillPath(using: evenOdd ? .evenOdd : .winding); g.restoreGState()
    }
    func stroke(_ p: CGPath, _ c: CGColor, _ w: CGFloat, join: CGLineJoin = .miter, cap: CGLineCap = .butt) {
        g.saveGState(); g.addPath(p); g.setStrokeColor(c); g.setLineWidth(w); g.setLineJoin(join); g.setLineCap(cap); g.strokePath(); g.restoreGState()
    }
    func grad(_ stops: [(CGFloat, CGColor)], _ a: CGPoint, _ b: CGPoint, clip: CGPath? = nil, evenOdd: Bool = false, opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]) {
        g.saveGState()
        if let clip { g.addPath(clip); g.clip(using: evenOdd ? .evenOdd : .winding) }
        let gr = CGGradient(colorsSpace: PC.cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
        g.drawLinearGradient(gr, start: a, end: b, options: opts); g.restoreGState()
    }
    func vgrad(_ p: CGPath, _ stops: [(CGFloat, CGColor)], evenOdd: Bool = false) {
        let b = p.boundingBoxOfPath
        grad(stops, CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.midX, y: b.maxY), clip: p, evenOdd: evenOdd)
    }
    func hgrad(_ p: CGPath, _ stops: [(CGFloat, CGColor)]) {
        let b = p.boundingBoxOfPath
        grad(stops, CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.maxX, y: b.midY), clip: p)
    }
    func radial(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ stops: [(CGFloat, CGColor)], clip: CGPath? = nil, additive: Bool = false) {
        g.saveGState()
        if let clip { g.addPath(clip); g.clip() }
        if additive { g.setBlendMode(.plusLighter) }
        let gr = CGGradient(colorsSpace: PC.cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
        g.drawRadialGradient(gr, startCenter: c, startRadius: r0, endCenter: c, endRadius: r1, options: [.drawsAfterEndLocation])
        g.restoreGState()
    }
    func setGlow(_ c: CGColor, _ blur: CGFloat) { g.setShadow(offset: .zero, blur: blur * scale, color: c) }

    /// Neon-style glow edge: wide soft passes then a crisp core.
    func glowStroke(_ p: CGPath, _ c: CGColor, _ w: CGFloat, radius: CGFloat = 10, core: CGColor? = nil) {
        g.saveGState(); setGlow(c, radius); stroke(p, c, w); stroke(p, c, w); g.restoreGState()
        if let core { stroke(p, core, max(0.6, w * 0.4)) }
    }
    func glowFill(_ p: CGPath, _ c: CGColor, radius: CGFloat = 10) {
        g.saveGState(); setGlow(c, radius); fill(p, c); g.restoreGState()
    }
    func dropShadow(_ p: CGPath, _ fillC: CGColor, dy: CGFloat = 4, blur: CGFloat = 8, alpha: CGFloat = 0.55) {
        g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: PC.c(0, alpha))
        // NB: our context is flipped, shadow offset is in device space (y up), so negative = down on screen.
        fill(p, fillC); g.restoreGState()
    }
    func innerShadow(_ p: CGPath, blur: CGFloat = 12, alpha: CGFloat = 0.6, dy: CGFloat = 0) {
        g.saveGState(); g.addPath(p); g.clip()
        let big = CGMutablePath(); big.addRect(p.boundingBoxOfPath.insetBy(dx: -200, dy: -200)); big.addPath(p)
        g.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: PC.c(0, alpha))
        g.addPath(big); g.setFillColor(PC.c(0)); g.fillPath(using: .evenOdd); g.restoreGState()
    }

    // MARK: material
    func brushed(_ p: CGPath, alpha: CGFloat = 0.10, seed: UInt64 = 7) {
        g.saveGState(); g.addPath(p); g.clip()
        var r = PRNG(seed); let b = p.boundingBoxOfPath
        var y = b.minY
        while y < b.maxY {
            let light = r.f() > 0.5
            g.setStrokeColor(light ? PC.c(0xFFFFFF, alpha * r.r(0.3, 1)) : PC.c(0, alpha * r.r(0.5, 1.4)))
            g.setLineWidth(r.r(0.4, 1.0))
            g.move(to: CGPoint(x: b.minX, y: y)); g.addLine(to: CGPoint(x: b.maxX, y: y)); g.strokePath()
            y += r.r(0.8, 2.0)
        }
        g.restoreGState()
    }
    func grunge(_ p: CGPath, alpha: CGFloat = 0.25, seed: UInt64 = 3, density: CGFloat = 1) {
        g.saveGState(); g.addPath(p); g.clip()
        var r = PRNG(seed); let b = p.boundingBoxOfPath
        let n = Int(b.width * b.height / 900 * density)
        for _ in 0..<max(4, min(n, 900)) {
            let x = r.r(b.minX, b.maxX), y = r.r(b.minY, b.maxY), rad = r.r(0.4, 2.6)
            g.setFillColor(PC.c(r.f() > 0.55 ? 0xFFFFFF : 0x000000, alpha * r.r(0.2, 1) * (rad < 1 ? 1 : 0.6)))
            g.fillEllipse(in: CGRect(x: x, y: y, width: rad * (r.f() > 0.7 ? 3 : 1), height: rad))
        }
        // scratches
        for _ in 0..<max(3, min(n / 14, 40)) {
            let x = r.r(b.minX, b.maxX), y = r.r(b.minY, b.maxY), l = r.r(8, 38), a = r.r(-0.5, 0.5)
            g.setStrokeColor(PC.c(r.f() > 0.5 ? 0xFFFFFF : 0x000000, alpha * 0.8)); g.setLineWidth(0.5)
            g.move(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l)); g.strokePath()
        }
        g.restoreGState()
    }
    /// Standard gunmetal plate: gradient, brushed grain, top bevel highlight, dark outline.
    func plate(_ p: CGPath, tone: Int = 0, grunge gr: CGFloat = 0.12, seed: UInt64 = 5, outline: CGFloat = 1) {
        let his: [UInt32] = [0x39414A, 0x2B3138, 0x4A535E], los: [UInt32] = [0x14171B, 0x0D0F12, 0x20252B]
        let hi = his[tone], lo = los[tone]
        vgrad(p, [(0, PC.c(hi)), (0.5, PC.c(PC.s2)), (1, PC.c(lo))])
        brushed(p, alpha: 0.10, seed: seed)
        if gr > 0 { grunge(p, alpha: gr, seed: seed &+ 1) }
        g.saveGState(); g.addPath(p); g.clip()
        stroke(p, PC.c(0xFFFFFF, 0.22), 2.0)   // inner top rim (clipped half)
        g.restoreGState()
        if outline > 0 { stroke(p, PC.c(0x050607), outline) }
    }
    func hazard(_ p: CGPath, stripe: CGFloat = 14, c1: UInt32 = 0xF2B705, c2: UInt32 = 0x141414, alpha: CGFloat = 1, angle: CGFloat = 1) {
        g.saveGState(); g.addPath(p); g.clip()
        let b = p.boundingBoxOfPath
        g.setFillColor(PC.c(c2, alpha)); g.fill(b)
        g.setFillColor(PC.c(c1, alpha))
        var x = b.minX - b.height - stripe
        while x < b.maxX + stripe {
            let q = CGMutablePath()
            q.addLines(between: [CGPoint(x: x, y: b.maxY), CGPoint(x: x + stripe, y: b.maxY),
                                 CGPoint(x: x + stripe + b.height * angle, y: b.minY), CGPoint(x: x + b.height * angle, y: b.minY)])
            q.closeSubpath(); g.addPath(q); g.fillPath()
            x += stripe * 2
        }
        g.restoreGState()
    }
    func rivet(_ c: CGPoint, _ r: CGFloat = 3) {
        fill(circle(CGPoint(x: c.x, y: c.y + 0.6), r + 0.6), PC.c(0, 0.5))
        radial(CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35), 0, r * 1.2, [(0, PC.c(0xC8D0D9)), (0.55, PC.c(PC.s4)), (1, PC.c(PC.s1))], clip: circle(c, r))
        stroke(circle(c, r), PC.c(0, 0.6), 0.6)
    }
    func rivets(_ pts: [CGPoint], _ r: CGFloat = 3) { pts.forEach { rivet($0, r) } }
    func screw(_ c: CGPoint, _ r: CGFloat = 4) {
        rivet(c, r)
        stroke({ let p = CGMutablePath(); p.move(to: CGPoint(x: c.x - r * 0.6, y: c.y - r * 0.1)); p.addLine(to: CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.1)); return p }(), PC.c(0, 0.7), 0.9)
    }
    /// Thin accent line with glow.
    func accentLine(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat = 2, color: UInt32? = nil, glowR: CGFloat = 8) {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b)
        glowStroke(p, PC.c(color ?? self.a.primary), w, radius: glowR, core: PC.c(self.a.glow, 0.9))
    }
    func line(_ pts: [CGPoint], _ c: CGColor, _ w: CGFloat, closed: Bool = false, cap: CGLineCap = .butt) {
        let p = CGMutablePath(); p.addLines(between: pts); if closed { p.closeSubpath() }
        stroke(p, c, w, cap: cap)
    }
    func ticks(from a: CGPoint, to b: CGPoint, count: Int, len: CGFloat, color: CGColor, width: CGFloat = 1, longEvery: Int = 0) {
        let dx = b.x - a.x, dy = b.y - a.y, l = hypot(dx, dy); guard l > 0 else { return }
        let nx = -dy / l, ny = dx / l
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count); let k = (longEvery > 0 && i % longEvery == 0) ? 1.8 : 1
            let p = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            line([p, CGPoint(x: p.x + nx * len * k, y: p.y + ny * len * k)], color, width)
        }
    }

    // MARK: type
    func textWidth(_ s: String, font names: [String], size: CGFloat, track: CGFloat = 0) -> CGFloat {
        let l = ctLine(s, names, size, PC.white, track); return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    }
    func ctLine(_ s: String, _ names: [String], _ size: CGFloat, _ c: CGColor, _ track: CGFloat) -> CTLine {
        let f = PFont.make(names, size)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): c, .init(kCTKernAttributeName as String): track]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }
    /// Draws text vertically centred (by cap height) in `r`. Squeezes to fit width. Optional stencil cuts, glow, slant.
    func text(_ s: String, _ names: [String] = PFont.headline, size: CGFloat, color: CGColor = PC.white, in r: CGRect, align: Align = .center,
              track: CGFloat = 0, stencil: Bool = false, glow gl: CGColor? = nil, glowR: CGFloat = 8, slant: CGFloat = 0, shadow: Bool = false,
              gradient: (CGColor, CGColor)? = nil, outline: CGColor? = nil, outlineW: CGFloat = 2) {
        let line = ctLine(s, names, size, color, track)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - track
        let font = PFont.make(names, size); let cap = CTFontGetCapHeight(font)
        let sq = w > r.width && r.width > 0 ? r.width / w : 1
        let dw = w * sq
        let x0: CGFloat = align == .left ? r.minX : (align == .right ? r.maxX - dw : r.midX - dw / 2)
        let base = r.midY + cap / 2
        g.saveGState()
        g.translateBy(x: x0, y: base); g.scaleBy(x: sq, y: 1)
        g.concatenate(CGAffineTransform(a: 1, b: 0, c: -slant, d: 1, tx: 0, ty: 0))
        g.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        g.setShouldSmoothFonts(false)
        func drawLine(mode: CGTextDrawingMode = .fill) {
            g.setTextDrawingMode(mode); g.textPosition = .zero; CTLineDraw(line, g)
        }
        if let gl { g.setShadow(offset: .zero, blur: glowR * scale, color: gl) }
        else if shadow { g.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 4 * scale, color: PC.c(0, 0.7)) }
        let needLayer = stencil || gradient != nil || outline != nil
        if needLayer { g.beginTransparencyLayer(auxiliaryInfo: nil) }
        if let o = outline { g.setStrokeColor(o); g.setLineWidth(outlineW); g.setLineJoin(.round); drawLine(mode: .stroke) }
        drawLine()
        if gradient != nil || stencil { g.setShadow(offset: .zero, blur: 0, color: nil) }
        if let gr = gradient {
            g.setBlendMode(.sourceAtop)
            let grd = CGGradient(colorsSpace: PC.cs, colors: [gr.0, gr.1] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grd, start: CGPoint(x: 0, y: -cap), end: CGPoint(x: 0, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            g.setBlendMode(.normal)
        }
        if stencil {
            g.setBlendMode(.clear)
            let gap = max(1.2, size * 0.045)
            for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
                let n = CTRunGetGlyphCount(run); guard n > 0 else { continue }
                var pos = [CGPoint](repeating: .zero, count: n); CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                var gl = [CGGlyph](repeating: 0, count: n); CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gl)
                var adv = [CGSize](repeating: .zero, count: n)
                CTFontGetAdvancesForGlyphs(PFont.make(names, size), .horizontal, gl, &adv, n)
                for i in 0..<n where adv[i].width > size * 0.28 {
                    let cx = pos[i].x + adv[i].width / 2
                    g.fill(CGRect(x: cx - gap / 2, y: -cap - 2, width: gap, height: cap * 0.2 + 2))
                    g.fill(CGRect(x: cx - gap / 2, y: -cap * 0.2, width: gap, height: cap * 0.2 + 2))
                }
            }
            g.setBlendMode(.normal)
        }
        if needLayer { g.endTransparencyLayer() }
        g.restoreGState()
    }
    func tag(_ s: String, size: CGFloat, in r: CGRect, color: CGColor = PC.white, align: Align = .center, track: CGFloat = 1.5) {
        text(s, PFont.tag, size: size, color: color, in: r, align: align, track: track)
    }

    // MARK: fire
    func flameTongue(base: CGPoint, w: CGFloat, h: CGFloat, lean: CGFloat) -> CGPath {
        let p = CGMutablePath(); let tip = CGPoint(x: base.x + lean, y: base.y - h)
        p.move(to: CGPoint(x: base.x - w / 2, y: base.y))
        p.addCurve(to: tip, control1: CGPoint(x: base.x - w * 0.75, y: base.y - h * 0.38), control2: CGPoint(x: base.x - w * 0.12 + lean * 0.35, y: base.y - h * 0.72))
        p.addCurve(to: CGPoint(x: base.x + w / 2, y: base.y), control1: CGPoint(x: base.x + w * 0.38 + lean * 0.2, y: base.y - h * 0.55), control2: CGPoint(x: base.x + w * 0.8, y: base.y - h * 0.3))
        p.closeSubpath(); return p
    }
    /// A stylised flame: layered tongues, red outside -> white-yellow core, additive glow.
    func flame(base: CGPoint, width: CGFloat, height: CGFloat, seed: UInt64 = 1, tongues: Int = 5, palette: (outer: UInt32, mid: UInt32, inner: UInt32)? = nil, glowOn: Bool = true) {
        var r = PRNG(seed)
        let pal = palette ?? (a.hot, a.primary, a.glow)
        // soft glow halo
        if glowOn { radial(CGPoint(x: base.x, y: base.y - height * 0.4), 0, max(width, height) * 0.5, [(0, PC.c(pal.mid, 0.4)), (1, PC.c(pal.mid, 0))], clip: circle(CGPoint(x: base.x, y: base.y - height * 0.4), max(width, height) * 0.5)) }
        struct T { var x: CGFloat; var w: CGFloat; var h: CGFloat; var lean: CGFloat }
        var ts: [T] = []
        for i in 0..<tongues {
            let t = tongues == 1 ? 0.5 : CGFloat(i) / CGFloat(tongues - 1)
            let centre = 1 - abs(t - 0.5) * 2
            ts.append(T(x: base.x + (t - 0.5) * width * 0.7 + r.r(-3, 3), w: width * r.r(0.32, 0.5), h: height * (0.45 + 0.55 * centre) * r.r(0.85, 1.08), lean: (t - 0.5) * -width * 0.35 + r.r(-width * 0.1, width * 0.1)))
        }
        ts.sort { $0.h < $1.h }
        let layers: [(CGFloat, UInt32, CGFloat)] = [(1.0, pal.outer, 0.95), (0.74, pal.mid, 1.0), (0.46, pal.inner, 1.0), (0.2, 0xFFFFFF, 0.9)]
        for (k, l) in layers.enumerated() {
            for t in ts {
                let p = flameTongue(base: CGPoint(x: t.x, y: base.y), w: t.w * l.0, h: t.h * (0.35 + 0.65 * l.0), lean: t.lean * l.0)
                let top = base.y - t.h * l.0
                g.saveGState()
                if k >= 2 { g.setBlendMode(.plusLighter) }
                grad([(0, PC.c(l.1, 0)), (0.25, PC.c(l.1, l.2 * 0.85)), (0.82, PC.c(l.1, l.2)), (1, PC.c(l.1, k == 0 ? l.2 : 0.35))], CGPoint(x: t.x, y: top), CGPoint(x: t.x, y: base.y), clip: p)
                g.restoreGState()
            }
        }
    }
    func fireBed(_ rect: CGRect, count: Int, seed: UInt64 = 1, heightScale: CGFloat = 1) {
        var r = PRNG(seed)
        for i in 0..<count {
            let t = (CGFloat(i) + r.r(-0.3, 0.3)) / CGFloat(max(1, count - 1))
            let swell = 0.55 + 0.45 * sin(t * .pi * 3.1 + r.r(0, 2)) * sin(t * .pi * 1.2 + 0.6)
            let hh = rect.height * heightScale * max(0.3, swell) * r.r(0.7, 1.0)
            flame(base: CGPoint(x: rect.minX + t * rect.width, y: rect.maxY), width: rect.width / CGFloat(count) * r.r(1.6, 2.6), height: hh, seed: seed &+ UInt64(i) &* 13, tongues: 3, glowOn: false)
        }
    }
    func embers(_ rect: CGRect, count: Int, seed: UInt64 = 1, maxR: CGFloat = 3, bias: CGFloat = 1) {
        var r = PRNG(seed)
        g.saveGState(); g.setBlendMode(.plusLighter)
        for _ in 0..<count {
            let x = r.r(rect.minX, rect.maxX), y = rect.minY + pow(r.f(), bias) * rect.height
            let rad = r.r(0.6, maxR), hot = r.f() > 0.5
            radial(CGPoint(x: x, y: y), 0, rad * 6, [(0, PC.c(hot ? a.glow : a.primary, 0.9)), (0.25, PC.c(a.primary, 0.45)), (1, PC.c(a.hot, 0))])
        }
        g.restoreGState()
    }
    func sparks(_ origin: CGPoint, count: Int, length: CGFloat, spread: CGFloat = .pi, dir: CGFloat = -.pi / 2, seed: UInt64 = 1) {
        var r = PRNG(seed)
        g.saveGState(); g.setBlendMode(.plusLighter); g.setLineCap(.round)
        for _ in 0..<count {
            let ang = dir + r.r(-spread / 2, spread / 2), l = length * r.r(0.25, 1)
            let s = CGPoint(x: origin.x + cos(ang) * l * 0.15, y: origin.y + sin(ang) * l * 0.15)
            let e = CGPoint(x: origin.x + cos(ang) * l, y: origin.y + sin(ang) * l + l * l / length * 0.2)
            g.setStrokeColor(PC.c(a.glow, 0.9)); g.setLineWidth(r.r(0.7, 1.6))
            let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
            g.move(to: s); g.addLine(to: mid); g.strokePath()
            g.setStrokeColor(PC.c(a.primary, 0.5)); g.move(to: mid); g.addLine(to: e); g.strokePath()
        }
        g.restoreGState()
    }
}
