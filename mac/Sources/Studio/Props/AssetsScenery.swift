import Foundation
import CoreGraphics

extension PCtx {
    /// Per-pixel noise written into a bitmap then drawn scaled (resolution independent, fast).
    func noise(_ rect: CGRect, px: Int = 960, seed: UInt64 = 1, _ f: (inout PRNG, Int, Int) -> (UInt8, UInt8)) {
        let pw = px, ph = max(1, Int(CGFloat(px) * rect.height / rect.width))
        var buf = [UInt8](repeating: 0, count: pw * ph * 4); var r = PRNG(seed)
        for y in 0..<ph { for x in 0..<pw { let (v, a) = f(&r, x, y); let o = (y * pw + x) * 4
            let pa = UInt8(UInt16(v) * UInt16(a) / 255); buf[o] = pa; buf[o + 1] = pa; buf[o + 2] = pa; buf[o + 3] = a } }
        let img: CGImage? = buf.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4, space: PC.cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage() }
        if let img { g.saveGState(); g.interpolationQuality = .medium; g.translateBy(x: rect.minX, y: rect.maxY); g.scaleBy(x: 1, y: -1); g.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height)); g.restoreGState() }
    }
    func smoke(_ rect: CGRect, count: Int, seed: UInt64, color: UInt32 = 0xB0B6BC, alpha: CGFloat = 0.12, size: ClosedRange<CGFloat> = 80...260) {
        var r = PRNG(seed)
        for _ in 0..<count { let x = r.r(rect.minX, rect.maxX), y = r.r(rect.minY, rect.maxY), rad = r.r(size.lowerBound, size.upperBound)
            g.saveGState(); g.translateBy(x: x, y: y); g.scaleBy(x: r.r(1.2, 2.4), y: 1)
            radial(.zero, 0, rad, [(0, PC.c(color, alpha * r.r(0.4, 1))), (1, PC.c(color, 0))]); g.restoreGState() }
    }
    func skyline(_ y0: CGFloat, maxH: CGFloat, seed: UInt64, color: CGColor, ruined: Bool = false, step: ClosedRange<CGFloat> = 30...90, windows: CGColor? = nil) {
        var r = PRNG(seed); var x: CGFloat = -20
        let m = CGMutablePath(); m.move(to: CGPoint(x: -20, y: h + 10))
        var wins: [CGRect] = []
        while x < w + 40 {
            let bw = r.r(step.lowerBound, step.upperBound), bh = r.r(maxH * 0.25, maxH)
            if ruined {
                let n = Int(bw / 12) + 2; var cx = x
                m.addLine(to: CGPoint(x: x, y: y0 - bh * 0.3))
                for _ in 0..<n { cx += bw / CGFloat(n); m.addLine(to: CGPoint(x: cx, y: y0 - bh * r.r(0.55, 1))) }
                m.addLine(to: CGPoint(x: x + bw, y: y0 - bh * 0.3))
            } else { m.addLine(to: CGPoint(x: x, y: y0 - bh)); m.addLine(to: CGPoint(x: x + bw, y: y0 - bh)) }
            if windows != nil { for wy in stride(from: y0 - bh + 14, to: y0 - 8, by: 20) { for wx in stride(from: x + 8, to: x + bw - 10, by: 16) where r.f() > 0.78 { wins.append(CGRect(x: wx, y: wy, width: 6, height: 9)) } } }
            x += bw + r.r(0, 8)
        }
        m.addLine(to: CGPoint(x: w + 40, y: h + 10)); m.closeSubpath(); fill(m, color)
        if let wc = windows { g.setFillColor(wc); wins.forEach { g.fill($0) } }
    }
    func sky(_ stops: [(CGFloat, UInt32)]) { grad(stops.map { ($0.0, PC.c($0.1)) }, .zero, CGPoint(x: 0, y: h)) }
}

func textureAssets() -> [BuiltinAsset] {
    let C = PropCategory.textures
    var o: [BuiltinAsset] = []
    let big: (String, String, [String], @escaping @Sendable (PCtx) -> Void, Bool) -> Void = { id, name, tags, f, themed in
        o.append(asset("tex." + id, name, C, 1920, 1080, tags: tags, maxScale: 1, themed: themed, f)) }
    big("scratches", "Scratches Overlay", ["scratch", "grunge", "wear"], { c in
        var r = PRNG(8); c.g.setLineCap(.round)
        for _ in 0..<420 { let x = r.r(0, 1920), y = r.r(0, 1080), l = r.r(20, 260), a = r.r(-0.6, 0.6) + (r.f() > 0.5 ? 0 : .pi / 2)
            c.g.setStrokeColor(PC.c(0xFFFFFF, r.r(0.04, 0.3))); c.g.setLineWidth(r.r(0.4, 1.4))
            let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y)); p.addQuadCurve(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l), control: CGPoint(x: x + cos(a) * l / 2 + r.r(-8, 8), y: y + sin(a) * l / 2 + r.r(-8, 8))); c.g.addPath(p); c.g.strokePath() } }, false)
    big("grain", "Film Grain", ["grain", "noise", "film"], { c in c.noise(c.rect, px: 960, seed: 2) { r, _, _ in (r.f() > 0.5 ? 255 : 0, UInt8(r.r(0, 40))) } }, false)
    big("scanlines", "Scanlines", ["scanlines", "crt", "retro"], { c in
        for y in stride(from: 0.0, to: 1080.0, by: 4.0) { c.fill(c.rc(0, y, 1920, 1.6), PC.c(0, 0.32)) }
        c.grad([(0, PC.c(0xFFFFFF, 0)), (0.5, PC.c(0xFFFFFF, 0.04)), (1, PC.c(0xFFFFFF, 0))], CGPoint(x: 0, y: 300), CGPoint(x: 0, y: 700)) }, false)
    big("vignette", "Vignette", ["vignette", "dark edges"], { c in c.radial(CGPoint(x: 960, y: 540), 380, 1150, [(0, PC.c(0, 0)), (1, PC.c(0, 0.82))]) }, false)
    big("vignette.hot", "Danger Vignette", ["vignette", "danger", "red", "final circle"], { c in
        c.radial(CGPoint(x: 960, y: 540), 360, 1100, [(0, PC.c(c.a.hot, 0)), (0.6, PC.c(c.a.hot, 0.22)), (1, PC.c(c.a.hot, 0.75))]) }, true)
    big("dust", "Dust & Specks", ["dust", "particles", "grunge"], { c in
        var r = PRNG(15); for _ in 0..<900 { let rad = r.r(0.5, 2.6); c.fill(c.circle(CGPoint(x: r.r(0, 1920), y: r.r(0, 1080)), rad), PC.c(0xFFFFFF, r.r(0.05, 0.5))) }
        for _ in 0..<40 { c.radial(CGPoint(x: r.r(0, 1920), y: r.r(0, 1080)), 0, r.r(6, 16), [(0, PC.c(0xFFFFFF, 0.25)), (1, PC.c(0xFFFFFF, 0))]) } }, false)
    big("smoke", "Smoke Wisps", ["smoke", "fog", "haze"], { c in c.smoke(c.rect, count: 46, seed: 4, alpha: 0.2) }, false)
    big("sparks", "Spark Streaks", ["sparks", "embers", "fire"], { c in
        c.sparks(CGPoint(x: 400, y: 1080), count: 90, length: 760, spread: 1.4, dir: -1.2, seed: 2); c.sparks(CGPoint(x: 1500, y: 1080), count: 90, length: 820, spread: 1.6, dir: -1.9, seed: 5) }, true)
    big("lightleak", "Light Leak", ["light leak", "warm", "flare"], { c in
        c.g.setBlendMode(.plusLighter)
        c.radial(CGPoint(x: 1900, y: 40), 0, 900, [(0, PC.c(c.a.glow, 0.55)), (0.4, PC.c(c.a.primary, 0.25)), (1, PC.c(c.a.hot, 0))])
        c.radial(CGPoint(x: 0, y: 1100), 0, 700, [(0, PC.c(c.a.primary, 0.4)), (1, PC.c(c.a.hot, 0))]) }, true)
    o.append(asset("tex.hazardtape", "Hazard Tape", C, 1920, 90, tags: ["hazard", "tape", "stripe", "warning"], maxScale: 1) { c in
        let p = c.rc(0, 8, 1920, 74); c.hazard(p, stripe: 38, c1: c.a.primary, alpha: 1); c.grunge(p, alpha: 0.3, seed: 2); c.line([CGPoint(x: 0, y: 8), CGPoint(x: 1920, y: 8)], PC.c(0, 0.5), 2); c.line([CGPoint(x: 0, y: 82), CGPoint(x: 1920, y: 82)], PC.c(0, 0.5), 2) })
    o.append(asset("tex.camo", "Camo Pattern", C, 512, 512, tags: ["camo", "pattern", "tile", "military"], themed: false) { c in
        c.fill(c.rc(0, 0, 512, 512), PC.c(0x3C4630)); var r = PRNG(31)
        for (col, n) in [(0x586340, 26), (0x2A3220, 22), (0x7A7650, 14), (0x181C12, 16)] as [(UInt32, Int)] {
            for _ in 0..<n { let x = r.r(0, 512), y = r.r(0, 512), w = r.r(40, 130), h = r.r(24, 70)
                for dx in [-512.0, 0, 512] { for dy in [-512.0, 0, 512] where x + dx > -140 && x + dx < 640 && y + dy > -100 && y + dy < 600 {
                    let p = CGMutablePath(); p.move(to: CGPoint(x: x + dx, y: y + dy + h * 0.5))
                    p.addCurve(to: CGPoint(x: x + dx + w, y: y + dy + h * 0.4), control1: CGPoint(x: x + dx + w * 0.2, y: y + dy - h * 0.3), control2: CGPoint(x: x + dx + w * 0.7, y: y + dy - h * 0.2))
                    p.addCurve(to: CGPoint(x: x + dx, y: y + dy + h * 0.5), control1: CGPoint(x: x + dx + w * 1.1, y: y + dy + h), control2: CGPoint(x: x + dx + w * 0.3, y: y + dy + h * 1.1)); c.fill(p, PC.c(col)) } } } } })
    o.append(asset("tex.carbon", "Carbon Fibre", C, 256, 256, tags: ["carbon", "fibre", "pattern", "tile"], themed: false) { c in
        c.fill(c.rc(0, 0, 256, 256), PC.c(0x0E1013))
        for gy in 0..<32 { for gx in 0..<32 { let x = CGFloat(gx) * 8, y = CGFloat(gy) * 8, horiz = (gx + gy) % 2 == 0
            let r = c.rc(x, y, 8, 8)
            if horiz { c.grad([(0, PC.c(0x2A3036)), (0.5, PC.c(0x0A0C0E)), (1, PC.c(0x22272C))], CGPoint(x: x, y: y), CGPoint(x: x, y: y + 8), clip: r) }
            else { c.grad([(0, PC.c(0x2A3036)), (0.5, PC.c(0x0A0C0E)), (1, PC.c(0x22272C))], CGPoint(x: x, y: y), CGPoint(x: x + 8, y: y), clip: r) } } } })
    big("grid", "Tactical Grid", ["grid", "tactical", "map"], { c in
        for x in stride(from: 0.0, through: 1920.0, by: 60.0) { c.fill(c.rc(x, 0, 1, 1080), PC.c(0xFFFFFF, Int(x) % 300 == 0 ? 0.22 : 0.09)) }
        for y in stride(from: 0.0, through: 1080.0, by: 60.0) { c.fill(c.rc(0, y, 1920, 1), PC.c(0xFFFFFF, Int(y) % 300 == 0 ? 0.22 : 0.09)) }
        for x in stride(from: 0.0, through: 1920.0, by: 300.0) { for y in stride(from: 0.0, through: 1080.0, by: 300.0) { c.line([CGPoint(x: x - 8, y: y), CGPoint(x: x + 8, y: y)], PC.c(0xFFFFFF, 0.5), 1.4); c.line([CGPoint(x: x, y: y - 8), CGPoint(x: x, y: y + 8)], PC.c(0xFFFFFF, 0.5), 1.4) } } }, false)
    big("halftone", "Halftone Dots", ["halftone", "dots", "pattern"], { c in
        for y in stride(from: 0.0, to: 1080.0, by: 14.0) { for x in stride(from: 0.0, to: 1920.0, by: 14.0) { let d = hypot(x - 960, y - 540) / 1100
            c.fill(c.circle(CGPoint(x: x + (Int(y / 14) % 2 == 0 ? 0 : 7), y: y), 0.6 + 3.8 * d), PC.c(0, 0.55 * min(1, d * 1.4))) } } }, false)
    return o
}

func backgroundAssets() -> [BuiltinAsset] {
    let C = PropCategory.backgrounds
    var o: [BuiltinAsset] = []
    func bg(_ id: String, _ name: String, _ tags: [String], themed: Bool = true, _ f: @escaping @Sendable (PCtx) -> Void) {
        o.append(asset("bg." + id, name, C, 1920, 1080, tags: tags + ["background"], maxScale: 1, themed: themed, f)) }
    bg("dusk", "Battlefield Dusk", ["dusk", "skyline", "sunset", "war"]) { c in
        c.sky([(0, 0x0D0F1A), (0.45, 0x3A1E2A), (0.7, c.a.hot), (0.85, c.a.primary), (1, 0xFFB050)].map { ($0.0, $0.1) })
        c.radial(CGPoint(x: 1300, y: 760), 0, 520, [(0, PC.c(c.a.glow, 0.9)), (0.2, PC.c(c.a.primary, 0.5)), (1, PC.c(c.a.hot, 0))], additive: true)
        c.fill(c.circle(CGPoint(x: 1300, y: 760), 70), PC.c(c.a.glow, 0.95))
        c.smoke(CGRect(x: 0, y: 300, width: 1920, height: 400), count: 26, seed: 3, color: 0x1A1416, alpha: 0.5, size: 120...320)
        c.skyline(870, maxH: 260, seed: 4, color: PC.c(0x241618), ruined: true, step: 40...110)
        c.skyline(960, maxH: 300, seed: 9, color: PC.c(0x0C0A0C), ruined: true, step: 50...130, windows: PC.c(c.a.primary, 0.6))
        c.embers(CGRect(x: 0, y: 300, width: 1920, height: 780), count: 90, seed: 6, maxR: 2.2, bias: 1.4)
        c.radial(CGPoint(x: 960, y: 540), 520, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.6))]) }
    bg("ember", "Ember Field", ["ember", "fire", "sparks", "hot"]) { c in
        c.sky([(0, 0x07080A), (0.6, 0x1A0C0A), (1, 0x4A1408)].map { ($0.0, $0.1) })
        c.radial(CGPoint(x: 960, y: 1200), 0, 1100, [(0, PC.c(c.a.hot, 0.75)), (0.5, PC.c(c.a.hot, 0.2)), (1, PC.c(c.a.hot, 0))], additive: true)
        c.embers(c.rect, count: 340, seed: 8, maxR: 3.2, bias: 1.8); c.smoke(CGRect(x: 0, y: 500, width: 1920, height: 580), count: 18, seed: 5, color: 0x6A4A40, alpha: 0.12)
        c.radial(CGPoint(x: 960, y: 540), 560, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.55))]) }
    bg("smokefire", "Smoke & Fire", ["smoke", "fire", "gradient", "inferno"]) { c in
        c.sky([(0, 0x0A0B0D), (0.5, 0x23272C), (0.8, 0x3A1A12), (1, 0x7A2A0A)].map { ($0.0, $0.1) })
        c.smoke(c.rect, count: 40, seed: 12, color: 0x8A9096, alpha: 0.18, size: 140...380)
        c.g.saveGState(); c.g.setBlendMode(.plusLighter); c.fireBed(CGRect(x: -40, y: 780, width: 2000, height: 330), count: 26, seed: 3, heightScale: 1.1); c.g.restoreGState()
        c.embers(CGRect(x: 0, y: 200, width: 1920, height: 880), count: 120, seed: 4, maxR: 2.6, bias: 1.5)
        c.radial(CGPoint(x: 960, y: 540), 560, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.55))]) }
    bg("desert", "Desert Battleground", ["desert", "dunes", "sand", "miramar"]) { c in
        c.sky([(0, 0x3A6A9A), (0.5, 0xE8B070), (0.75, 0xF4D49A), (1, 0xC89050)].map { ($0.0, $0.1) })
        c.radial(CGPoint(x: 1500, y: 320), 0, 500, [(0, PC.c(0xFFF4D0, 0.9)), (1, PC.c(0xFFF4D0, 0))], additive: true)
        for (k, (y, col)) in [(640.0, 0xC69458), (730.0, 0xA87440), (840.0, 0x835530), (960.0, 0x5A3A20)].enumerated() {
            let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: 1080)); var x = 0.0
            while x <= 1920 { p.addLine(to: CGPoint(x: x, y: y + sin(x / 210 + CGFloat(k) * 1.7) * 46 + sin(x / 83 + CGFloat(k)) * 12)); x += 20 }
            p.addLine(to: CGPoint(x: 1920, y: 1080)); p.closeSubpath(); c.fill(p, PC.c(UInt32(col))) }
        c.skyline(700, maxH: 120, seed: 21, color: PC.c(0x6A4A30, 0.8), ruined: true, step: 30...70)
        c.radial(CGPoint(x: 960, y: 540), 600, 1200, [(0, PC.c(0, 0)), (1, PC.c(0, 0.45))]) }
    bg("ruins", "Urban Ruins", ["ruins", "city", "urban", "erangel", "silhouette"], themed: true) { c in
        c.sky([(0, 0x14181E), (0.6, 0x3A4048), (1, 0x7A8088)].map { ($0.0, $0.1) })
        c.smoke(CGRect(x: 0, y: 300, width: 1920, height: 600), count: 30, seed: 7, color: 0xC8CED4, alpha: 0.22, size: 140...320)
        c.skyline(800, maxH: 380, seed: 33, color: PC.c(0x2A3036), ruined: true, step: 50...120)
        c.skyline(900, maxH: 460, seed: 44, color: PC.c(0x14181C), ruined: true, step: 60...140, windows: PC.c(c.a.primary, 0.35))
        c.skyline(1010, maxH: 300, seed: 55, color: PC.c(0x07080A), ruined: true, step: 40...100)
        c.radial(CGPoint(x: 700, y: 1000), 0, 600, [(0, PC.c(c.a.primary, 0.25)), (1, PC.c(c.a.primary, 0))], additive: true)
        c.radial(CGPoint(x: 960, y: 540), 560, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.6))]) }
    bg("tactical", "Tactical Map Grid", ["tactical", "map", "grid", "blueprint"]) { c in
        c.sky([(0, 0x10161A), (1, 0x0A0E11)].map { ($0.0, $0.1) })
        for x in stride(from: 0.0, through: 1920.0, by: 48.0) { c.fill(c.rc(x, 0, 1, 1080), PC.c(c.a.primary, Int(x) % 240 == 0 ? 0.3 : 0.1)) }
        for y in stride(from: 0.0, through: 1080.0, by: 48.0) { c.fill(c.rc(0, y, 1920, 1), PC.c(c.a.primary, Int(y) % 240 == 0 ? 0.3 : 0.1)) }
        for (x, y, r) in [(1300.0, 420.0, 330.0), (1300.0, 420.0, 200.0), (1300.0, 420.0, 80.0)] { c.stroke(c.circle(CGPoint(x: x, y: y), r), PC.c(c.a.primary, 0.4), 1.5) }
        c.stroke(c.circle(CGPoint(x: 760, y: 640), 260), PC.c(c.a.hot, 0.55), 3)
        var r = PRNG(7); let p = CGMutablePath(); p.move(to: CGPoint(x: -20, y: 800)); var x = 0.0; var y = 800.0; while x < 1960 { x += 80; y += r.r(-70, 60); p.addLine(to: CGPoint(x: x, y: max(300, min(1000, y)))) }
        c.stroke(p, PC.c(c.a.primary, 0.35), 2)
        c.radial(CGPoint(x: 960, y: 540), 500, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.6))]) }
    bg("gunmetal", "Gunmetal Plate", ["metal", "brushed", "steel", "plate"], themed: true) { c in
        let r = c.rect; let p = CGPath(rect: r, transform: nil)
        c.vgrad(p, [(0, PC.c(0x2E343B)), (0.5, PC.c(0x1A1E23)), (1, PC.c(0x0E1013))]); c.brushed(p, alpha: 0.07, seed: 5); c.grunge(p, alpha: 0.12, seed: 8, density: 0.8)
        for (x, y) in [(40.0, 40.0), (1880.0, 40.0), (40.0, 1040.0), (1880.0, 1040.0)] { c.screw(CGPoint(x: x, y: y), 9) }
        c.hazard(c.rc(0, 0, 1920, 14), stripe: 18); c.hazard(c.rc(0, 1066, 1920, 14), stripe: 18)
        c.radial(CGPoint(x: 960, y: 480), 200, 1200, [(0, PC.c(0, 0)), (1, PC.c(0, 0.6))]) }
    bg("nightraid", "Night Raid", ["night", "raid", "dark", "searchlight"]) { c in
        c.sky([(0, 0x04060A), (0.7, 0x0E1620), (1, 0x1A2630)].map { ($0.0, $0.1) })
        for (x, a) in [(520.0, -0.2), (1400.0, 0.25)] as [(CGFloat, CGFloat)] { c.g.saveGState(); c.g.setBlendMode(.plusLighter); c.g.translateBy(x: x, y: 1100); c.g.rotate(by: a)
            c.grad([(0, PC.c(0xDDEEFF, 0.4)), (1, PC.c(0xDDEEFF, 0))], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -1100), clip: c.poly([-18, 0, 18, 0, 120, -1100, -120, -1100])); c.g.restoreGState() }
        c.smoke(CGRect(x: 0, y: 500, width: 1920, height: 500), count: 20, seed: 9, color: 0x8AA0B0, alpha: 0.12)
        c.skyline(960, maxH: 340, seed: 61, color: PC.c(0x050709), ruined: true, step: 50...120, windows: PC.c(c.a.primary, 0.5))
        c.radial(CGPoint(x: 960, y: 540), 560, 1180, [(0, PC.c(0, 0)), (1, PC.c(0, 0.6))]) }
    bg("hex", "Hex Armor Pattern", ["hex", "pattern", "honeycomb", "tech"]) { c in
        c.sky([(0, 0x1A1E23), (1, 0x08090B)].map { ($0.0, $0.1) })
        let s: CGFloat = 64
        for row in 0..<20 { for col in 0..<18 { let cx = CGFloat(col) * s * 1.75 + (row % 2 == 0 ? 0 : s * 0.875), cy = CGFloat(row) * s * 0.76
            let p = CGMutablePath(); for k in 0..<6 { let a = CGFloat(k) * .pi / 3 + .pi / 6; let pt = CGPoint(x: cx + cos(a) * s * 0.52, y: cy + sin(a) * s * 0.52); k == 0 ? p.move(to: pt) : p.addLine(to: pt) }; p.closeSubpath()
            let d = hypot(cx - 960, cy - 540) / 1100; c.stroke(p, PC.c(c.a.primary, 0.05 + 0.2 * d), 1.2) } }
        c.radial(CGPoint(x: 960, y: 540), 0, 700, [(0, PC.c(c.a.primary, 0.18)), (1, PC.c(c.a.primary, 0))], additive: true) }
    return o
}

func fireAssets() -> [BuiltinAsset] {
    let C = PropCategory.fire
    var o: [BuiltinAsset] = []
    o.append(asset("fire.flame", "Flame", C, 400, 520, tags: ["fire", "flame", "burn"]) { c in c.flame(base: CGPoint(x: 200, y: 500), width: 300, height: 440, seed: 4, tongues: 5) })
    o.append(asset("fire.flame.small", "Small Flame", C, 200, 280, tags: ["fire", "flame", "candle"]) { c in c.flame(base: CGPoint(x: 100, y: 270), width: 140, height: 220, seed: 9, tongues: 3) })
    o.append(asset("fire.flame.blue", "Blue Flame", C, 400, 520, tags: ["fire", "flame", "blue", "plasma"]) { c in c.flame(base: CGPoint(x: 200, y: 500), width: 300, height: 440, seed: 4, tongues: 5, palette: (0x1E55FF, 0x35B6FF, 0xBFF0FF)) })
    o.append(asset("fire.bed", "Fire Bed", C, 1400, 360, tags: ["fire", "line", "bottom", "wall"]) { c in c.fireBed(CGRect(x: 20, y: 40, width: 1360, height: 310), count: 22, seed: 7) })
    o.append(asset("fire.bed.top", "Fire Edge (Top)", C, 1400, 360, tags: ["fire", "edge", "top"]) { c in
        c.g.translateBy(x: 0, y: 360); c.g.scaleBy(x: 1, y: -1); c.fireBed(CGRect(x: 20, y: 40, width: 1360, height: 310), count: 22, seed: 11) })
    o.append(asset("fire.embers", "Ember Cloud", C, 800, 800, tags: ["embers", "sparks", "particles"]) { c in c.embers(c.rect, count: 140, seed: 3, maxR: 3.4, bias: 1.2) })
    o.append(asset("fire.sparkburst", "Spark Burst", C, 600, 600, tags: ["sparks", "burst", "impact"]) { c in
        c.sparks(CGPoint(x: 300, y: 300), count: 70, length: 280, spread: 6.28, dir: 0, seed: 3); c.radial(CGPoint(x: 300, y: 300), 0, 90, [(0, PC.c(0xFFFFFF, 0.9)), (0.3, PC.c(c.a.glow, 0.6)), (1, PC.c(c.a.hot, 0))], additive: true) })
    o.append(asset("fire.fireball", "Fireball", C, 500, 500, tags: ["fireball", "explosion", "boom"]) { c in
        c.radial(CGPoint(x: 250, y: 250), 0, 240, [(0, PC.c(0xFFFFFF, 1)), (0.18, PC.c(c.a.glow, 1)), (0.45, PC.c(c.a.primary, 0.9)), (0.75, PC.c(c.a.hot, 0.55)), (1, PC.c(c.a.hot, 0))])
        var r = PRNG(2); for i in 0..<9 { let a = CGFloat(i) * .pi * 2 / 9 + r.r(-0.2, 0.2); c.flame(base: CGPoint(x: 250 + cos(a) * 60, y: 250 + sin(a) * 60), width: 150, height: 230, seed: UInt64(i) + 5, tongues: 3, glowOn: false) } })
    o.append(asset("fire.ring", "Flame Ring", C, 640, 640, tags: ["fire", "ring", "circle", "cam"]) { c in
        var r = PRNG(6); let m = CGPoint(x: 320, y: 320)
        for i in 0..<28 { let a = CGFloat(i) / 28 * .pi * 2; c.g.saveGState(); c.g.translateBy(x: m.x + cos(a) * 210, y: m.y + sin(a) * 210); c.g.rotate(by: a + .pi / 2)
            c.flame(base: .zero, width: 78, height: r.r(70, 120), seed: UInt64(i) * 7 + 1, tongues: 2, glowOn: false); c.g.restoreGState() }
        c.stroke(c.circle(m, 206), PC.c(c.a.hot, 0.9), 6) })
    o.append(asset("fire.explosion", "Explosion Burst", C, 640, 640, tags: ["explosion", "boom", "impact", "blast"]) { c in
        let m = CGPoint(x: 320, y: 320); var r = PRNG(9)
        c.smoke(CGRect(x: 120, y: 120, width: 400, height: 400), count: 24, seed: 4, color: 0x2A2E33, alpha: 0.5, size: 60...150)
        for i in 0..<16 { let a = CGFloat(i) / 16 * .pi * 2; let l = r.r(150, 300); let p = c.poly([CGPoint(x: m.x + cos(a - 0.14) * 40, y: m.y + sin(a - 0.14) * 40), CGPoint(x: m.x + cos(a) * l, y: m.y + sin(a) * l), CGPoint(x: m.x + cos(a + 0.14) * 40, y: m.y + sin(a + 0.14) * 40)])
            c.grad([(0, PC.c(c.a.glow)), (0.5, PC.c(c.a.primary, 0.9)), (1, PC.c(c.a.hot, 0))], m, CGPoint(x: m.x + cos(a) * l, y: m.y + sin(a) * l), clip: p) }
        c.radial(m, 0, 130, [(0, PC.c(0xFFFFFF)), (0.4, PC.c(c.a.glow)), (1, PC.c(c.a.primary, 0))]); c.sparks(m, count: 40, length: 300, spread: 6.28, dir: 0, seed: 7) })
    o.append(asset("fire.logoflame", "Flame Emblem", C, 360, 420, tags: ["emblem", "logo", "flame", "badge"]) { c in
        let p = c.flameTongue(base: CGPoint(x: 180, y: 380), w: 260, h: 340, lean: 20)
        c.M(p, c.a.glow, c.a.hot, outline: 3); c.flame(base: CGPoint(x: 180, y: 360), width: 140, height: 220, seed: 3, tongues: 3, glowOn: false)
        c.stroke(c.ringPath(c.circle(CGPoint(x: 180, y: 220), 0), c.circle(CGPoint(x: 180, y: 220), 0)), PC.c(0, 0), 0) })
    o.append(asset("fire.smokeplume", "Smoke Plume", C, 500, 800, tags: ["smoke", "plume", "column"], themed: false) { c in
        c.smoke(CGRect(x: 120, y: 80, width: 260, height: 700), count: 60, seed: 11, color: 0xA8AEB4, alpha: 0.28, size: 40...120) })
    return o
}

func stingerAssets() -> [BuiltinAsset] {
    let C = PropCategory.stingers
    var o: [BuiltinAsset] = []
    o.append(asset("stinger.firewipe", "Fire Wipe", C, 3840, 1080, tags: ["fire", "wipe", "transition", "stinger"], maxScale: 1) { c in
        // left half solid cover, right edge flames; template slides it across the screen
        c.grad([(0, PC.c(0x050607)), (0.8, PC.c(0x1A0A06)), (1, PC.c(c.a.hot, 0.9))], .zero, CGPoint(x: 2500, y: 0), clip: c.rc(0, 0, 2500, 1080))
        c.g.saveGState(); c.g.translateBy(x: 3200, y: 0); c.g.rotate(by: .pi / 2)
        c.fireBed(CGRect(x: 0, y: 0, width: 1080, height: 700), count: 14, seed: 4, heightScale: 1.0); c.g.restoreGState()
        c.embers(CGRect(x: 2200, y: 0, width: 1640, height: 1080), count: 220, seed: 5, maxR: 3, bias: 0.7) })
    o.append(asset("stinger.glitch", "Glitch Slice", C, 1920, 1080, tags: ["glitch", "transition", "digital"], maxScale: 1) { c in
        var r = PRNG(14)
        for _ in 0..<46 { let y = r.r(0, 1060), h = r.r(8, 70), x = r.r(-200, 1500), w = r.r(300, 1100)
            let col = r.f() > 0.55 ? c.a.primary : (r.f() > 0.5 ? c.a.hot : 0x00E5FF)
            c.g.setFillColor(PC.c(col, r.r(0.5, 0.95))); c.g.fill(CGRect(x: x, y: y, width: w, height: h))
            c.g.setFillColor(PC.c(0x0A0C0E, 0.9)); c.g.fill(CGRect(x: x + r.r(40, 200), y: y + h * 0.3, width: w * 0.5, height: h * 0.4)) } })
    o.append(asset("stinger.smokesweep", "Smoke Sweep", C, 3840, 1080, tags: ["smoke", "sweep", "transition"], maxScale: 1, themed: false) { c in
        c.grad([(0, PC.c(0x0E1013)), (0.55, PC.c(0x0E1013)), (1, PC.c(0x0E1013, 0))], .zero, CGPoint(x: 2600, y: 0), clip: c.rc(0, 0, 2600, 1080))
        c.smoke(CGRect(x: 1800, y: 0, width: 2000, height: 1080), count: 80, seed: 3, color: 0x9AA0A6, alpha: 0.3, size: 140...380) })
    o.append(asset("stinger.slash", "Slash Bars", C, 1920, 1080, tags: ["slash", "diagonal", "transition", "wipe"], maxScale: 1) { c in
        for (i, col) in [c.a.hot, c.a.primary, 0x14171B, c.a.glow].enumerated() { let x = CGFloat(i) * 170 - 100
            c.glowFill(c.poly([x + 420, 0, x + 700, 0, x + 280, 1080, x, 1080]), PC.c(col), radius: i == 2 ? 0 : 20) }
        c.hazard(c.poly([1300, 0, 1920, 0, 1920, 1080, 880, 1080]), stripe: 40, alpha: 0.9) })
    return o
}
