import Foundation
import CoreGraphics

enum GunKind { case ar, sniper, smg, shotgun, pistol }

extension PCtx {
    /// Run `body` in a 0...100 local square placed at `box`.
    func local(_ box: CGRect, _ body: () -> Void) {
        g.saveGState(); g.translateBy(x: box.minX, y: box.minY); g.scaleBy(x: box.width / 100, y: box.height / 100); body(); g.restoreGState()
    }
    func ell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: x, y: y, width: w, height: h), transform: nil) }
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 2) -> CGPath { rrect(CGRect(x: x, y: y, width: w, height: h), r) }
    func rc(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath { CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil) }
    func union(_ ps: [CGPath]) -> CGPath { let m = CGMutablePath(); ps.forEach { m.addPath($0) }; return m }
    /// Material fill used by all icons: shadow, vertical gradient, sheen, dark outline, top rim light.
    func M(_ p: CGPath, _ hi: UInt32, _ lo: UInt32, outline: CGFloat = 1.2, shadow: Bool = true, sheen: CGFloat = 0.22, evenOdd: Bool = false) {
        if shadow { g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -2.2 * scale), blur: 5 * scale, color: PC.c(0, 0.55)); fill(p, PC.c(lo), evenOdd: evenOdd); g.restoreGState() }
        vgrad(p, [(0, PC.c(hi)), (1, PC.c(lo))], evenOdd: evenOdd)
        if sheen > 0 {
            let b = p.boundingBoxOfPath
            g.saveGState(); g.addPath(p); g.clip(using: evenOdd ? .evenOdd : .winding)
            grad([(0, PC.c(0xFFFFFF, sheen)), (0.5, PC.c(0xFFFFFF, 0)), (1, PC.c(0, 0.12))], CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)); g.restoreGState()
        }
        if outline > 0 { stroke(p, PC.c(0x050607, 0.85), outline, join: .round) }
        g.saveGState(); g.addPath(p); g.clip(using: evenOdd ? .evenOdd : .winding)
        let b = p.boundingBoxOfPath
        g.setStrokeColor(PC.c(0xFFFFFF, 0.28)); g.setLineWidth(1.0); g.move(to: CGPoint(x: b.minX, y: b.minY + 0.8)); g.addLine(to: CGPoint(x: b.maxX, y: b.minY + 0.8)); g.strokePath()
        g.restoreGState()
    }
}

func gunPath(_ c: PCtx, _ k: GunKind) -> CGPath {
    // 100 x 40 local space, muzzle to the right.
    switch k {
    case .ar:
        return c.union([c.poly([0, 13, 14, 12, 27, 14, 27, 26, 14, 28, 6, 31, 0, 27]), c.rc(26, 11, 34, 14), c.rc(58, 13, 29, 9), c.rc(86, 15, 10, 3.2), c.rc(95, 13.5, 5, 6.2),
                        c.poly([40, 25, 51, 25, 49, 39, 38, 37]), c.poly([29, 25, 37, 25, 35, 37, 28, 37]), c.rc(34, 7, 22, 4.5), c.rc(80, 9, 3.2, 6), c.rc(28, 9, 5, 3)])
    case .sniper:
        return c.union([c.poly([0, 12, 22, 12, 28, 14, 28, 27, 14, 28, 6, 30, 0, 26]), c.rc(26, 14, 28, 9), c.rc(52, 16, 48, 3.4), c.rc(96, 14.8, 4, 5.8),
                        c.rc(22, 5, 46, 5), c.rc(26, 9, 4, 5), c.rc(60, 9, 4, 7), c.rc(20, 3.5, 4, 8), c.rc(66, 3.5, 4, 8), c.poly([38, 23, 46, 23, 45, 33, 38, 33]), c.poly([56, 19, 80, 19, 90, 38, 87, 38, 77, 21, 56, 21])])
    case .smg:
        return c.union([c.poly([0, 14, 12, 13, 16, 15, 16, 24, 8, 24, 0, 20]), c.rc(14, 11, 44, 13), c.rc(56, 13.5, 14, 6), c.rc(69, 14.5, 12, 3.4), c.poly([32, 24, 40, 24, 40, 40, 31, 40]), c.poly([20, 24, 28, 24, 26, 35, 19, 35]), c.rc(20, 8, 22, 4), c.rc(62, 8, 3.2, 6)])
    case .shotgun:
        return c.union([c.poly([0, 13, 18, 12, 36, 15, 36, 24, 18, 30, 5, 35, 0, 31]), c.rc(34, 14, 24, 9), c.rc(56, 14.5, 44, 4), c.rc(40, 19.5, 50, 4), c.rc(62, 20, 20, 7.2), c.rc(92, 12.5, 3, 3), c.poly([42, 23, 50, 23, 48, 32, 41, 32])])
    case .pistol:
        return c.union([c.rc(14, 12, 74, 10), c.poly([14, 22, 30, 22, 34, 24, 34, 28, 22, 28, 20, 40, 8, 40, 14, 22]), c.rc(86, 14, 10, 6), c.rc(26, 8, 4, 4), c.rc(80, 8, 4, 4)])
    }
}
func drawGun(_ c: PCtx, kind: GunKind, box: CGRect, color: CGColor) {
    c.g.saveGState(); c.g.translateBy(x: box.minX, y: box.minY); c.g.scaleBy(x: box.width / 100, y: box.height / 40)
    c.fill(gunPath(c, kind), color); c.g.restoreGState()
}
func skullPath(_ c: PCtx) -> CGPath {
    let m = CGMutablePath()
    m.addPath(c.ell(18, 8, 64, 62)); m.addPath(c.rr(32, 58, 36, 30, 6))
    return m
}
func drawSkull(_ c: PCtx, center: CGPoint, size: CGFloat, color: CGColor) {
    c.local(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)) {
        c.fill(skullPath(c), color)
        c.g.saveGState(); c.g.setBlendMode(.clear)
        c.g.addPath(c.ell(26, 36, 20, 20)); c.g.addPath(c.ell(54, 36, 20, 20)); c.g.addPath(c.poly([50, 54, 44, 66, 56, 66])); c.g.fillPath()
        for x in [41.0, 49.0, 57.0] { c.g.addPath(c.rc(x - 1.2, 72, 2.4, 14)) }; c.g.fillPath()
        c.g.restoreGState()
    }
}
func drawHelmet(_ c: PCtx, center: CGPoint, size: CGFloat, level: Int) {
    c.local(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)) { helmetArt(c, level) }
}
private let levelHi: [UInt32] = [0xAEB6BF, 0x74B8FF, 0xFFD060], levelLo: [UInt32] = [0x4A525C, 0x1F5FB0, 0xB8700C]
func helmetArt(_ c: PCtx, _ level: Int) {
    let L = max(1, min(3, level)) - 1
    let hi = levelHi[L], lo = levelLo[L]
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 12, y: 60)); p.addCurve(to: CGPoint(x: 50, y: 14), control1: CGPoint(x: 12, y: 30), control2: CGPoint(x: 28, y: 14))
    p.addCurve(to: CGPoint(x: 88, y: 60), control1: CGPoint(x: 72, y: 14), control2: CGPoint(x: 88, y: 30)); p.closeSubpath()
    c.M(c.rr(6, 56, 88, 11, 5), hi, lo)
    c.M(p, hi, lo)
    c.g.saveGState(); c.g.addPath(p); c.g.clip()
    for k in 1...4 { let q = CGMutablePath(); q.addArc(center: CGPoint(x: 50, y: 62), radius: CGFloat(k) * 11, startAngle: .pi, endAngle: 0, clockwise: false); c.stroke(q, PC.c(0, 0.18), 1) }
    c.fill(c.rc(48.5, 10, 3, 50), PC.c(0, 0.2))
    c.g.restoreGState()
    if L >= 1 { c.M(c.poly([44, 20, 56, 20, 58, 38, 42, 38]), 0xFFFFFF, 0xC9D2DC, shadow: false, sheen: 0.1) }
    if L >= 2 { c.M(c.poly([50, 6, 58, 18, 50, 24, 42, 18]), 0xFFE9A0, 0xE08A00, shadow: false); c.fill(c.ell(46, 38, 8, 8), PC.c(0xE5261B)) }
    c.M(c.poly([20, 67, 28, 67, 30, 86, 22, 86]), 0x3A3F46, 0x15181B, shadow: false); c.M(c.poly([72, 67, 80, 67, 78, 86, 70, 86]), 0x3A3F46, 0x15181B, shadow: false)
    c.M(c.rr(36, 80, 28, 10, 3), 0x59626D, 0x1E2227, shadow: false)
    c.fill(c.ell(47, 82, 6, 6), PC.c(c.a.primary))
}
private func packArt(_ c: PCtx, _ level: Int) {
    let L = level - 1
    let hi = levelHi[L], lo = levelLo[L]
    c.M(c.rr(22, 20, 56, 70, 14), hi, lo)                         // body
    c.M(c.rr(16, 50, 10, 30, 4), hi, lo, shadow: false); c.M(c.rr(74, 50, 10, 30, 4), hi, lo, shadow: false)  // side pockets
    let flap = CGMutablePath(); flap.move(to: CGPoint(x: 22, y: 36)); flap.addCurve(to: CGPoint(x: 78, y: 36), control1: CGPoint(x: 30, y: 6), control2: CGPoint(x: 70, y: 6)); flap.addLine(to: CGPoint(x: 78, y: 48)); flap.addLine(to: CGPoint(x: 22, y: 48)); flap.closeSubpath()
    c.M(flap, hi, lo, shadow: false)
    c.M(c.rr(32, 58, 36, 24, 5), lo, 0x15181B, shadow: false); c.line([CGPoint(x: 32, y: 66), CGPoint(x: 68, y: 66)], PC.c(0, 0.4), 1)
    c.M(c.rr(44, 42, 12, 10, 2), 0xC9D2DC, 0x59626D, shadow: false)
    c.line([CGPoint(x: 30, y: 38), CGPoint(x: 30, y: 52)], PC.c(0, 0.5), 2.2); c.line([CGPoint(x: 70, y: 38), CGPoint(x: 70, y: 52)], PC.c(0, 0.5), 2.2)
    if level >= 2 { c.fill(c.rc(22, 54, 56, 3), PC.c(c.a.primary)) }
    if level >= 3 { c.fill(c.rc(22, 54, 56, 3), PC.c(c.a.glow)); c.fill(c.rc(22, 84, 56, 3), PC.c(c.a.glow)) }
}
private func gren(_ c: PCtx, kind: Int) {   // 0 frag, 1 smoke, 2 flash
    switch kind {
    case 0:
        c.M(c.ell(22, 28, 56, 64), 0x7C8A58, 0x2A3320)
        c.g.saveGState(); c.g.addPath(c.ell(22, 28, 56, 64)); c.g.clip()
        for k in 1..<5 { c.line([CGPoint(x: 22, y: 28 + CGFloat(k) * 13), CGPoint(x: 78, y: 28 + CGFloat(k) * 13)], PC.c(0, 0.35), 1.1); c.line([CGPoint(x: 22 + CGFloat(k) * 11, y: 28), CGPoint(x: 22 + CGFloat(k) * 11, y: 92)], PC.c(0, 0.3), 1.1) }
        c.g.restoreGState()
        c.M(c.rr(38, 16, 24, 14, 3), 0x8C96A0, 0x3A4048, shadow: false)
        let lever = CGMutablePath(); lever.move(to: CGPoint(x: 58, y: 18)); lever.addCurve(to: CGPoint(x: 80, y: 36), control1: CGPoint(x: 76, y: 14), control2: CGPoint(x: 82, y: 26)); lever.addLine(to: CGPoint(x: 74, y: 56)); lever.addLine(to: CGPoint(x: 70, y: 54)); lever.addLine(to: CGPoint(x: 74, y: 36)); lever.addCurve(to: CGPoint(x: 56, y: 24), control1: CGPoint(x: 72, y: 28), control2: CGPoint(x: 64, y: 24)); lever.closeSubpath()
        c.M(lever, 0xB8C0C8, 0x59626D, shadow: false)
        c.stroke(c.ell(28, 6, 18, 14), PC.c(0xC9D2DC), 2.6)
    case 1:
        c.M(c.rr(30, 28, 40, 62, 8), 0x9AA3AD, 0x3A4048); c.M(c.rc(30, 52, 40, 10), 0xFFFFFF, 0xBFC6CE, shadow: false)
        c.M(c.rr(32, 20, 36, 12, 3), 0x59626D, 0x23282E, shadow: false); c.M(c.rr(44, 12, 12, 10, 2), 0x8C96A0, 0x3A4048, shadow: false)
        for (x, y, r) in [(42.0, 8.0, 10.0), (56.0, 4.0, 12.0), (68.0, 12.0, 8.0)] { c.fill(c.circle(CGPoint(x: x, y: y), r), PC.c(0xDDE3EA, 0.6)) }
    default:
        c.M(c.rr(30, 24, 40, 66, 8), 0xE8D060, 0x8A6A10); c.M(c.rc(30, 46, 40, 10), 0x2A2E34, 0x14171B, shadow: false); c.fill(c.rc(30, 62, 40, 4), PC.c(0x14171B))
        c.M(c.rr(32, 16, 36, 12, 3), 0x59626D, 0x23282E, shadow: false)
        c.g.saveGState(); c.g.setBlendMode(.plusLighter)
        for k in 0..<8 { let a = CGFloat(k) * .pi / 4; c.line([CGPoint(x: 50 + cos(a) * 12, y: 8 + sin(a) * 12), CGPoint(x: 50 + cos(a) * 22, y: 8 + sin(a) * 22)], PC.c(0xFFF2A0, 0.8), 2.4, cap: .round) }; c.g.restoreGState()
    }
}
private func bulletsArt(_ c: PCtx, caliber: Int) {
    let cfg: [(w: CGFloat, h: CGFloat, brass: Bool, tip: UInt32, n: Int)] = [(10, 56, true, 0x4C8A3C, 3), (13, 66, true, 0x3C7AD0, 3), (14, 40, true, 0xB8602A, 3), (16, 50, false, 0xE5261B, 2)]
    let k = cfg[caliber]
    let total = CGFloat(k.n) * k.w + CGFloat(k.n - 1) * 5, x0 = 50 - total / 2
    for i in 0..<k.n { c.local(CGRect(x: 0, y: 0, width: 100, height: 100)) {
        c.g.saveGState(); c.g.setShadow(offset: CGSize(width: 0, height: -2 * c.scale), blur: 4 * c.scale, color: PC.c(0, 0.5))
        c.bullet(x: x0 + CGFloat(i) * (k.w + 5), y: 50 - k.h / 2 - 4 + CGFloat(i % 2) * 4, w: k.w, h: k.h, brass: k.brass, tip: k.tip); c.g.restoreGState() } }
}
private func vehicle(_ c: PCtx, _ k: Int) {   // 0 jeep, 1 bike, 2 boat, 3 plane
    switch k {
    case 0:
        let body = c.union([c.poly([8, 52, 14, 40, 30, 38, 36, 26, 66, 26, 72, 38, 90, 42, 94, 54, 94, 64, 8, 64]), c.rc(34, 20, 4, 8), c.rc(62, 20, 4, 8)])
        c.M(body, 0x7C8A58, 0x2A3320)
        c.M(c.poly([40, 29, 64, 29, 69, 38, 36, 38]), 0x9FD0E8, 0x3A5F78, shadow: false)
        c.line([CGPoint(x: 8, y: 54), CGPoint(x: 94, y: 54)], PC.c(0, 0.35), 1)
        c.fill(c.rc(16, 48, 6, 6), PC.c(0xFFD060)); c.fill(c.rc(86, 46, 6, 6), PC.c(0xFFD060))
        for x in [28.0, 76.0] { c.M(c.circle(CGPoint(x: x, y: 66), 12), 0x3A3F46, 0x0D0F12); c.M(c.circle(CGPoint(x: x, y: 66), 5.5), 0xC9D2DC, 0x59626D, shadow: false) }
    case 1:
        for x in [24.0, 78.0] { c.stroke(c.circle(CGPoint(x: x, y: 66), 14), PC.c(0x15181B), 5.5); c.stroke(c.circle(CGPoint(x: x, y: 66), 14), PC.c(PC.s4), 1.2); c.fill(c.circle(CGPoint(x: x, y: 66), 3), PC.c(PC.s6)) }
        let tank = c.union([c.poly([36, 36, 60, 34, 62, 44, 38, 48])])
        c.M(c.poly([24, 66, 40, 50, 52, 52, 58, 66, 66, 66, 62, 52, 70, 44, 78, 66, 76, 68, 70, 54, 64, 62, 56, 70, 40, 66]), 0x59626D, 0x1E2227, outline: 1)
        c.M(tank, c.a.primary, c.a.hot, outline: 1); c.M(c.poly([40, 32, 54, 31, 56, 37, 40, 39]), 0x2A2E34, 0x0D0F12, shadow: false)
        c.line([CGPoint(x: 66, y: 44), CGPoint(x: 74, y: 30), CGPoint(x: 84, y: 28)], PC.c(0x15181B), 3.2); c.line([CGPoint(x: 74, y: 30), CGPoint(x: 70, y: 24)], PC.c(PC.s6), 2.2)
        c.M(c.rr(44, 58, 12, 8, 2), 0xA3AEBB, 0x3A4048, shadow: false)
    case 2:
        let hull = c.poly([6, 52, 94, 48, 82, 74, 24, 76])
        c.M(hull, 0x8C96A0, 0x2A3036)
        c.fill(c.poly([8, 54, 92, 50, 90, 56, 10, 60]), PC.c(c.a.primary))
        c.M(c.poly([36, 50, 44, 32, 64, 32, 70, 50]), 0xDDE3EA, 0x59626D, shadow: false); c.M(c.poly([42, 48, 47, 36, 62, 36, 66, 48]), 0x9FD0E8, 0x3A5F78, shadow: false)
        c.line([CGPoint(x: 6, y: 82), CGPoint(x: 94, y: 80)], PC.c(0x9FD0E8, 0.55), 2.2); c.line([CGPoint(x: 18, y: 88), CGPoint(x: 70, y: 87)], PC.c(0x9FD0E8, 0.35), 1.6)
        c.M(c.rr(80, 40, 6, 10, 2), 0x59626D, 0x1E2227, shadow: false)
    default:
        let body = c.union([c.poly([4, 50, 20, 44, 78, 44, 96, 50, 78, 56, 20, 56]), c.poly([40, 46, 60, 46, 46, 14, 36, 14]), c.poly([40, 54, 60, 54, 46, 86, 36, 86]), c.poly([8, 48, 20, 48, 12, 32, 6, 32]), c.poly([8, 52, 20, 52, 12, 68, 6, 68])])
        c.M(body, 0x9AA3AD, 0x3A4048)
        c.fill(c.ell(72, 46, 10, 6), PC.c(0x9FD0E8, 0.9))
        c.fill(c.circle(CGPoint(x: 49, y: 50), 3), PC.c(c.a.primary)); c.fill(c.rc(10, 48.5, 70, 2), PC.c(c.a.primary, 0.9))
        c.M(c.ell(90, 40, 6, 20), 0x59626D, 0x15181B, shadow: false)
    }
}
func rankBadge(_ c: PCtx, rank: Int) {
    // 0 bronze ... 7 conqueror
    let hi: [UInt32] = [0xE0A070, 0xE8EEF4, 0xFFE27A, 0x9CF5EA, 0xA8D6FF, 0xFFB86A, 0xFF8A66, 0xFF5A4A]
    let lo: [UInt32] = [0x7A4418, 0x707C8A, 0xC48A0A, 0x1FA89A, 0x2D6FD0, 0xC05A10, 0xB0301C, 0x8A0A10]
    let h = hi[rank], l = lo[rank]
    if rank >= 5 {   // wings
        for s in [1.0, -1.0] { let w = CGMutablePath(); w.move(to: CGPoint(x: 50 + s * 20, y: 46))
            w.addCurve(to: CGPoint(x: 50 + s * 48, y: 30), control1: CGPoint(x: 50 + s * 30, y: 44), control2: CGPoint(x: 50 + s * 42, y: 40))
            w.addCurve(to: CGPoint(x: 50 + s * 44, y: 62), control1: CGPoint(x: 50 + s * 54, y: 44), control2: CGPoint(x: 50 + s * 52, y: 56)); w.addLine(to: CGPoint(x: 50 + s * 20, y: 62)); w.closeSubpath()
            c.M(w, h, l, shadow: rank == 7) }
    }
    let sh = CGMutablePath(); sh.move(to: CGPoint(x: 50, y: 8)); sh.addLine(to: CGPoint(x: 82, y: 20)); sh.addLine(to: CGPoint(x: 82, y: 52)); sh.addCurve(to: CGPoint(x: 50, y: 92), control1: CGPoint(x: 82, y: 72), control2: CGPoint(x: 62, y: 84)); sh.addCurve(to: CGPoint(x: 18, y: 52), control1: CGPoint(x: 38, y: 84), control2: CGPoint(x: 18, y: 72)); sh.addLine(to: CGPoint(x: 18, y: 20)); sh.closeSubpath()
    c.M(sh, h, l)
    let inner = CGMutablePath(); inner.move(to: CGPoint(x: 50, y: 17)); inner.addLine(to: CGPoint(x: 74, y: 26)); inner.addLine(to: CGPoint(x: 74, y: 52)); inner.addCurve(to: CGPoint(x: 50, y: 83), control1: CGPoint(x: 74, y: 68), control2: CGPoint(x: 58, y: 77)); inner.addCurve(to: CGPoint(x: 26, y: 52), control1: CGPoint(x: 42, y: 77), control2: CGPoint(x: 26, y: 68)); inner.addLine(to: CGPoint(x: 26, y: 26)); inner.closeSubpath()
    c.vgrad(inner, [(0, PC.c(0x2A3038)), (1, PC.c(0x0B0D10))]); c.stroke(inner, PC.c(0, 0.7), 1)
    let n = min(rank / 2 + 1, 4)
    for k in 0..<n { let y = 36 + CGFloat(k) * 11 - CGFloat(n - 1) * 4
        let ch = c.poly([28, y, 50, y + 12, 72, y, 72, y + 6, 50, y + 18, 28, y + 6]); c.M(ch, h, l, outline: 0.8, shadow: false, sheen: 0.1) }
    c.M(c.poly([50, 20, 56, 28, 50, 36, 44, 28]), 0xFFFFFF, h, outline: 0.8, shadow: false)
    if rank == 7 { c.g.saveGState(); c.g.setBlendMode(.plusLighter); c.radial(CGPoint(x: 50, y: 50), 6, 60, [(0, PC.c(c.a.hot, 0.35)), (1, PC.c(c.a.hot, 0))]); c.g.restoreGState() }
}

func iconAssets() -> [BuiltinAsset] {
    let C = PropCategory.icons
    var o: [BuiltinAsset] = []
    func icon(_ id: String, _ name: String, tags: [String], _ body: @escaping @Sendable (PCtx) -> Void) {
        o.append(asset("icon." + id, name, C, 256, 256, tags: ["icon"] + tags) { c in c.local(CGRect(x: 18, y: 18, width: 220, height: 220)) { body(c) } })
    }
    for l in 1...3 { icon("helmet\(l)", "Helmet Lv.\(l)", tags: ["helmet", "armor", "level \(l)"]) { c in helmetArt(c, l) } }
    for l in 1...3 { icon("pack\(l)", "Backpack Lv.\(l)", tags: ["backpack", "bag", "level \(l)"]) { c in packArt(c, l) } }
    icon("medkit", "Med Kit", tags: ["heal", "medkit", "health"]) { c in
        c.stroke(c.rr(36, 14, 28, 20, 5), PC.c(0x8C96A0), 5)
        c.M(c.rr(10, 28, 80, 58, 8), 0xFF6A58, 0xA8120C); c.fill(c.rr(10, 28, 80, 8, 4), PC.c(0, 0.12))
        c.fill(c.poly([42, 40, 58, 40, 58, 52, 70, 52, 70, 64, 58, 64, 58, 76, 42, 76, 42, 64, 30, 64, 30, 52, 42, 52]), PC.white)
    }
    icon("firstaid", "First Aid Kit", tags: ["heal", "first aid", "health"]) { c in
        c.stroke(c.rr(38, 14, 24, 18, 5), PC.c(0xC9D2DC), 4.5)
        c.M(c.rr(12, 26, 76, 58, 8), 0xFFFFFF, 0xB8C0C8); c.fill(c.poly([42, 36, 58, 36, 58, 48, 70, 48, 70, 62, 58, 62, 58, 74, 42, 74, 42, 62, 30, 62, 30, 48, 42, 48]), PC.c(0xE5261B))
    }
    icon("bandage", "Bandage", tags: ["heal", "bandage"]) { c in
        c.g.saveGState(); c.g.translateBy(x: 50, y: 50); c.g.rotate(by: -.pi / 4); c.g.translateBy(x: -50, y: -50)
        c.M(c.rr(6, 34, 88, 32, 14), 0xF0D6A8, 0xB08A52)
        c.M(c.rr(34, 34, 32, 32, 3), 0xFFF8EA, 0xE0CFA8, shadow: false); c.stroke(c.rr(38, 38, 24, 24, 2), PC.c(0, 0.12), 1)
        for x in [14.0, 20.0, 26.0, 74.0, 80.0, 86.0] { c.fill(c.ell(x - 1.2, 47, 2.4, 2.4), PC.c(0x8A5A22, 0.6)); c.fill(c.ell(x - 1.2, 53, 2.4, 2.4), PC.c(0x8A5A22, 0.6)) }
        c.g.restoreGState()
    }
    icon("energy", "Energy Drink", tags: ["boost", "drink", "energy"]) { c in
        c.M(c.rr(30, 14, 40, 76, 8), 0x3A4048, 0x0D0F12); c.M(c.ell(30, 10, 40, 10), 0xC9D2DC, 0x59626D, shadow: false)
        c.g.saveGState(); c.g.addPath(c.rr(30, 14, 40, 76, 8)); c.g.clip()
        c.vgrad(c.rc(30, 28, 40, 48), [(0, PC.c(c.a.glow)), (1, PC.c(c.a.primary))]); c.g.restoreGState()
        c.fill(c.poly([54, 30, 40, 54, 49, 54, 44, 74, 62, 46, 52, 46]), PC.c(0x14171B))
        c.fill(c.rc(30, 76, 40, 3), PC.c(c.a.hot))
    }
    icon("painkiller", "Painkiller", tags: ["boost", "pills", "medicine"]) { c in
        c.M(c.rr(28, 24, 44, 66, 9), 0xFFB04A, 0xB4620A)
        c.M(c.rr(26, 12, 48, 18, 5), 0xFFFFFF, 0xB8C0C8, shadow: false)
        c.M(c.rr(34, 44, 32, 30, 3), 0xFFFFFF, 0xD8DEE5, shadow: false); c.fill(c.poly([47, 48, 53, 48, 53, 55, 60, 55, 60, 61, 53, 61, 53, 68, 47, 68, 47, 61, 40, 61, 40, 55, 47, 55]), PC.c(0xE5261B))
        c.M(c.ell(66, 70, 26, 16), 0xFFFFFF, 0xC9D2DC); c.line([CGPoint(x: 79, y: 70), CGPoint(x: 79, y: 86)], PC.c(0, 0.25), 1.4)
    }
    icon("syringe", "Adrenaline Syringe", tags: ["boost", "adrenaline", "syringe"]) { c in
        c.g.saveGState(); c.g.translateBy(x: 50, y: 50); c.g.rotate(by: -.pi / 4); c.g.translateBy(x: -50, y: -50)
        c.M(c.rr(24, 40, 52, 20, 4), 0xDDF0FF, 0x7FA4C0); c.fill(c.rr(30, 44, 36, 12, 3), PC.c(c.a.primary)); c.fill(c.rc(26, 38, 3, 24), PC.c(0, 0.25))
        c.M(c.rr(74, 36, 6, 28, 2), 0xC9D2DC, 0x59626D, shadow: false); c.M(c.rr(10, 46, 14, 8, 2), 0xC9D2DC, 0x59626D, shadow: false)
        c.M(c.rr(4, 36, 6, 28, 2), 0xC9D2DC, 0x59626D, shadow: false); c.line([CGPoint(x: 80, y: 50), CGPoint(x: 98, y: 50)], PC.c(0xC9D2DC), 2.2)
        c.g.restoreGState()
    }
    icon("frag", "Frag Grenade", tags: ["grenade", "throwable", "frag"]) { c in gren(c, kind: 0) }
    icon("smoke", "Smoke Grenade", tags: ["grenade", "throwable", "smoke"]) { c in gren(c, kind: 1) }
    icon("flash", "Flashbang", tags: ["grenade", "throwable", "flash", "stun"]) { c in gren(c, kind: 2) }
    icon("molotov", "Molotov", tags: ["fire", "throwable", "molotov"]) { c in
        let b = CGMutablePath(); b.move(to: CGPoint(x: 42, y: 30)); b.addLine(to: CGPoint(x: 58, y: 30)); b.addLine(to: CGPoint(x: 58, y: 46)); b.addCurve(to: CGPoint(x: 72, y: 70), control1: CGPoint(x: 70, y: 52), control2: CGPoint(x: 72, y: 60)); b.addLine(to: CGPoint(x: 72, y: 86)); b.addQuadCurve(to: CGPoint(x: 66, y: 92), control: CGPoint(x: 72, y: 92)); b.addLine(to: CGPoint(x: 34, y: 92)); b.addQuadCurve(to: CGPoint(x: 28, y: 86), control: CGPoint(x: 28, y: 92)); b.addLine(to: CGPoint(x: 28, y: 70)); b.addCurve(to: CGPoint(x: 42, y: 46), control1: CGPoint(x: 28, y: 60), control2: CGPoint(x: 30, y: 52)); b.closeSubpath()
        c.M(b, 0x6FA070, 0x23402A); c.fill(c.rc(30, 66, 40, 22), PC.c(c.a.hot, 0.55))
        c.M(c.rr(42, 62, 16, 22, 2), 0xE8DCC0, 0x9A8A60, shadow: false)
        c.flame(base: CGPoint(x: 50, y: 30), width: 34, height: 40, seed: 3, tongues: 3)
    }
    for (i, n) in ["5.56", "7.62", "9mm", "12ga"].enumerated() {
        icon("ammo.\(n.replacingOccurrences(of: ".", with: ""))", "Ammo \(n)", tags: ["ammo", "bullets", n]) { c in
            bulletsArt(c, caliber: i)
            c.text(n.uppercased(), PFont.tag, size: 20, color: PC.c(c.a.primary), in: CGRect(x: 5, y: 80, width: 90, height: 18), glow: PC.c(0, 0.8), glowR: 3)
        }
    }
    for (id, nm, k): (String, String, GunKind) in [("ar", "Assault Rifle", .ar), ("sniper", "Sniper Rifle", .sniper), ("smg", "SMG", .smg), ("shotgun", "Shotgun", .shotgun), ("pistol", "Pistol", .pistol)] {
        icon("gun." + id, nm, tags: ["weapon", "gun", id]) { c in
            c.g.saveGState(); c.g.translateBy(x: 0, y: 30); c.g.scaleBy(x: 1, y: 1)
            let box = CGRect(x: 2, y: 0, width: 96, height: 40)
            c.g.translateBy(x: box.minX, y: box.minY); c.g.scaleBy(x: box.width / 100, y: box.height / 40 * 1.7); c.g.translateBy(x: 0, y: -4)
            c.M(gunPath(c, k), 0x6A7480, 0x15181B, outline: 0.8)
            c.fill(c.rc(2, 14.6, 1.2, 0.01), PC.c(0)); c.g.restoreGState()
        }
    }
    icon("airdrop", "Airdrop Crate", tags: ["airdrop", "crate", "loot", "parachute"]) { c in
        let can = CGMutablePath(); can.move(to: CGPoint(x: 8, y: 40)); can.addCurve(to: CGPoint(x: 92, y: 40), control1: CGPoint(x: 8, y: -6), control2: CGPoint(x: 92, y: -6)); can.addQuadCurve(to: CGPoint(x: 76, y: 44), control: CGPoint(x: 84, y: 36)); can.addQuadCurve(to: CGPoint(x: 62, y: 42), control: CGPoint(x: 69, y: 36)); can.addQuadCurve(to: CGPoint(x: 38, y: 42), control: CGPoint(x: 50, y: 36)); can.addQuadCurve(to: CGPoint(x: 24, y: 44), control: CGPoint(x: 31, y: 36)); can.addQuadCurve(to: CGPoint(x: 8, y: 40), control: CGPoint(x: 16, y: 36))
        c.M(can, 0xFFFFFF, 0xC9D2DC)
        c.g.saveGState(); c.g.addPath(can); c.g.clip()
        for (i, x) in [8.0, 33.0, 58.0].enumerated() { _ = i; c.fill(c.poly([x + 10, 0, x + 26, 0, x + 26, 46, x + 8, 46]), PC.c(c.a.primary)) }
        c.g.restoreGState(); c.stroke(can, PC.c(0, 0.6), 1.2)
        for x in [10.0, 28, 50, 72, 90] { c.line([CGPoint(x: x, y: 42), CGPoint(x: 50, y: 72)], PC.c(0xDDE3EA, 0.85), 0.9) }
        c.M(c.rr(32, 70, 36, 26, 3), 0x8A9468, 0x3A4228); c.hazard(c.rc(32, 78, 36, 5), stripe: 5); c.line([CGPoint(x: 50, y: 70), CGPoint(x: 50, y: 96)], PC.c(0, 0.35), 1)
    }
    icon("parachute", "Parachute", tags: ["parachute", "drop", "glide"]) { c in
        let can = CGMutablePath(); can.move(to: CGPoint(x: 4, y: 52)); can.addCurve(to: CGPoint(x: 96, y: 52), control1: CGPoint(x: 4, y: -12), control2: CGPoint(x: 96, y: -12))
        for i in 0..<4 { let x1 = 96 - CGFloat(i + 1) * 23; can.addQuadCurve(to: CGPoint(x: x1, y: 52), control: CGPoint(x: x1 + 11.5, y: 44)) }
        c.M(can, 0xFFFFFF, 0xB8C0C8, sheen: 0.12)
        c.g.saveGState(); c.g.addPath(can); c.g.clip()
        for x in [-6.0, 40.0] { c.fill(c.poly([x + 18, -5, x + 40, -5, x + 40, 60, x + 4, 60]), PC.c(c.a.primary)) }
        c.fill(c.poly([88, -5, 110, -5, 110, 60, 88, 60]), PC.c(c.a.primary)); c.g.restoreGState(); c.stroke(can, PC.c(0, 0.6), 1.2)
        for x in [4.0, 27, 50, 73, 96] { c.line([CGPoint(x: x, y: 52), CGPoint(x: 50, y: 84)], PC.c(0xDDE3EA, 0.85), 0.9) }
        c.M(c.rr(42, 80, 16, 14, 4), 0x4A5442, 0x1E2418)
    }
    icon("supply", "Supply Crate", tags: ["crate", "loot", "supply"]) { c in
        c.M(c.rr(10, 22, 80, 66, 4), 0x8A9468, 0x3A4228)
        c.g.saveGState(); c.g.addPath(c.rr(10, 22, 80, 66, 4)); c.g.clip()
        for x in [26.0, 74.0] { c.fill(c.rc(x - 4, 22, 8, 66), PC.c(0x1E2418, 0.7)) }
        c.fill(c.rc(10, 22, 80, 6), PC.c(0, 0.25)); c.fill(c.rc(10, 80, 80, 8), PC.c(0, 0.25)); c.g.restoreGState()
        c.text("SUPPLY", PFont.headline, size: 20, color: PC.c(0xF0E8C8), in: CGRect(x: 30, y: 44, width: 40, height: 22), stencil: true)
        c.rivets([CGPoint(x: 18, y: 30), CGPoint(x: 82, y: 30), CGPoint(x: 18, y: 80), CGPoint(x: 82, y: 80)], 1.8)
        c.fill(c.rc(30, 70, 40, 3), PC.c(c.a.primary))
    }
    icon("jeep", "Jeep", tags: ["vehicle", "car", "jeep"]) { c in vehicle(c, 0) }
    icon("bike", "Motorbike", tags: ["vehicle", "bike", "motorcycle"]) { c in vehicle(c, 1) }
    icon("boat", "Boat", tags: ["vehicle", "boat", "water"]) { c in vehicle(c, 2) }
    icon("plane", "Plane", tags: ["vehicle", "plane", "air"]) { c in vehicle(c, 3) }
    icon("skull", "Skull", tags: ["skull", "kill", "death"]) { c in
        c.g.saveGState(); c.g.setShadow(offset: CGSize(width: 0, height: -2 * c.scale), blur: 6 * c.scale, color: PC.c(0, 0.6))
        c.vgrad(skullPath(c), [(0, PC.c(0xF2F4F6)), (1, PC.c(0xA3AEBB))]); c.g.restoreGState()
        c.g.saveGState(); c.g.setBlendMode(.clear)
        c.g.addPath(c.ell(26, 36, 20, 20)); c.g.addPath(c.ell(54, 36, 20, 20)); c.g.addPath(c.poly([50, 54, 44, 66, 56, 66])); c.g.fillPath()
        for x in [41.0, 49.0, 57.0] { c.g.addPath(c.rc(x - 1.2, 72, 2.4, 14)) }; c.g.fillPath(); c.g.restoreGState()
        c.glowFill(c.ell(30, 40, 12, 12), PC.c(c.a.hot), radius: 6); c.glowFill(c.ell(58, 40, 12, 12), PC.c(c.a.hot), radius: 6)
    }
    icon("headshot", "Headshot", tags: ["headshot", "kill", "skull", "crosshair"]) { c in
        c.fill(c.circle(CGPoint(x: 50, y: 50), 40), PC.c(0, 0.45))
        c.local(CGRect(x: 22, y: 20, width: 56, height: 56)) { c.vgrad(skullPath(c), [(0, PC.c(0xF2F4F6)), (1, PC.c(0xA3AEBB))])
            c.g.saveGState(); c.g.setBlendMode(.clear); c.g.addPath(c.ell(26, 36, 20, 20)); c.g.addPath(c.ell(54, 36, 20, 20)); c.g.fillPath(); c.g.restoreGState() }
        let hot = PC.c(c.a.hot)
        c.g.saveGState(); c.setGlow(hot, 8); c.stroke(c.circle(CGPoint(x: 50, y: 50), 38), hot, 3.4); c.g.restoreGState()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] { c.line([CGPoint(x: 50 + dx * 28, y: 50 + dy * 28), CGPoint(x: 50 + dx * 50, y: 50 + dy * 50)], hot, 3.4) }
        c.fill(c.circle(CGPoint(x: 50, y: 34), 3), hot)
    }
    icon("trophy", "Trophy", tags: ["trophy", "win", "cup"]) { c in
        for s in [1.0, -1.0] { let h = CGMutablePath(); h.move(to: CGPoint(x: 50 + s * 26, y: 22)); h.addCurve(to: CGPoint(x: 50 + s * 24, y: 50), control1: CGPoint(x: 50 + s * 50, y: 20), control2: CGPoint(x: 50 + s * 50, y: 48)); c.stroke(h, PC.c(0xC48A0A), 5.5, cap: .round); c.stroke(h, PC.c(0xFFD84A), 2.2, cap: .round) }
        let cup = CGMutablePath(); cup.move(to: CGPoint(x: 26, y: 14)); cup.addLine(to: CGPoint(x: 74, y: 14)); cup.addCurve(to: CGPoint(x: 52, y: 62), control1: CGPoint(x: 74, y: 40), control2: CGPoint(x: 62, y: 56)); cup.addLine(to: CGPoint(x: 48, y: 62)); cup.addCurve(to: CGPoint(x: 26, y: 14), control1: CGPoint(x: 38, y: 56), control2: CGPoint(x: 26, y: 40)); cup.closeSubpath()
        c.M(c.rc(46, 58, 8, 14), 0xFFD84A, 0xA8700A, shadow: false); c.M(c.rr(30, 70, 40, 10, 2), 0xFFD84A, 0xA8700A); c.M(c.rr(24, 80, 52, 12, 3), 0x3A4048, 0x0D0F12)
        c.M(cup, 0xFFF0A0, 0xE09A10); c.fill(c.poly([34, 18, 40, 18, 44, 44, 38, 38]), PC.c(0xFFFFFF, 0.35))
        c.glowFill(c.poly([50, 26, 54, 34, 62, 34, 56, 40, 58, 48, 50, 43, 42, 48, 44, 40, 38, 34, 46, 34]), PC.c(c.a.hot, 0.9), radius: 4)
    }
    icon("chicken", "Chicken Dinner", tags: ["winner", "chicken", "dinner", "win"]) { c in
        c.M(c.ell(4, 66, 92, 24), 0xDDE3EA, 0x6B7683); c.fill(c.ell(14, 70, 72, 14), PC.c(0x14171B, 0.35))
        let body = CGMutablePath(); body.move(to: CGPoint(x: 22, y: 66)); body.addCurve(to: CGPoint(x: 50, y: 26), control1: CGPoint(x: 18, y: 40), control2: CGPoint(x: 32, y: 26)); body.addCurve(to: CGPoint(x: 80, y: 66), control1: CGPoint(x: 70, y: 26), control2: CGPoint(x: 84, y: 44)); body.addQuadCurve(to: CGPoint(x: 22, y: 66), control: CGPoint(x: 50, y: 78))
        c.M(body, 0xFFB44A, 0x9A4A08)
        c.g.saveGState(); c.g.addPath(body); c.g.clip(); c.radial(CGPoint(x: 40, y: 40), 2, 36, [(0, PC.c(0xFFF0B0, 0.7)), (1, PC.c(0xFFF0B0, 0))]); c.g.restoreGState()
        for (x, y, a) in [(18.0, 66.0, -2.4), (84.0, 64.0, -0.7)] { c.g.saveGState(); c.g.translateBy(x: x, y: y); c.g.rotate(by: a)
            c.M(c.ell(-4, -9, 14, 18), 0xFFB44A, 0x8A3E06, shadow: false); c.M(c.rr(8, -3.5, 14, 7, 3), 0xF4E8D0, 0xB09A70, shadow: false); c.M(c.circle(CGPoint(x: 23, y: 0), 4.2), 0xF4E8D0, 0xB09A70, shadow: false); c.g.restoreGState() }
        c.fill(c.ell(48, 10, 4, 14), PC.c(0xFFFFFF, 0.35)); c.fill(c.ell(40, 14, 4, 12), PC.c(0xFFFFFF, 0.25)); c.fill(c.ell(58, 12, 4, 12), PC.c(0xFFFFFF, 0.25))
    }
    icon("crown", "Crown", tags: ["crown", "king", "win", "top"]) { c in
        let cr = CGMutablePath(); cr.move(to: CGPoint(x: 10, y: 74)); cr.addLine(to: CGPoint(x: 6, y: 28)); cr.addLine(to: CGPoint(x: 30, y: 50)); cr.addLine(to: CGPoint(x: 50, y: 18)); cr.addLine(to: CGPoint(x: 70, y: 50)); cr.addLine(to: CGPoint(x: 94, y: 28)); cr.addLine(to: CGPoint(x: 90, y: 74)); cr.closeSubpath()
        c.M(cr, 0xFFE680, 0xD08A0C); c.M(c.rr(10, 74, 80, 12, 3), 0xFFD84A, 0xA8700A)
        for (x, col) in [(26.0, c.a.hot), (50.0, 0x35B6FF), (74.0, c.a.hot)] { c.M(c.circle(CGPoint(x: x, y: 64), 5.5), 0xFFFFFF, col, outline: 0.8, shadow: false, sheen: 0.4) }
        for (x, y) in [(6.0, 26.0), (50.0, 16.0), (94.0, 26.0)] { c.M(c.circle(CGPoint(x: x, y: y), 4.2), 0xFFFFFF, 0xFFD84A, outline: 0.8, shadow: false) }
    }
    let rankNames = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "Crown", "Ace", "Conqueror"]
    for (i, n) in rankNames.enumerated() { icon("rank.\(n.lowercased())", "Rank \(n)", tags: ["rank", "medal", "tier", n.lowercased()]) { c in rankBadge(c, rank: i) } }
    icon("dogtag", "Dog Tag", tags: ["dogtag", "id", "military"]) { c in
        let chain = CGMutablePath(); chain.move(to: CGPoint(x: 18, y: 4)); chain.addQuadCurve(to: CGPoint(x: 70, y: 20), control: CGPoint(x: 36, y: 42))
        c.stroke(chain, PC.c(0xA3AEBB), 2.4); c.stroke(chain, PC.c(0x3A4048), 0.9)
        c.g.saveGState(); c.g.translateBy(x: 56, y: 62); c.g.rotate(by: -0.12); c.g.translateBy(x: -56, y: -62)
        c.M(c.rr(24, 30, 64, 54, 12), 0xC9D2DC, 0x59626D, shadow: true)
        c.stroke(c.rr(29, 35, 54, 44, 9), PC.c(0, 0.3), 1)
        c.fill(c.circle(CGPoint(x: 32, y: 44), 3), PC.c(0, 0.65))
        c.text("7XEN", PFont.mono, size: 12, color: PC.c(0x2A3038), in: CGRect(x: 38, y: 40, width: 40, height: 12)); c.text("O POS", PFont.mono, size: 9, color: PC.c(0x2A3038), in: CGRect(x: 38, y: 56, width: 40, height: 10)); c.text("ALPHA", PFont.mono, size: 9, color: PC.c(0x2A3038), in: CGRect(x: 38, y: 68, width: 40, height: 10))
        c.g.restoreGState()
    }
    icon("target", "Target Reticle", tags: ["target", "reticle", "bullseye"]) { c in
        let m = CGPoint(x: 50, y: 50)
        c.fill(c.circle(m, 44), PC.c(0x14171B, 0.8))
        for (r, col) in [(40.0, 0xFFFFFF), (30.0, c.a.hot), (20.0, 0xFFFFFF), (10.0, c.a.hot)] as [(CGFloat, UInt32)] { c.fill(c.circle(m, r), PC.c(col)) }
        c.stroke(c.circle(m, 44), PC.c(0x3A4048), 2.5)
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] { c.line([CGPoint(x: 50 + dx * 30, y: 50 + dy * 30), CGPoint(x: 50 + dx * 50, y: 50 + dy * 50)], PC.c(0x14171B), 3) }
    }
    icon("flare", "Signal Flare", tags: ["flare", "signal", "fire"]) { c in
        c.g.saveGState(); c.g.translateBy(x: 50, y: 50); c.g.rotate(by: 0.22); c.g.translateBy(x: -50, y: -50)
        c.M(c.rr(42, 42, 16, 50, 3), 0xFF6A5A, 0x9A1810); c.fill(c.rc(42, 56, 16, 5), PC.c(0xFFFFFF, 0.8)); c.M(c.rr(40, 38, 20, 8, 2), 0x59626D, 0x1E2227, shadow: false)
        c.flame(base: CGPoint(x: 50, y: 38), width: 34, height: 46, seed: 7, tongues: 3)
        c.g.restoreGState(); c.sparks(CGPoint(x: 52, y: 14), count: 14, length: 28, spread: 2.2, seed: 5)
    }
    icon("bomb", "Bomb", tags: ["bomb", "explosive", "boom"]) { c in
        c.M(c.circle(CGPoint(x: 46, y: 62), 32), 0x4A525C, 0x050607)
        c.g.saveGState(); c.g.addPath(c.circle(CGPoint(x: 46, y: 62), 32)); c.g.clip(); c.radial(CGPoint(x: 34, y: 48), 1, 20, [(0, PC.c(0xFFFFFF, 0.5)), (1, PC.c(0xFFFFFF, 0))]); c.g.restoreGState()
        c.M(c.rr(36, 24, 20, 12, 3), 0x8C96A0, 0x3A4048, shadow: false)
        let fuse = CGMutablePath(); fuse.move(to: CGPoint(x: 52, y: 26)); fuse.addCurve(to: CGPoint(x: 78, y: 12), control1: CGPoint(x: 56, y: 12), control2: CGPoint(x: 70, y: 22)); c.stroke(fuse, PC.c(0xD8C8A0), 3, cap: .round)
        c.sparks(CGPoint(x: 78, y: 12), count: 16, length: 22, spread: 6.2, seed: 2); c.glowFill(c.circle(CGPoint(x: 78, y: 12), 4), PC.c(c.a.glow), radius: 8)
        c.text("!", PFont.headline, size: 30, color: PC.c(c.a.primary), in: CGRect(x: 34, y: 50, width: 24, height: 30))
    }
    icon("c4", "C4 Charge", tags: ["bomb", "c4", "explosive"]) { c in
        c.M(c.rr(10, 34, 80, 44, 4), 0xC9C09A, 0x6A6446)
        c.fill(c.rc(10, 34, 80, 5), PC.c(0, 0.15)); c.M(c.rr(16, 42, 36, 18, 2), 0x0A1A0F, 0x050A06, shadow: false)
        c.text("00:30", PFont.mono, size: 13, color: PC.c(0xFF4A2A), in: CGRect(x: 16, y: 42, width: 36, height: 18), glow: PC.c(0xFF3B1F), glowR: 4)
        c.line([CGPoint(x: 60, y: 44), CGPoint(x: 86, y: 44)], PC.c(0, 0.3), 1); c.line([CGPoint(x: 60, y: 70), CGPoint(x: 86, y: 70)], PC.c(0, 0.3), 1)
        c.line([CGPoint(x: 70, y: 34), CGPoint(x: 70, y: 20), CGPoint(x: 86, y: 14)], PC.c(c.a.hot), 2.2, cap: .round); c.glowFill(c.circle(CGPoint(x: 70, y: 18), 3.2), PC.c(c.a.hot), radius: 6)
    }
    icon("knife", "Combat Knife", tags: ["weapon", "knife", "melee"]) { c in
        c.g.saveGState(); c.g.translateBy(x: 50, y: 50); c.g.rotate(by: -.pi / 4); c.g.translateBy(x: -50, y: -50)
        let blade = CGMutablePath(); blade.move(to: CGPoint(x: 38, y: 40)); blade.addLine(to: CGPoint(x: 80, y: 40)); blade.addQuadCurve(to: CGPoint(x: 98, y: 52), control: CGPoint(x: 92, y: 42)); blade.addLine(to: CGPoint(x: 38, y: 52)); blade.closeSubpath()
        c.M(blade, 0xF2F4F6, 0x8C96A0); c.fill(c.rc(40, 49, 54, 1.5), PC.c(0, 0.25)); c.M(c.rr(34, 34, 6, 24, 2), 0x59626D, 0x15181B, shadow: false)
        c.M(c.rr(4, 38, 30, 16, 5), 0x3A4048, 0x0D0F12); for x in [10.0, 16, 22, 28] { c.line([CGPoint(x: x, y: 39), CGPoint(x: x, y: 53)], PC.c(0, 0.5), 1.4) }
        c.g.restoreGState()
    }
    icon("pan", "Frying Pan", tags: ["weapon", "pan", "melee", "armor"]) { c in
        c.g.saveGState(); c.g.translateBy(x: 50, y: 50); c.g.rotate(by: -.pi / 5); c.g.translateBy(x: -50, y: -50)
        c.M(c.rr(66, 44, 32, 12, 5), 0x59626D, 0x15181B); c.fill(c.circle(CGPoint(x: 92, y: 50), 2.4), PC.c(0, 0.6))
        c.M(c.circle(CGPoint(x: 38, y: 50), 34), 0x5A636E, 0x15181B)
        c.M(c.circle(CGPoint(x: 38, y: 50), 27), 0x2A3038, 0x0A0C0E, shadow: false, sheen: 0.1)
        c.g.saveGState(); c.g.addPath(c.circle(CGPoint(x: 38, y: 50), 27)); c.g.clip(); c.radial(CGPoint(x: 28, y: 38), 1, 22, [(0, PC.c(0xFFFFFF, 0.28)), (1, PC.c(0xFFFFFF, 0))]); c.g.restoreGState()
        c.g.restoreGState()
    }
    icon("ammobox", "Ammo Box", tags: ["ammo", "box", "crate"]) { c in
        c.M(c.rr(10, 34, 80, 48, 5), 0x7C8A58, 0x2A3320); c.M(c.rr(8, 28, 84, 12, 3), 0x8A9468, 0x3A4228, shadow: false)
        c.M(c.rr(38, 20, 24, 12, 4), 0x59626D, 0x1E2227, shadow: false)
        c.text("AMMO", PFont.headline, size: 18, color: PC.c(0xF0E8C8), in: CGRect(x: 14, y: 48, width: 72, height: 20), stencil: true); c.fill(c.rc(10, 72, 80, 4), PC.c(c.a.primary))
        c.bullet(x: 78, y: 40, w: 4, h: 14); c.bullet(x: 84, y: 40, w: 4, h: 14)
    }
    icon("gascan", "Fuel Can", tags: ["fuel", "gas", "can", "vehicle"]) { c in
        c.M(c.rr(20, 22, 60, 68, 8), 0xE5261B, 0x7A0A08); c.M(c.rr(24, 14, 22, 12, 3), 0x59626D, 0x1E2227, shadow: false)
        c.M(c.rr(58, 12, 12, 14, 3), 0xFFD84A, 0xA8700A, shadow: false)
        c.stroke(c.poly([34, 40, 66, 40, 66, 74, 34, 74]), PC.c(0, 0.35), 1.6); c.fill(c.poly([54, 44, 44, 60, 51, 60, 46, 72, 58, 56, 51, 56]), PC.c(0xFFD84A))
    }
    return o
}
