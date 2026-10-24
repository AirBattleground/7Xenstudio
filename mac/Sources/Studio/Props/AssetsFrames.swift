import Foundation
import CoreGraphics

extension PCtx {
    /// Plate ring with inner accent edge, soft inner shadow and corner rivets.
    func frameRing(outer: CGPath, inner: CGPath, rivetsAt: [CGPoint] = [], accent: Bool = true, tone: Int = 0, seed: UInt64 = 11) {
        let ring = ringPath(outer, inner)
        g.saveGState(); g.setShadow(offset: .zero, blur: 22 * scale, color: PC.c(0, 0.85))
        fill(ring, PC.c(PC.s2), evenOdd: true); g.restoreGState()
        g.saveGState(); g.addPath(ring); g.clip(using: .evenOdd)
        plate(outer, tone: tone, seed: seed); g.restoreGState()
        // hollow out any plate overdraw in the hole
        g.saveGState(); g.addPath(inner); g.setBlendMode(.clear); g.fillPath(); g.restoreGState()
        stroke(outer, PC.c(0xFFFFFF, 0.16), 1)
        if accent { glowStroke(inner, PC.c(a.primary), 1.6, radius: 7, core: PC.c(a.glow, 0.7)) }
        rivets(rivetsAt, 2.6)
    }
}

func frameAssets() -> [BuiltinAsset] {
    let C = PropCategory.frames
    var out: [BuiltinAsset] = []

    out.append(asset("frame.cornercut", "Corner-Cut Tech Frame", C, 640, 360, tags: ["gameplay", "cam", "angular"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 628, height: 348), 34, 10, 34, 10)
        let i = c.chamfer(CGRect(x: 24, y: 24, width: 592, height: 312), 22, 4, 22, 4)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 16, y: 40), CGPoint(x: 624, y: 320), CGPoint(x: 624, y: 40), CGPoint(x: 16, y: 320)])
        c.accentLine(CGPoint(x: 40, y: 15), CGPoint(x: 200, y: 15), 2.2)
        c.accentLine(CGPoint(x: 440, y: 345), CGPoint(x: 600, y: 345), 2.2)
        c.hazard(c.rrect(CGRect(x: 210, y: 11, width: 60, height: 8), 1), stripe: 6, alpha: 0.9)
    })
    out.append(asset("frame.double", "Double-Line Frame", C, 640, 360, tags: ["thin", "clean"]) { c in
        let o = c.chamfer(CGRect(x: 8, y: 8, width: 624, height: 344), 26, 6, 26, 6)
        let i = c.chamfer(CGRect(x: 20, y: 20, width: 600, height: 320), 18, 2, 18, 2)
        c.g.saveGState(); c.setGlow(PC.c(0, 0.8), 16)
        c.stroke(o, PC.c(PC.s3), 5); c.g.restoreGState()
        c.stroke(o, PC.c(PC.s4), 1.2); c.stroke(c.chamfer(CGRect(x: 12, y: 12, width: 616, height: 336), 22, 4, 22, 4), PC.c(PC.s1), 3)
        c.glowStroke(i, PC.c(c.a.primary), 2, radius: 8, core: PC.c(c.a.glow, 0.8))
        for p in [CGPoint(x: 30, y: 8), CGPoint(x: 610, y: 352)] { c.fill(c.poly([p, CGPoint(x: p.x + 46, y: p.y), CGPoint(x: p.x + 36, y: p.y + 6 * (p.y < 100 ? 1 : -1)), CGPoint(x: p.x + 6, y: p.y + 6 * (p.y < 100 ? 1 : -1))]), PC.c(c.a.primary)) }
    })
    out.append(asset("frame.hazard", "Hazard Stripe Frame", C, 640, 360, tags: ["warning", "construction"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 628, height: 348), 24, 6, 24, 6)
        let i = c.chamfer(CGRect(x: 30, y: 30, width: 580, height: 300), 14, 2, 14, 2)
        c.frameRing(outer: o, inner: i, accent: false)
        let top = c.chamfer(CGRect(x: 6, y: 6, width: 628, height: 18), 12, 3, 12, 3)
        let bot = c.chamfer(CGRect(x: 6, y: 336, width: 628, height: 18), 3, 12, 3, 12)
        for s in [top, bot] { c.hazard(s, stripe: 12, alpha: 0.95); c.stroke(s, PC.c(0, 0.8), 1) }
        c.innerShadow(top, blur: 4, alpha: 0.5, dy: 1)
        c.glowStroke(i, PC.c(c.a.hot), 1.6, radius: 6)
        c.rivets([CGPoint(x: 17, y: 180), CGPoint(x: 623, y: 180)], 3)
    })
    out.append(asset("frame.ember", "Ember Glow Frame", C, 640, 360, tags: ["fire", "glow", "hot"]) { c in
        let o = c.chamfer(CGRect(x: 8, y: 8, width: 624, height: 344), 28, 8, 28, 8)
        let i = c.chamfer(CGRect(x: 22, y: 22, width: 596, height: 316), 20, 4, 20, 4)
        c.frameRing(outer: o, inner: i, tone: 1)
        c.glowStroke(o, PC.c(c.a.hot), 2.5, radius: 14, core: PC.c(c.a.primary))
        c.fireBed(CGRect(x: 30, y: 300, width: 580, height: 58), count: 18, seed: 5, heightScale: 1.6)
        c.embers(CGRect(x: 20, y: 250, width: 600, height: 110), count: 26, seed: 9, maxR: 2.2, bias: 0.6)
        c.glowStroke(i, PC.c(c.a.primary), 2, radius: 10, core: PC.c(c.a.glow))
    })
    out.append(asset("frame.bracket", "Military Bracket Frame", C, 640, 360, tags: ["bracket", "minimal", "corners"]) { c in
        let col = PC.c(c.a.primary), L: CGFloat = 70, t: CGFloat = 5
        func corner(_ x: CGFloat, _ y: CGFloat, _ sx: CGFloat, _ sy: CGFloat) {
            let p = c.poly([CGPoint(x: x, y: y), CGPoint(x: x + sx * L, y: y), CGPoint(x: x + sx * (L - t * 1.4), y: y + sy * t),
                            CGPoint(x: x + sx * t, y: y + sy * t), CGPoint(x: x + sx * t, y: y + sy * (L - t * 1.4)), CGPoint(x: x, y: y + sy * L)])
            c.g.saveGState(); c.setGlow(col, 10); c.fill(p, col); c.g.restoreGState()
            c.fill(p, col)
            c.line([CGPoint(x: x + sx * 14, y: y + sy * 14), CGPoint(x: x + sx * 14, y: y + sy * 30)], PC.c(c.a.glow, 0.8), 1.5)
            c.line([CGPoint(x: x + sx * 14, y: y + sy * 14), CGPoint(x: x + sx * 30, y: y + sy * 14)], PC.c(c.a.glow, 0.8), 1.5)
        }
        corner(8, 8, 1, 1); corner(632, 8, -1, 1); corner(8, 352, 1, -1); corner(632, 352, -1, -1)
        c.ticks(from: CGPoint(x: 120, y: 8), to: CGPoint(x: 520, y: 8), count: 40, len: 4, color: PC.c(0xFFFFFF, 0.35), longEvery: 5)
        c.ticks(from: CGPoint(x: 520, y: 352), to: CGPoint(x: 120, y: 352), count: 40, len: 4, color: PC.c(0xFFFFFF, 0.35), longEvery: 5)
    })
    out.append(asset("frame.hex", "Hex-Cut Frame", C, 640, 360, tags: ["hex", "hexagon"]) { c in
        let o = c.hexagon(CGRect(x: 6, y: 6, width: 628, height: 348), cut: 44)
        let i = c.hexagon(CGRect(x: 24, y: 24, width: 592, height: 312), cut: 34)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 70, y: 15), CGPoint(x: 570, y: 15), CGPoint(x: 70, y: 345), CGPoint(x: 570, y: 345)])
        c.accentLine(CGPoint(x: 6, y: 150), CGPoint(x: 6, y: 210), 3)
        c.accentLine(CGPoint(x: 634, y: 150), CGPoint(x: 634, y: 210), 3)
    })
    out.append(asset("frame.parallelogram", "Parallelogram Cam Frame", C, 640, 360, tags: ["cam", "slant", "esports"]) { c in
        let o = c.para(CGRect(x: 6, y: 6, width: 628, height: 348), skew: 60)
        let i = c.para(CGRect(x: 26, y: 22, width: 592, height: 316), skew: 52)
        c.frameRing(outer: o, inner: i)
        c.fill(c.poly([66, 6, 150, 6, 142, 20, 58, 20]), PC.c(c.a.primary))
        c.fill(c.poly([490, 340, 574, 340, 568, 354, 484, 354]), PC.c(c.a.hot))
    })
    out.append(asset("frame.circle", "Circle Cam Ring", C, 420, 420, tags: ["cam", "round", "circle"]) { c in
        let ctr = CGPoint(x: 210, y: 210)
        let o = c.circle(ctr, 204), i = c.circle(ctr, 176)
        c.frameRing(outer: o, inner: i, accent: false)
        c.glowStroke(i, PC.c(c.a.primary), 2, radius: 8, core: PC.c(c.a.glow, 0.7))
        // segmented accent arcs
        for k in 0..<4 {
            let p = CGMutablePath(); let a0 = CGFloat(k) * .pi / 2 + 0.25
            p.addArc(center: ctr, radius: 190, startAngle: a0, endAngle: a0 + 0.9, clockwise: false)
            c.stroke(p, PC.c(k % 2 == 0 ? c.a.primary : c.a.hot), 5, cap: .butt)
        }
        for k in 0..<24 { let a = CGFloat(k) * .pi / 12
            c.line([CGPoint(x: 210 + cos(a) * 180, y: 210 + sin(a) * 180), CGPoint(x: 210 + cos(a) * 186, y: 210 + sin(a) * 186)], PC.c(0, 0.5), 1.4) }
        c.rivets([CGPoint(x: 210, y: 197 - 193 + 205 - 9), CGPoint(x: 210, y: 420 - 14)].map { $0 }, 3)
    })
    out.append(asset("frame.cam43", "Angular Cam 4:3", C, 480, 360, tags: ["cam", "facecam", "4:3"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 468, height: 348), 30, 6, 30, 6)
        let i = c.chamfer(CGRect(x: 22, y: 22, width: 436, height: 316), 20, 2, 20, 2)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 14, y: 34), CGPoint(x: 466, y: 326)])
        c.fill(c.poly([30, 340, 190, 340, 176, 354, 20, 354]), PC.c(c.a.primary))
        c.fill(c.poly([200, 340, 230, 340, 216, 354, 186, 354]), PC.c(c.a.hot))
    })
    out.append(asset("frame.camtab", "Cam Frame With Name Tab", C, 480, 400, tags: ["cam", "nameplate", "facecam"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 468, height: 340), 30, 6, 6, 6)
        let i = c.chamfer(CGRect(x: 22, y: 22, width: 436, height: 308), 20, 2, 2, 2)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 14, y: 34)])
        let tab = c.chamfer(CGRect(x: 22, y: 330, width: 330, height: 58), 0, 0, 22, 0)
        c.dropShadow(tab, PC.c(PC.s2), dy: 3)
        c.plate(tab, tone: 1)
        c.fill(c.poly([22, 330, 30, 330, 30, 388, 22, 388]), PC.c(c.a.primary))
        c.fill(c.rrect(CGRect(x: 360, y: 330, width: 98, height: 16), 2), PC.c(c.a.primary))
        c.hazard(c.rrect(CGRect(x: 360, y: 350, width: 98, height: 10), 2), stripe: 7, alpha: 0.85)
    })
    out.append(asset("frame.phone", "Phone Portrait Frame", C, 360, 640, tags: ["phone", "portrait", "9:16", "squad"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 348, height: 628), 28, 8, 28, 8)
        let i = c.chamfer(CGRect(x: 22, y: 22, width: 316, height: 596), 20, 4, 20, 4)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 14, y: 40), CGPoint(x: 346, y: 600)])
        c.accentLine(CGPoint(x: 40, y: 14), CGPoint(x: 130, y: 14), 2.5)
        c.accentLine(CGPoint(x: 230, y: 626), CGPoint(x: 320, y: 626), 2.5)
    })
    out.append(asset("frame.screen", "Full-Screen Tech Border", C, 1920, 1080, tags: ["fullscreen", "gameplay", "border"], maxScale: 1) { c in
        let o = c.rect.insetBy(dx: 10, dy: 10)
        let col = PC.c(c.a.primary)
        let p = c.chamfer(o, 54, 20, 54, 20)
        c.g.saveGState(); c.setGlow(col, 16); c.stroke(p, PC.c(c.a.hot, 0.9), 3); c.g.restoreGState()
        c.stroke(c.chamfer(o.insetBy(dx: 10, dy: 10), 46, 14, 46, 14), PC.c(0xFFFFFF, 0.18), 1.2)
        for (x, y, sx, sy) in [(10.0, 10.0, 1.0, 1.0), (1910.0, 1070.0, -1.0, -1.0)] {
            let q = c.poly([CGPoint(x: x, y: y + sy * 54), CGPoint(x: x + sx * 54, y: y), CGPoint(x: x + sx * 260, y: y), CGPoint(x: x + sx * 242, y: y + sy * 12), CGPoint(x: x + sx * 62, y: y + sy * 12), CGPoint(x: x + sx * 12, y: y + sy * 62)])
            c.glowFill(q, col, radius: 12)
        }
        c.hazard(c.rrect(CGRect(x: 960 - 100, y: 6, width: 200, height: 10), 2), stripe: 9, alpha: 0.9)
        c.hazard(c.rrect(CGRect(x: 960 - 100, y: 1064, width: 200, height: 10), 2), stripe: 9, alpha: 0.9)
        c.ticks(from: CGPoint(x: 14, y: 360), to: CGPoint(x: 14, y: 720), count: 36, len: 6, color: PC.c(0xFFFFFF, 0.3), longEvery: 6)
        c.ticks(from: CGPoint(x: 1906, y: 360), to: CGPoint(x: 1906, y: 720), count: 36, len: -6, color: PC.c(0xFFFFFF, 0.3), longEvery: 6)
        c.radial(CGPoint(x: 960, y: 540), 520, 1150, [(0, PC.c(0, 0)), (1, PC.c(0, 0.35))])
    })
    out.append(asset("frame.notch", "Top-Notch Frame", C, 640, 360, tags: ["notch", "title"]) { c in
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 8, y: 30), CGPoint(x: 8, y: 340), CGPoint(x: 632, y: 340), CGPoint(x: 632, y: 30), CGPoint(x: 400, y: 30), CGPoint(x: 384, y: 10), CGPoint(x: 256, y: 10), CGPoint(x: 240, y: 30)]); p.closeSubpath()
        let i = c.chamfer(CGRect(x: 22, y: 44, width: 596, height: 282), 8, 8, 8, 8)
        c.frameRing(outer: p, inner: i)
        c.fill(c.poly([262, 14, 378, 14, 372, 22, 268, 22]), PC.c(c.a.primary))
    })
    out.append(asset("frame.glitch", "Glitch Slice Frame", C, 640, 360, tags: ["glitch", "digital"]) { c in
        let o = c.chamfer(CGRect(x: 8, y: 8, width: 624, height: 344), 20, 20, 20, 20)
        let i = c.chamfer(CGRect(x: 20, y: 20, width: 600, height: 320), 12, 12, 12, 12)
        c.frameRing(outer: o, inner: i, accent: false, tone: 1)
        var r = PRNG(21)
        c.g.saveGState(); c.g.addPath(c.ringPath(o, i)); c.g.clip(using: .evenOdd)
        for _ in 0..<9 {
            let y = r.r(6, 340), h = r.r(2, 9), dx = r.r(-26, 26), x = r.r(0, 560), w = r.r(14, 60)
            c.g.setFillColor(PC.c(r.f() > 0.5 ? c.a.primary : c.a.hot, 0.95)); c.g.fill(CGRect(x: x + dx, y: y, width: w, height: h))
            c.g.setFillColor(PC.c(0x00E5FF, 0.6)); c.g.fill(CGRect(x: x + dx - 5, y: y + 1, width: w, height: h * 0.4))
        }
        c.g.restoreGState()
        c.glowStroke(i, PC.c(c.a.primary), 1.6, radius: 6)
    })
    return out
}
