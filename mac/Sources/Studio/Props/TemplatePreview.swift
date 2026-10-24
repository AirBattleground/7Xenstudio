// Lightweight CoreGraphics renderer for LayerScene thumbnails / template previews (final animated state, placeholder sources).
// Not the engine: approximations only, used by the template gallery and for design review.
import Foundation
import CoreGraphics

enum TemplatePreview {
    static func hex(_ c: RGBA) -> UInt32 { (UInt32(max(0, min(1, c.r)) * 255) << 16) | (UInt32(max(0, min(1, c.g)) * 255) << 8) | UInt32(max(0, min(1, c.b)) * 255) }

    static func render(_ scene: LayerScene, variables: SceneVariables = .init(Templates.defaultVariables), width: Int = 1280) -> CGImage {
        let cw = Double(scene.canvas.w), ch = Double(scene.canvas.h)
        let sc = Double(width) / cw
        let pw = width, ph = Int((ch * sc).rounded())
        let g = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: PC.cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        g.translateBy(x: 0, y: CGFloat(ph)); g.scaleBy(x: CGFloat(sc), y: -CGFloat(sc))
        g.interpolationQuality = .high
        let theme = PropTheme.ember
        let bg = scene.background.color
        g.setFillColor(bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let c = PCtx(g: g, w: cw, h: ch, a: theme, scale: CGFloat(sc))
        var vars = variables; for (k, v) in scene.variableDefaults where vars[k] == nil { vars[k] = v }
        draw(scene.layers, c, vars, scene.variableDefaults)
        return g.makeImage()!
    }

    static func draw(_ layers: [Layer], _ c: PCtx, _ vars: SceneVariables, _ defs: [String: String]) {
        for l in layers where l.visible {
            if case .image(let s) = l.kind, let b = s.builtin, b.hasPrefix("stinger.") { continue }   // transient transition art
            let g = c.g
            g.saveGState()
            let r = l.transform.rect
            g.translateBy(x: r.midX, y: r.midY); g.rotate(by: CGFloat(l.transform.rotation * .pi / 180)); g.translateBy(x: -r.midX, y: -r.midY)
            g.setAlpha(CGFloat(l.opacity))
            if l.blend == .add || l.blend == .screen { g.setBlendMode(.plusLighter) }
            if l.mask.kind == .circle { g.addEllipse(in: r); g.clip() }
            else if l.mask.kind == .roundedRect { g.addPath(c.rrect(r, 16)); g.clip() }
            switch l.kind {
            case .image(let s): drawImage(s, r, c)
            case .shape(let s): drawShape(s, r, c)
            case .text(let t): drawText(t, r, c, vars, defs)
            case .source(let ref, _): drawSource(ref, r, c)
            case .effect(let e): drawEffect(e, r, c, vars, defs)
            case .teamBoard(let spec):
                if let img = TeamBoardArt.composite(spec, vars: vars, defaults: defs, w: max(8, Int(r.width)), h: max(8, Int(r.height))) {
                    g.saveGState(); g.translateBy(x: r.minX, y: r.maxY); g.scaleBy(x: 1, y: -1)
                    g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); g.restoreGState()
                }
            case .group(let ch):
                g.translateBy(x: r.minX, y: r.minY)
                g.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(ch, c, vars, defs)
                g.endTransparencyLayer()
            }
            g.restoreGState()
        }
    }

    static func drawImage(_ s: ImageSpec, _ r: CGRect, _ c: PCtx) {
        guard let id = s.builtin, let a = PropsCatalog.byID[id] else { return }
        let img = a.image(scale: 1, theme: PropTheme.named(s.theme ?? "ember"))
        var dst = r
        if s.fit != .stretch {
            let k = min(r.width / a.size.width, r.height / a.size.height)
            dst = CGRect(x: r.midX - a.size.width * k / 2, y: r.midY - a.size.height * k / 2, width: a.size.width * k, height: a.size.height * k)
        }
        c.g.saveGState(); c.g.translateBy(x: dst.minX, y: dst.maxY); c.g.scaleBy(x: 1, y: -1)
        c.g.draw(img, in: CGRect(x: 0, y: 0, width: dst.width, height: dst.height)); c.g.restoreGState()
    }

    static func drawShape(_ s: ShapeSpec, _ r: CGRect, _ c: PCtx) {
        let p: CGPath = s.kind == .ellipse ? CGPath(ellipseIn: r, transform: nil) : (s.kind == .roundedRect ? c.rrect(r, CGFloat(s.cornerRadius)) : CGPath(rect: r, transform: nil))
        if let gr = s.fill.gradient {
            let st = gr.stops.map { ($0.pos, $0.color.cgColor) }
            c.grad(st.map { (CGFloat($0.0), $0.1) }, CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), clip: p)
        } else { c.fill(p, s.fill.color.cgColor) }
        if s.stroke.width > 0 { c.stroke(p, s.stroke.color.cgColor, CGFloat(s.stroke.width)) }
    }

    static func drawText(_ t: TextStyle, _ r: CGRect, _ c: PCtx, _ vars: SceneVariables, _ defs: [String: String]) {
        var s = vars.resolve(t.string, defaults: defs); if t.allCaps { s = s.uppercased() }
        let grad = t.gradient.flatMap { g in g.stops.first.flatMap { f in g.stops.last.map { (f.color.cgColor, $0.color.cgColor) } } }
        let glow: CGColor? = t.shadow.isOn && t.shadow.color.a > 0.5 && (t.shadow.dy == 0) ? t.shadow.color.cgColor : nil
        let align: Align = t.alignment == .left ? .left : (t.alignment == .right ? .right : .center)
        c.text(s, [t.font, "Impact", "HelveticaNeue-Bold"], size: CGFloat(t.size), color: t.color.cgColor, in: r, align: align, track: CGFloat(t.tracking),
               glow: glow, glowR: CGFloat(t.shadow.blur), shadow: glow == nil && t.shadow.isOn, gradient: grad)
    }

    static func drawSource(_ ref: SourceRef, _ r: CGRect, _ c: PCtx) {
        c.g.saveGState(); c.g.addRect(r); c.g.clip()
        var label = "SOURCE"
        switch ref {
        case .slate:
            label = "GAMEPLAY"
            c.grad([(0, PC.c(0x3C5A66)), (0.55, PC.c(0x5B6E4A)), (1, PC.c(0x2A2C22))], CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY))
            var rg = PRNG(3); for _ in 0..<26 { c.fill(CGPath(rect: CGRect(x: rg.r(r.minX, r.maxX), y: r.minY + r.height * rg.r(0.45, 0.9), width: rg.r(30, 140), height: rg.r(20, 90)), transform: nil), PC.c(0x1A1E16, 0.5)) }
        case .camera:
            label = "CAM"
            c.grad([(0, PC.c(0x4A4F66)), (1, PC.c(0x22253A))], CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY))
            c.fill(c.circle(CGPoint(x: r.midX, y: r.minY + r.height * 0.42), min(r.width, r.height) * 0.17), PC.c(0x0A0B12, 0.55))
            c.fill(c.ell2(CGRect(x: r.midX - r.width * 0.3, y: r.minY + r.height * 0.62, width: r.width * 0.6, height: r.height * 0.55)), PC.c(0x0A0B12, 0.55))
        default:
            label = "PHONE"
            c.grad([(0, PC.c(0x405A52)), (1, PC.c(0x1E2A28))], CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY))
            var rg = PRNG(UInt64(r.minX) + 5); for _ in 0..<12 { c.fill(CGPath(rect: CGRect(x: rg.r(r.minX, r.maxX), y: rg.r(r.minY, r.maxY), width: 60, height: 40), transform: nil), PC.c(0, 0.25)) }
        }
        c.text(label, PFont.tag, size: min(60, r.height * 0.16), color: PC.c(0xFFFFFF, 0.28), in: r, track: 6)
        c.g.restoreGState()
    }

    static func drawEffect(_ e: EffectSpec, _ r: CGRect, _ c: PCtx, _ vars: SceneVariables, _ defs: [String: String]) {
        let th = PropTheme(id: "fx", name: "fx", primary: hex(e.color2.a > 0 && e.kind != .fireEmitter ? e.color2 : e.color2), hot: hex(e.color2), glow: hex(e.color))
        let ec = PCtx(g: c.g, w: c.w, h: c.h, a: th, scale: c.scale)
        switch e.kind {
        case .embers: ec.embers(r, count: min(300, e.count), seed: UInt64(e.seed), maxR: 3, bias: 1.4)
        case .fireEmitter:
            c.g.saveGState(); c.g.setBlendMode(.plusLighter); ec.fireBed(CGRect(x: r.minX, y: r.minY + r.height * 0.4, width: r.width, height: r.height * 0.6), count: 20, seed: UInt64(e.seed), heightScale: 1.2 * CGFloat(e.intensity)); c.g.restoreGState()
        case .smoke: ec.smoke(r, count: 24, seed: UInt64(e.seed), color: 0x9AA0A6, alpha: 0.16, size: 120...300)
        case .sparks: ec.sparks(CGPoint(x: r.midX, y: r.maxY), count: 60, length: r.height * 0.8, spread: 1.6, dir: -.pi / 2, seed: UInt64(e.seed))
        case .vignette: c.radial(CGPoint(x: r.midX, y: r.midY), r.height * 0.45, r.width * 0.65, [(0, PC.c(hex(e.color), 0)), (1, PC.c(hex(e.color), CGFloat(0.8 * e.intensity)))], clip: CGPath(rect: r, transform: nil))
        case .scanlines: for y in stride(from: r.minY, to: r.maxY, by: CGFloat(max(2, e.size))) { c.fill(CGPath(rect: CGRect(x: r.minX, y: y, width: r.width, height: 1.4), transform: nil), PC.c(0, 0.3)) }
        case .pulsingGlow: c.radial(CGPoint(x: r.midX, y: r.midY), r.height * 0.3, r.width * 0.6, [(0, PC.c(hex(e.color), 0)), (1, PC.c(hex(e.color), 0.4))], clip: CGPath(rect: r, transform: nil))
        case .animatedGradient: c.grad([(0, e.color.cgColor), (1, e.color2.cgColor)], CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.midX, y: r.minY), clip: CGPath(rect: r, transform: nil))
        case .hudCornerBrackets:
            let L = CGFloat(e.size), col = e.color.cgColor
            for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                c.line([CGPoint(x: x, y: y + sy * L), CGPoint(x: x, y: y), CGPoint(x: x + sx * L, y: y)], col, CGFloat(e.thickness)) }
        case .countdown, .ticker, .killfeedLine:
            let s = vars.resolve(e.text, defaults: defs)
            c.text(s, [TextPresets.monoFont, "Menlo-Bold"], size: CGFloat(e.fontSize), color: e.color.cgColor, in: r, glow: e.color2.cgColor, glowR: CGFloat(e.fontSize * 0.1))
        case .lightSweep, .glitch, .filmGrain, .lightning, .radarSweep: break
        }
    }
}
extension PCtx { func ell2(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) } }
