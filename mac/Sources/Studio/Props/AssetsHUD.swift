import Foundation
import CoreGraphics

extension PCtx {
    /// White line with a dark outline (readable on any gameplay footage).
    func hudLine(_ pts: [CGPoint], _ w: CGFloat = 3, color: CGColor = PC.white) {
        line(pts, PC.c(0, 0.75), w + 3, cap: .square); line(pts, color, w, cap: .square)
    }
    func hudPath(_ p: CGPath, _ w: CGFloat = 3, color: CGColor = PC.white) {
        stroke(p, PC.c(0, 0.75), w + 3); stroke(p, color, w)
    }
    func bullet(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, brass: Bool = true, tip: UInt32 = 0xB8602A) {
        let tipH = h * 0.38
        let body = CGRect(x: x, y: y + tipH, width: w, height: h - tipH)
        let bp = CGMutablePath(); bp.addRect(body)
        hgrad(bp, brass ? [(0, PC.c(0x7A5A1C)), (0.35, PC.c(0xF0CE6A)), (0.6, PC.c(0xC49A34)), (1, PC.c(0x5A3F10))] : [(0, PC.c(PC.s3)), (0.4, PC.c(PC.s6)), (1, PC.c(PC.s2))])
        let t = CGMutablePath(); t.move(to: CGPoint(x: x, y: y + tipH)); t.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x, y: y + tipH * 0.4), control2: CGPoint(x: x + w * 0.25, y: y + 1))
        t.addCurve(to: CGPoint(x: x + w, y: y + tipH), control1: CGPoint(x: x + w * 0.75, y: y + 1), control2: CGPoint(x: x + w, y: y + tipH * 0.4)); t.closeSubpath()
        hgrad(t, [(0, PC.c(tip).mix(0x000000, 0.45)), (0.4, PC.c(tip).mix(0xFFFFFF, 0.35)), (1, PC.c(tip).mix(0x000000, 0.5))])
        fill(CGPath(rect: CGRect(x: x, y: y + h - h * 0.1, width: w, height: h * 0.1), transform: nil), PC.c(0, 0.35))
        stroke(bp, PC.c(0, 0.4), 0.6)
    }
}
extension CGColor {
    func mix(_ hex: UInt32, _ t: CGFloat) -> CGColor {
        let o = PC.c(hex).components ?? [0, 0, 0, 1], s = components ?? [0, 0, 0, 1]
        return CGColor(colorSpace: PC.cs, components: [s[0] + (o[0] - s[0]) * t, s[1] + (o[1] - s[1]) * t, s[2] + (o[2] - s[2]) * t, alpha])!
    }
}

func hudAssets() -> [BuiltinAsset] {
    let C = PropCategory.hud
    var out: [BuiltinAsset] = []
    let ctr: (PCtx) -> CGPoint = { CGPoint(x: $0.w / 2, y: $0.h / 2) }

    // Crosshairs
    out.append(asset("hud.cross.dot", "Crosshair Dot", C, 128, 128, tags: ["crosshair", "dot"]) { c in
        let m = ctr(c); c.fill(c.circle(m, 8), PC.c(0, 0.7)); c.glowFill(c.circle(m, 5), PC.c(c.a.primary), radius: 6); c.fill(c.circle(m, 2.2), PC.white)
    })
    out.append(asset("hud.cross.plus", "Crosshair Plus", C, 128, 128, tags: ["crosshair", "classic"]) { c in
        let m = ctr(c)
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] { c.hudLine([CGPoint(x: m.x + dx * 12, y: m.y + dy * 12), CGPoint(x: m.x + dx * 44, y: m.y + dy * 44)], 3) }
        c.fill(c.circle(m, 2), PC.c(c.a.primary))
    })
    out.append(asset("hud.cross.circle", "Crosshair Circle", C, 128, 128, tags: ["crosshair", "ring"]) { c in
        let m = ctr(c); c.hudPath(c.circle(m, 30), 2.5)
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] { c.hudLine([CGPoint(x: m.x + dx * 22, y: m.y + dy * 22), CGPoint(x: m.x + dx * 40, y: m.y + dy * 40)], 2.5) }
        c.glowFill(c.circle(m, 2.5), PC.c(c.a.primary), radius: 6)
    })
    out.append(asset("hud.cross.chevron", "Crosshair Chevron", C, 128, 128, tags: ["crosshair", "chevron"]) { c in
        let m = ctr(c)
        c.hudLine([CGPoint(x: m.x - 26, y: m.y + 18), CGPoint(x: m.x, y: m.y - 4), CGPoint(x: m.x + 26, y: m.y + 18)], 4, color: PC.c(c.a.primary))
        c.hudLine([CGPoint(x: m.x - 14, y: m.y + 34), CGPoint(x: m.x, y: m.y + 22), CGPoint(x: m.x + 14, y: m.y + 34)], 3)
        c.fill(c.circle(CGPoint(x: m.x, y: m.y - 14), 2), PC.white)
    })
    out.append(asset("hud.cross.tactical", "Crosshair Tactical", C, 160, 160, tags: ["crosshair", "ticks"]) { c in
        let m = ctr(c); let col = PC.c(c.a.primary)
        for k in 0..<4 { let a = CGFloat(k) * .pi / 2 + .pi / 4
            let p = CGMutablePath(); p.addArc(center: m, radius: 46, startAngle: a - 0.38, endAngle: a + 0.38, clockwise: false); c.stroke(p, PC.c(0, 0.7), 8); c.stroke(p, col, 4.5) }
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0)] { c.hudLine([CGPoint(x: m.x + dx * 16, y: m.y + dy * 16), CGPoint(x: m.x + dx * 36, y: m.y + dy * 36)], 2.5) }
        c.hudLine([CGPoint(x: m.x, y: m.y - 70), CGPoint(x: m.x, y: m.y - 54)], 2.5)
        c.glowFill(c.circle(m, 2.6), PC.c(c.a.glow), radius: 5)
    })
    out.append(asset("hud.cross.scope", "Sniper Scope", C, 640, 640, tags: ["scope", "sniper", "crosshair"]) { c in
        let m = ctr(c)
        let full = CGMutablePath(); full.addRect(c.rect); full.addPath(c.circle(m, 300))
        c.fill(full, PC.c(0, 0.92), evenOdd: true)
        c.stroke(c.circle(m, 300), PC.c(PC.s4), 3); c.stroke(c.circle(m, 304), PC.c(0, 0.9), 5)
        c.line([CGPoint(x: 20, y: m.y), CGPoint(x: 620, y: m.y)], PC.c(0, 0.85), 1.4); c.line([CGPoint(x: m.x, y: 20), CGPoint(x: m.x, y: 620)], PC.c(0, 0.85), 1.4)
        c.line([CGPoint(x: m.x - 300, y: m.y), CGPoint(x: m.x - 60, y: m.y)], PC.c(0, 1), 4); c.line([CGPoint(x: m.x + 60, y: m.y), CGPoint(x: m.x + 300, y: m.y)], PC.c(0, 1), 4)
        c.line([CGPoint(x: m.x, y: m.y - 300), CGPoint(x: m.x, y: m.y - 60)], PC.c(0, 1), 4)
        for k in 1...6 { let d = CGFloat(k) * 28 + 40; c.line([CGPoint(x: m.x - 6, y: m.y + d), CGPoint(x: m.x + 6, y: m.y + d)], PC.c(0, 1), 2) }
        c.fill(c.circle(m, 2), PC.c(c.a.hot))
    })
    // Hit markers
    @Sendable func hit(_ c: PCtx, _ col: CGColor, _ gl: CGColor?) {
        let m = ctr(c)
        for (dx, dy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
            let a = CGPoint(x: m.x + dx * 10, y: m.y + dy * 10), b = CGPoint(x: m.x + dx * 26, y: m.y + dy * 26)
            c.g.saveGState(); if let gl { c.setGlow(gl, 8) }
            c.line([a, b], PC.c(0, 0.6), 7, cap: .butt); c.line([a, b], col, 4.2, cap: .butt); c.g.restoreGState()
        }
    }
    out.append(asset("hud.hit.white", "Hit Marker", C, 80, 80, tags: ["hit", "marker"]) { c in hit(c, PC.white, nil) })
    out.append(asset("hud.hit.head", "Headshot Hit Marker", C, 80, 80, tags: ["hit", "headshot"]) { c in hit(c, PC.c(c.a.hot), PC.c(c.a.hot)) })
    out.append(asset("hud.hit.kill", "Kill Confirm Marker", C, 96, 96, tags: ["hit", "kill", "skull"]) { c in
        hit(c, PC.c(c.a.hot), PC.c(c.a.hot)); let m = ctr(c); drawSkull(c, center: m, size: 30, color: PC.white)
    })
    out.append(asset("hud.lock", "Target Lock Brackets", C, 200, 200, tags: ["target", "lock", "brackets"]) { c in
        let col = PC.c(c.a.primary)
        for (x, y, sx, sy) in [(20.0, 20.0, 1.0, 1.0), (180.0, 20.0, -1.0, 1.0), (20.0, 180.0, 1.0, -1.0), (180.0, 180.0, -1.0, -1.0)] {
            c.g.saveGState(); c.setGlow(col, 8)
            c.line([CGPoint(x: x, y: y + sy * 34), CGPoint(x: x, y: y), CGPoint(x: x + sx * 34, y: y)], col, 4); c.g.restoreGState()
        }
        c.line([CGPoint(x: 100, y: 84), CGPoint(x: 100, y: 116)], PC.c(c.a.glow, 0.9), 1.5); c.line([CGPoint(x: 84, y: 100), CGPoint(x: 116, y: 100)], PC.c(c.a.glow, 0.9), 1.5)
    })
    // Compass strip
    out.append(asset("hud.compass", "Compass Strip", C, 960, 72, tags: ["compass", "heading", "bearing"]) { c in
        c.g.beginTransparencyLayer(auxiliaryInfo: nil)
        let bar = c.chamfer(CGRect(x: 0, y: 14, width: 960, height: 44), 0)
        c.vgrad(bar, [(0, PC.c(PC.s1, 0.85)), (1, PC.c(PC.s0, 0.85))])
        c.line([CGPoint(x: 0, y: 14), CGPoint(x: 960, y: 14)], PC.c(0xFFFFFF, 0.18), 1)
        let names = ["SW", "W", "NW", "N", "NE", "E", "SE"]
        for d in stride(from: 0, through: 960, by: 12) {
            let x = CGFloat(d) + 0, idx = d / 12
            let major = idx % 5 == 0
            c.line([CGPoint(x: x, y: 58), CGPoint(x: x, y: major ? 44 : 50)], PC.c(0xFFFFFF, major ? 0.7 : 0.35), major ? 1.6 : 1)
        }
        for (i, n) in names.enumerated() {
            let x = 480 + (CGFloat(i) - 3.5) * 120 + 60 * 0 + 60
            let nx = 60 + CGFloat(i) * 140
            _ = x
            c.text(n, PFont.tag, size: n.count == 1 ? 26 : 20, color: n == "N" ? PC.c(c.a.primary) : PC.white, in: CGRect(x: nx - 30, y: 12, width: 60, height: 32), glow: n == "N" ? PC.c(c.a.primary) : nil)
        }
        // fade edges
        c.g.setBlendMode(.destinationIn)
        c.grad([(0, PC.c(0, 0)), (0.2, PC.c(0, 1)), (0.8, PC.c(0, 1)), (1, PC.c(0, 0))], CGPoint(x: 0, y: 0), CGPoint(x: 960, y: 0))
        c.g.setBlendMode(.normal); c.g.endTransparencyLayer()
        c.fill(c.poly([480, 60, 470, 72, 490, 72]), PC.c(c.a.primary))
        c.glowFill(c.poly([480, 10, 472, 0, 488, 0]), PC.c(c.a.primary), radius: 6)
        c.text("045", PFont.mono, size: 13, color: PC.c(c.a.glow), in: CGRect(x: 440, y: 20, width: 80, height: 14), glow: PC.c(0, 0.8), glowR: 3)
    })
    out.append(asset("hud.radar", "Radar Sweep", C, 360, 360, tags: ["radar", "minimap", "scan"]) { c in
        let m = ctr(c)
        c.fill(c.circle(m, 170), PC.c(0x050708, 0.72))
        for r in [40.0, 80.0, 120.0, 160.0] { c.stroke(c.circle(m, r), PC.c(c.a.primary, 0.35), 1) }
        c.line([CGPoint(x: 10, y: m.y), CGPoint(x: 350, y: m.y)], PC.c(c.a.primary, 0.3), 1); c.line([CGPoint(x: m.x, y: 10), CGPoint(x: m.x, y: 350)], PC.c(c.a.primary, 0.3), 1)
        let wedge = CGMutablePath(); wedge.move(to: m); wedge.addArc(center: m, radius: 164, startAngle: -1.9, endAngle: -0.6, clockwise: false); wedge.closeSubpath()
        c.g.saveGState(); c.g.addPath(wedge); c.g.clip(); c.g.setBlendMode(.plusLighter)
        c.grad([(0, PC.c(c.a.primary, 0)), (1, PC.c(c.a.primary, 0.7))], CGPoint(x: m.x - 100, y: m.y - 100), CGPoint(x: m.x + 100, y: m.y - 100)); c.g.restoreGState()
        c.line([m, CGPoint(x: m.x + cos(-0.6) * 164, y: m.y + sin(-0.6) * 164)], PC.c(c.a.glow, 0.9), 1.5)
        var r = PRNG(4); for _ in 0..<7 { let a = r.r(0, 6.28), d = r.r(30, 150); c.glowFill(c.circle(CGPoint(x: m.x + cos(a) * d, y: m.y + sin(a) * d), 3.2), PC.c(c.a.hot), radius: 6) }
        c.fill(c.poly([m.x, m.y - 9, m.x - 6, m.y + 6, m.x + 6, m.y + 6]), PC.white)
        c.stroke(c.circle(m, 172), PC.c(PC.s3), 6); c.stroke(c.circle(m, 176), PC.c(0, 0.8), 2); c.stroke(c.circle(m, 169), PC.c(0xFFFFFF, 0.15), 1)
        for k in 0..<72 { let a = CGFloat(k) * .pi / 36, l: CGFloat = k % 6 == 0 ? 10 : 5
            c.line([CGPoint(x: m.x + cos(a) * 168, y: m.y + sin(a) * 168), CGPoint(x: m.x + cos(a) * (168 - l), y: m.y + sin(a) * (168 - l))], PC.c(0xFFFFFF, 0.4), 1) }
    })
    // Bars
    func bar(_ id: String, _ name: String, fillTop: UInt32, fillBot: UInt32, tray: Bool, fillOn: Bool, tags: [String]) -> BuiltinAsset {
        asset(id, name, C, 440, 46, tags: tags) { c in
            let o = c.para(CGRect(x: 2, y: 4, width: 436, height: 38), skew: 14)
            if tray {
                c.dropShadow(o, PC.c(PC.s0), dy: 2, blur: 6)
                c.vgrad(o, [(0, PC.c(0x050607, 0.9)), (1, PC.c(PC.s2, 0.9))]); c.stroke(o, PC.c(PC.s4), 1.5); c.innerShadow(o, blur: 5, alpha: 0.7, dy: 2)
            }
            if fillOn {
                let f = c.para(CGRect(x: 8, y: 10, width: 424, height: 26), skew: 11)
                c.vgrad(f, [(0, PC.c(fillTop)), (1, PC.c(fillBot))])
                c.g.saveGState(); c.g.addPath(f); c.g.clip()
                c.fill(CGPath(rect: CGRect(x: 0, y: 10, width: 440, height: 8), transform: nil), PC.c(0xFFFFFF, 0.28))
                for x in stride(from: 40.0, to: 430.0, by: 38.0) { c.fill(CGPath(rect: CGRect(x: x, y: 8, width: 2, height: 30), transform: nil), PC.c(0, 0.45)) }
                c.g.restoreGState()
                c.glowStroke(f, PC.c(fillTop, 0.9), 1, radius: 6)
            }
        }
    }
    out.append(bar("hud.health", "Health Bar", fillTop: 0xFFFFFF, fillBot: 0xC9D2DC, tray: true, fillOn: true, tags: ["health", "bar"]))
    out.append(bar("hud.health.tray", "Health Bar Tray", fillTop: 0, fillBot: 0, tray: true, fillOn: false, tags: ["health", "tray"]))
    out.append(bar("hud.health.fill", "Health Bar Fill", fillTop: 0xFFFFFF, fillBot: 0xC9D2DC, tray: false, fillOn: true, tags: ["health", "fill"]))
    out.append(bar("hud.armor", "Armor Bar", fillTop: 0x7CC4FF, fillBot: 0x2F7BD0, tray: true, fillOn: true, tags: ["armor", "bar", "shield"]))
    out.append(bar("hud.boost", "Boost Energy Bar", fillTop: 0xFFD04A, fillBot: 0xE08A00, tray: true, fillOn: true, tags: ["boost", "energy", "bar"]))
    out.append(bar("hud.danger", "Danger Bar", fillTop: 0xFF5A3A, fillBot: 0xB00F10, tray: true, fillOn: true, tags: ["low", "danger", "bar"]))
    out.append(asset("hud.ammo", "Ammo Counter", C, 300, 110, tags: ["ammo", "counter"]) { c in
        let o = c.chamfer(CGRect(x: 4, y: 4, width: 292, height: 102), 6, 24, 6, 24)
        c.dropShadow(o, PC.c(PC.s2)); c.plate(o, tone: 1)
        c.fill(c.poly([4, 4, 20, 4, 20, 106, 4, 106]), PC.c(c.a.primary))
        for i in 0..<3 { c.bullet(x: 38 + CGFloat(i) * 16, y: 22, w: 11, h: 54) }
        c.text("30", PFont.headline, size: 62, color: PC.white, in: CGRect(x: 100, y: 14, width: 100, height: 70), align: .left, shadow: true)
        c.text("/ 120", PFont.tag, size: 28, color: PC.c(PC.s6), in: CGRect(x: 190, y: 40, width: 90, height: 30), align: .left)
        c.text("5.56 MM  -  AUTO", PFont.mono, size: 10, color: PC.c(c.a.primary), in: CGRect(x: 100, y: 84, width: 180, height: 14), align: .left)
    })
    out.append(asset("hud.minimap", "Minimap Frame", C, 360, 360, tags: ["minimap", "map", "frame"]) { c in
        let o = c.chamfer(CGRect(x: 6, y: 6, width: 348, height: 348), 28, 6, 28, 6)
        let i = c.chamfer(CGRect(x: 20, y: 20, width: 320, height: 320), 20, 2, 20, 2)
        c.frameRing(outer: o, inner: i, rivetsAt: [CGPoint(x: 13, y: 40), CGPoint(x: 347, y: 320)])
        c.g.saveGState(); c.g.addPath(i); c.g.clip()
        c.fill(i, PC.c(0x0A0D10, 0.55))
        for k in 1..<8 { let v = 20 + CGFloat(k) * 40; c.line([CGPoint(x: v, y: 20), CGPoint(x: v, y: 340)], PC.c(c.a.primary, 0.12), 1); c.line([CGPoint(x: 20, y: v), CGPoint(x: 340, y: v)], PC.c(c.a.primary, 0.12), 1) }
        c.g.restoreGState()
        c.text("N", PFont.tag, size: 18, color: PC.c(c.a.primary), in: CGRect(x: 160, y: 20, width: 40, height: 20), glow: PC.c(c.a.primary), glowR: 4)
        c.text("MAP", PFont.mono, size: 10, color: PC.c(PC.s6), in: CGRect(x: 26, y: 322, width: 60, height: 14), align: .left)
    })
    out.append(asset("hud.zone", "Zone Circle Timer", C, 300, 300, tags: ["zone", "circle", "timer", "blue zone"]) { c in
        let m = ctr(c)
        c.fill(c.circle(m, 138), PC.c(0x050708, 0.7)); c.stroke(c.circle(m, 138), PC.c(PC.s3), 10); c.stroke(c.circle(m, 143), PC.c(0, 0.8), 2)
        let arc = CGMutablePath(); arc.addArc(center: m, radius: 124, startAngle: -.pi / 2, endAngle: .pi * 1.05, clockwise: false)
        c.g.saveGState(); c.setGlow(PC.c(c.a.hot), 12); c.stroke(arc, PC.c(c.a.hot), 8); c.g.restoreGState(); c.stroke(arc, PC.c(c.a.primary), 4)
        let rest = CGMutablePath(); rest.addArc(center: m, radius: 124, startAngle: .pi * 1.05, endAngle: .pi * 1.5, clockwise: false); c.stroke(rest, PC.c(0xFFFFFF, 0.2), 4)
        for k in 0..<60 { let a = CGFloat(k) * .pi / 30; c.line([CGPoint(x: m.x + cos(a) * 108, y: m.y + sin(a) * 108), CGPoint(x: m.x + cos(a) * (k % 5 == 0 ? 98 : 103), y: m.y + sin(a) * (k % 5 == 0 ? 98 : 103))], PC.c(0xFFFFFF, 0.4), 1) }
        c.text("ZONE CLOSING", PFont.mono, size: 12, color: PC.c(c.a.glow), in: CGRect(x: 70, y: 80, width: 160, height: 16))
        c.hazard(c.rrect(CGRect(x: 105, y: 190, width: 90, height: 8), 2), stripe: 7, alpha: 0.9)
    })
    out.append(asset("hud.timer", "Timer Box", C, 220, 72, tags: ["timer", "clock"]) { c in
        let o = c.chamfer(CGRect(x: 4, y: 4, width: 212, height: 64), 12, 4, 12, 4)
        c.dropShadow(o, PC.c(PC.s2)); c.plate(o, tone: 1)
        c.glowStroke(c.chamfer(CGRect(x: 10, y: 10, width: 200, height: 52), 9, 2, 9, 2), PC.c(c.a.primary, 0.8), 1.2, radius: 4)
        c.text("05:00", PFont.mono, size: 34, color: PC.white, in: CGRect(x: 10, y: 10, width: 200, height: 52), glow: PC.c(c.a.primary, 0.9), glowR: 6)
    })
    out.append(asset("hud.killfeed.friend", "Kill Feed Row (Friendly)", C, 520, 46, tags: ["killfeed", "kill"]) { c in killRow(c, accent: c.a.primary, weapon: true) })
    out.append(asset("hud.killfeed.enemy", "Kill Feed Row (Enemy)", C, 520, 46, tags: ["killfeed", "kill", "enemy"]) { c in killRow(c, accent: c.a.hot, weapon: true) })
    out.append(asset("hud.killfeed.blank", "Kill Feed Row (Blank)", C, 520, 46, tags: ["killfeed", "kill"]) { c in killRow(c, accent: PC.s4, weapon: false) })
    out.append(asset("hud.damage.white", "Damage Number", C, 200, 80, tags: ["damage", "number"]) { c in
        c.text("124", PFont.italic, size: 54, color: PC.white, in: c.rect, shadow: true, outline: PC.c(0, 0.8), outlineW: 5)
    })
    out.append(asset("hud.damage.crit", "Critical Damage Number", C, 240, 100, tags: ["damage", "crit", "headshot"]) { c in
        c.text("250", PFont.italic, size: 70, color: PC.c(c.a.glow), in: c.rect, glow: PC.c(c.a.hot), glowR: 14, gradient: (PC.c(c.a.glow), PC.c(c.a.primary)), outline: PC.c(0, 0.85), outlineW: 6)
    })
    out.append(asset("hud.squad.slot", "Squad Status Slot", C, 280, 70, tags: ["squad", "teammate", "health"]) { c in
        let o = c.chamfer(CGRect(x: 4, y: 4, width: 272, height: 62), 4, 14, 4, 14)
        c.dropShadow(o, PC.c(PC.s2)); c.plate(o, tone: 1)
        c.fill(c.rrect(CGRect(x: 14, y: 14, width: 42, height: 42), 4), PC.c(PC.s0)); c.stroke(c.rrect(CGRect(x: 14, y: 14, width: 42, height: 42), 4), PC.c(c.a.primary), 1.5)
        drawHelmet(c, center: CGPoint(x: 35, y: 36), size: 26, level: 2)
        c.fill(c.rrect(CGRect(x: 66, y: 40, width: 192, height: 10), 2), PC.c(0, 0.6)); c.fill(c.rrect(CGRect(x: 66, y: 40, width: 150, height: 10), 2), PC.white)
        c.fill(c.rrect(CGRect(x: 66, y: 52, width: 192, height: 4), 1), PC.c(0, 0.6)); c.fill(c.rrect(CGRect(x: 66, y: 52, width: 100, height: 4), 1), PC.c(0x57B6FF))
    })
    out.append(asset("hud.waypoint", "Waypoint Marker", C, 96, 140, tags: ["waypoint", "ping", "marker"]) { c in
        let p = c.poly([48, 130, 12, 56, 20, 30, 48, 10, 76, 30, 84, 56])
        c.g.saveGState(); c.setGlow(PC.c(c.a.primary), 14); c.fill(p, PC.c(c.a.primary)); c.g.restoreGState()
        c.vgrad(p, [(0, PC.c(c.a.glow)), (1, PC.c(c.a.primary))]); c.stroke(p, PC.c(0, 0.5), 2)
        c.fill(c.circle(CGPoint(x: 48, y: 52), 14), PC.c(0, 0.75)); c.fill(c.circle(CGPoint(x: 48, y: 52), 6), PC.white)
    })
    return out
}

private func killRow(_ c: PCtx, accent: UInt32, weapon: Bool) {
    let o = c.para(CGRect(x: 6, y: 4, width: 508, height: 38), skew: 12)
    c.dropShadow(o, PC.c(0x0A0C0E, 0.9), dy: 2, blur: 6)
    c.vgrad(o, [(0, PC.c(PC.s2, 0.92)), (1, PC.c(PC.s0, 0.92))])
    c.g.saveGState(); c.g.addPath(o); c.g.clip()
    c.grad([(0, PC.c(accent, 0.45)), (0.35, PC.c(accent, 0))], CGPoint(x: 0, y: 0), CGPoint(x: 520, y: 0))
    c.fill(CGPath(rect: CGRect(x: 0, y: 4, width: 8, height: 38), transform: nil), PC.c(accent))
    c.g.restoreGState()
    c.stroke(o, PC.c(0xFFFFFF, 0.14), 1)
    if weapon {
        drawGun(c, kind: GunKind.ar, box: CGRect(x: 214, y: 10, width: 92, height: 26), color: PC.white)
        drawSkull(c, center: CGPoint(x: 486, y: 23), size: 18, color: PC.c(accent))
    }
}
