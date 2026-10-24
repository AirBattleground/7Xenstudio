import Foundation
import CoreGraphics

extension PCtx {
    /// Skewed plate with accent end-cap, soft shadow and metal finish.
    @discardableResult
    func slab(_ r: CGRect, skew: CGFloat = 18, tone: Int = 0, accent: UInt32? = nil, cap: CGFloat = 10, seed: UInt64 = 3, glowEdge: Bool = false) -> CGPath {
        let p = para(r, skew: skew)
        dropShadow(p, PC.c(PC.s1), dy: 4, blur: 10)
        plate(p, tone: tone, seed: seed)
        let ac = accent ?? a.primary
        if cap > 0 { fill(poly([r.minX + skew, r.minY, r.minX + skew + cap, r.minY, r.minX + cap, r.maxY, r.minX, r.maxY]), PC.c(ac)) }
        if glowEdge { glowStroke(p, PC.c(ac, 0.9), 1.4, radius: 8) }
        return p
    }
    func vsHex(_ ctr: CGPoint, _ r: CGFloat) {
        let hx = hexagon(CGRect(x: ctr.x - r, y: ctr.y - r * 0.9, width: r * 2, height: r * 1.8), cut: r * 0.5)
        g.saveGState(); setGlow(PC.c(a.hot, 0.9), 16); fill(hx, PC.c(a.hot)); g.restoreGState()
        vgrad(hx, [(0, PC.c(a.primary)), (1, PC.c(a.hot))]); stroke(hx, PC.c(0, 0.6), 2)
        stroke(hexagon(CGRect(x: ctr.x - r + 5, y: ctr.y - r * 0.9 + 5, width: r * 2 - 10, height: r * 1.8 - 10), cut: r * 0.45), PC.c(0xFFFFFF, 0.4), 1.2)
        text("VS", PFont.italic, size: r * 0.95, color: PC.white, in: CGRect(x: ctr.x - r, y: ctr.y - r * 0.45, width: r * 2, height: r * 0.9), shadow: true)
    }
    /// Social marks drawn as simple vector glyphs inside a 100x100 local box.
    func socialGlyph(_ k: Int, _ box: CGRect) {
        local(box) {
            switch k {
            case 0:   // YouTube
                M(rr(4, 20, 92, 60, 18), 0xFF4A3A, 0xC4120A, outline: 1)
                fill(poly([40, 33, 40, 67, 70, 50]), PC.white)
            case 1:   // Instagram
                let sq = rr(8, 8, 84, 84, 24)
                grad([(0, PC.c(0xFFD35A)), (0.35, PC.c(0xFF5A3A)), (0.7, PC.c(0xD0309A)), (1, PC.c(0x6A3AD0))], CGPoint(x: 8, y: 92), CGPoint(x: 92, y: 8), clip: sq)
                stroke(rr(28, 28, 44, 44, 14), PC.white, 6); stroke(circle(CGPoint(x: 50, y: 50), 11), PC.white, 6); fill(circle(CGPoint(x: 66, y: 34), 3.6), PC.white)
            case 2:   // Discord-like controller mask
                let p = CGMutablePath(); p.move(to: CGPoint(x: 20, y: 22)); p.addCurve(to: CGPoint(x: 38, y: 16), control1: CGPoint(x: 26, y: 18), control2: CGPoint(x: 32, y: 16))
                p.addQuadCurve(to: CGPoint(x: 62, y: 16), control: CGPoint(x: 50, y: 12)); p.addCurve(to: CGPoint(x: 80, y: 22), control1: CGPoint(x: 68, y: 16), control2: CGPoint(x: 74, y: 18))
                p.addCurve(to: CGPoint(x: 94, y: 66), control1: CGPoint(x: 90, y: 34), control2: CGPoint(x: 96, y: 52)); p.addCurve(to: CGPoint(x: 72, y: 80), control1: CGPoint(x: 84, y: 74), control2: CGPoint(x: 78, y: 78))
                p.addLine(to: CGPoint(x: 66, y: 72)); p.addQuadCurve(to: CGPoint(x: 34, y: 72), control: CGPoint(x: 50, y: 78)); p.addLine(to: CGPoint(x: 28, y: 80))
                p.addCurve(to: CGPoint(x: 6, y: 66), control1: CGPoint(x: 22, y: 78), control2: CGPoint(x: 16, y: 74)); p.addCurve(to: CGPoint(x: 20, y: 22), control1: CGPoint(x: 4, y: 52), control2: CGPoint(x: 10, y: 34)); p.closeSubpath()
                M(p, 0x8A9CFF, 0x4A5CD8, outline: 1)
                fill(ell(26, 40, 17, 22), PC.white); fill(ell(57, 40, 17, 22), PC.white); fill(ell(32, 48, 8, 12), PC.c(0x3A48A8)); fill(ell(63, 48, 8, 12), PC.c(0x3A48A8))
            default:  // Twitch-like bubble
                let p = poly([12, 8, 92, 8, 92, 56, 66, 82, 50, 82, 36, 94, 36, 82, 12, 82])
                M(p, 0xB58CFF, 0x6A3AD0, outline: 1)
                fill(rc(40, 26, 8, 26), PC.white); fill(rc(62, 26, 8, 26), PC.white)
            }
        }
    }
    func bell(_ ctr: CGPoint, _ s: CGFloat, color: CGColor = PC.white) {
        let p = CGMutablePath(); p.move(to: CGPoint(x: ctr.x - s * 0.6, y: ctr.y + s * 0.4)); p.addCurve(to: CGPoint(x: ctr.x, y: ctr.y - s * 0.7), control1: CGPoint(x: ctr.x - s * 0.4, y: ctr.y + s * 0.2), control2: CGPoint(x: ctr.x - s * 0.5, y: ctr.y - s * 0.7))
        p.addCurve(to: CGPoint(x: ctr.x + s * 0.6, y: ctr.y + s * 0.4), control1: CGPoint(x: ctr.x + s * 0.5, y: ctr.y - s * 0.7), control2: CGPoint(x: ctr.x + s * 0.4, y: ctr.y + s * 0.2)); p.closeSubpath()
        fill(p, color); fill(circle(CGPoint(x: ctr.x, y: ctr.y + s * 0.6), s * 0.16), color)
    }
    func thumb(_ box: CGRect, color: CGColor = PC.white) {
        local(box) {
            fill(rr(6, 44, 20, 46, 4), color)
            let p = CGMutablePath(); p.move(to: CGPoint(x: 32, y: 44)); p.addLine(to: CGPoint(x: 50, y: 10)); p.addCurve(to: CGPoint(x: 64, y: 22), control1: CGPoint(x: 60, y: 8), control2: CGPoint(x: 66, y: 14)); p.addLine(to: CGPoint(x: 58, y: 40)); p.addLine(to: CGPoint(x: 86, y: 40)); p.addCurve(to: CGPoint(x: 92, y: 52), control1: CGPoint(x: 92, y: 40), control2: CGPoint(x: 94, y: 48)); p.addLine(to: CGPoint(x: 84, y: 82)); p.addCurve(to: CGPoint(x: 74, y: 90), control1: CGPoint(x: 83, y: 87), control2: CGPoint(x: 79, y: 90)); p.addLine(to: CGPoint(x: 32, y: 90)); p.closeSubpath()
            fill(p, color)
        }
    }
}

private func bigBanner(_ c: PCtx, _ title: String, sub: String?, hot: Bool, glyph: ((PCtx, CGRect) -> Void)? = nil, fire: Bool = false, titleSize: CGFloat = 150) {
    let accent = hot ? c.a.hot : c.a.primary
    let bandH: CGFloat = c.h - 70, y0: CGFloat = 35
    let band = c.chamfer(CGRect(x: 20, y: y0, width: c.w - 40, height: bandH), 34, 10, 34, 10)
    c.dropShadow(band, PC.c(PC.s1), dy: 6, blur: 18)
    c.plate(band, tone: 1, seed: 9)
    c.g.saveGState(); c.g.addPath(band); c.g.clip()
    c.grad([(0, PC.c(accent, 0.0)), (1, PC.c(accent, 0.28))], CGPoint(x: 0, y: y0), CGPoint(x: 0, y: y0 + bandH))
    c.g.restoreGState()
    let hz1 = c.chamfer(CGRect(x: 20, y: y0, width: c.w - 40, height: 16), 12, 4, 0, 0), hz2 = c.chamfer(CGRect(x: 20, y: y0 + bandH - 16, width: c.w - 40, height: 16), 0, 0, 12, 4)
    c.hazard(hz1, stripe: 12, c1: hot ? 0xE5261B : 0xF2B705, alpha: 0.95); c.hazard(hz2, stripe: 12, c1: hot ? 0xE5261B : 0xF2B705, alpha: 0.95)
    c.glowStroke(band, PC.c(accent, 0.9), 1.6, radius: 10)
    c.rivets([CGPoint(x: 44, y: c.h / 2), CGPoint(x: c.w - 44, y: c.h / 2)], 4)
    var tx: CGFloat = 60, tw = c.w - 120
    if let glyph { glyph(c, CGRect(x: 56, y: c.h / 2 - 70, width: 140, height: 140)); tx = 210; tw = c.w - 270 }
    let th = sub == nil ? bandH - 50 : bandH - 100
    c.text(title, PFont.headline, size: titleSize, color: PC.white, in: CGRect(x: tx, y: y0 + 20 + (sub == nil ? 12 : 0), width: tw, height: th), track: 4, stencil: true, glow: PC.c(accent, 0.9), glowR: 16, gradient: (PC.white, PC.c(hot ? 0xFFB0A0 : 0xFFE9B0)))
    if let sub { c.text(sub, PFont.tag, size: 34, color: PC.c(accent), in: CGRect(x: tx, y: y0 + bandH - 78, width: tw, height: 40), track: 8, glow: PC.c(accent, 0.6), glowR: 6) }
    if fire { c.fireBed(CGRect(x: 60, y: y0 + 8, width: c.w - 120, height: 40), count: 18, seed: 12, heightScale: 1.3) }
}

func bannerAssets() -> [BuiltinAsset] {
    let C = PropCategory.banners
    var o: [BuiltinAsset] = []
    o.append(asset("banner.nameplate", "Player Name Plate", C, 560, 100, tags: ["nameplate", "player", "team slot"]) { c in
        c.slab(CGRect(x: 8, y: 10, width: 544, height: 80), skew: 22, tone: 0, glowEdge: false)
        let slot = c.chamfer(CGRect(x: 36, y: 22, width: 56, height: 56), 8, 2, 8, 2)
        c.fill(slot, PC.c(PC.s0)); c.glowStroke(slot, PC.c(c.a.primary), 1.6, radius: 5)
        c.fill(c.poly([112, 24, 114, 24, 98, 76, 96, 76]), PC.c(0xFFFFFF, 0.2))
        c.hazard(c.rc(470, 14, 70, 6), stripe: 6, alpha: 0.85)
        c.line([CGPoint(x: 120, y: 78), CGPoint(x: 520, y: 78)], PC.c(c.a.primary, 0.8), 1.5)
    })
    o.append(asset("banner.nameplate.slim", "Slim Name Plate", C, 460, 60, tags: ["nameplate", "slim", "cam"]) { c in
        c.slab(CGRect(x: 6, y: 6, width: 448, height: 48), skew: 14, tone: 1, cap: 8)
        c.fill(c.poly([408, 6, 428, 6, 416, 54, 396, 54]), PC.c(c.a.hot, 0.9))
    })
    o.append(asset("banner.nameplate.big", "Hero Name Plate", C, 700, 130, tags: ["nameplate", "hero", "lower third"]) { c in
        c.slab(CGRect(x: 8, y: 10, width: 684, height: 78), skew: 30, tone: 1, glowEdge: true)
        c.slab(CGRect(x: 8, y: 92, width: 420, height: 30), skew: 16, tone: 0, accent: c.a.hot, cap: 8)
        c.hazard(c.para(CGRect(x: 440, y: 98, width: 90, height: 18), skew: 12), stripe: 8, alpha: 0.9)
    })
    o.append(asset("banner.teamslot", "Team Slot Badge", C, 120, 120, tags: ["team", "logo", "badge", "slot"]) { c in
        let hx = c.hexagon(CGRect(x: 8, y: 14, width: 104, height: 92), cut: 28)
        c.dropShadow(hx, PC.c(PC.s1)); c.plate(hx, tone: 1); c.glowStroke(c.hexagon(CGRect(x: 16, y: 21, width: 88, height: 78), cut: 22), PC.c(c.a.primary), 1.6, radius: 6)
        let star = CGMutablePath(); for k in 0..<10 { let r: CGFloat = k % 2 == 0 ? 26 : 11, a = -CGFloat.pi / 2 + CGFloat(k) * .pi / 5; let pt = CGPoint(x: 60 + cos(a) * r, y: 60 + sin(a) * r); k == 0 ? star.move(to: pt) : star.addLine(to: pt) }; star.closeSubpath()
        c.M(star, c.a.glow, c.a.hot, shadow: false)
    })
    o.append(asset("banner.vs", "Team VS Bar", C, 1200, 150, tags: ["versus", "vs", "match", "teams"]) { c in
        c.slab(CGRect(x: 8, y: 22, width: 560, height: 96), skew: 34, tone: 0, glowEdge: false)
        // right plate mirrored
        c.g.saveGState(); c.g.translateBy(x: c.w, y: 0); c.g.scaleBy(x: -1, y: 1); c.slab(CGRect(x: 8, y: 22, width: 560, height: 96), skew: 34, tone: 0, accent: c.a.hot); c.g.restoreGState()
        c.vsHex(CGPoint(x: 600, y: 75), 62)
        c.hazard(c.rc(120, 24, 80, 6), stripe: 6, alpha: 0.85); c.hazard(c.rc(1000, 24, 80, 6), stripe: 6, alpha: 0.85)
    })
    o.append(asset("banner.vsbadge", "VS Badge", C, 180, 160, tags: ["versus", "vs", "badge"]) { c in c.vsHex(CGPoint(x: 90, y: 80), 70) })
    o.append(asset("banner.scorehead", "Scoreboard Header", C, 980, 84, tags: ["scoreboard", "standings", "header"]) { c in
        c.slab(CGRect(x: 6, y: 6, width: 968, height: 72), skew: 26, tone: 1, glowEdge: true)
        for (t, x, al) in [("RANK", 70.0, Align.center), ("TEAM", 200.0, .left), ("KILLS", 620.0, .center), ("PLACE", 740.0, .center), ("TOTAL", 880.0, .center)] as [(String, CGFloat, Align)] {
            c.text(t, PFont.tag, size: 24, color: PC.c(c.a.primary), in: CGRect(x: x - 40, y: 20, width: al == .left ? 300 : 80, height: 44), align: al, track: 3, glow: PC.c(0, 0.7), glowR: 3) }
    })
    for alt in [false, true] {
        o.append(asset("banner.scorerow\(alt ? ".alt" : "")", "Scoreboard Row\(alt ? " (Alt)" : "")", C, 980, 60, tags: ["scoreboard", "row", "standings"]) { c in
            let p = c.para(CGRect(x: 6, y: 4, width: 968, height: 52), skew: 18)
            c.vgrad(p, [(0, PC.c(alt ? PC.s3 : PC.s2, 0.9)), (1, PC.c(alt ? PC.s2 : PC.s1, 0.9))]); c.stroke(p, PC.c(0xFFFFFF, 0.1), 1)
            c.fill(c.poly([24, 4, 70, 4, 52, 56, 6, 56]), PC.c(alt ? c.a.hot : c.a.primary, 0.9))
        })
    }
    o.append(asset("banner.matchtitle", "Match Title Banner", C, 1040, 130, tags: ["title", "match", "banner"]) { c in
        let r = CGRect(x: 40, y: 18, width: 960, height: 94)
        let p = c.chamfer(r, 30, 8, 30, 8); c.dropShadow(p, PC.c(PC.s1), dy: 5, blur: 14); c.plate(p, tone: 1, seed: 4)
        c.glowStroke(p, PC.c(c.a.primary, 0.9), 1.6, radius: 9)
        for s in [1.0, -1.0] { let x = s > 0 ? 40.0 : 1000.0
            c.fill(c.poly([x, 30, x - s * 38, 30, x - s * 38 - s * 14, 100, x - s * 0, 100]), PC.c(0, 0)); c.hazard(c.poly([x - s * 4, 36, x - s * 36, 36, x - s * 52, 94, x - s * 20, 94]), stripe: 10, alpha: 0.95) }
        c.rivets([CGPoint(x: 70, y: 65), CGPoint(x: 970, y: 65)], 3.5)
    })
    o.append(asset("banner.live", "LIVE Tag", C, 220, 70, tags: ["live", "tag", "on air"]) { c in
        let p = c.para(CGRect(x: 6, y: 8, width: 208, height: 54), skew: 14)
        c.dropShadow(p, PC.c(PC.s0)); c.vgrad(p, [(0, PC.c(0xFF4A38)), (1, PC.c(0xB0100A))]); c.stroke(p, PC.c(0, 0.5), 1.5)
        c.g.saveGState(); c.g.addPath(p); c.g.clip(); c.fill(c.rc(0, 8, 230, 16), PC.c(0xFFFFFF, 0.18)); c.g.restoreGState()
        c.glowFill(c.circle(CGPoint(x: 44, y: 35), 8), PC.white, radius: 8)
        c.text("LIVE", PFont.headline, size: 38, color: PC.white, in: CGRect(x: 62, y: 8, width: 140, height: 54), align: .left, track: 5, shadow: true)
    })
    o.append(asset("banner.next", "NEXT MATCH Strip", C, 700, 72, tags: ["next", "match", "strip", "schedule"]) { c in
        c.slab(CGRect(x: 6, y: 8, width: 688, height: 56), skew: 22, tone: 1)
        let tab = c.para(CGRect(x: 24, y: 8, width: 230, height: 56), skew: 22)
        c.fill(tab, PC.c(c.a.primary)); c.g.saveGState(); c.g.addPath(tab); c.g.clip(); c.fill(c.rc(0, 8, 400, 18), PC.c(0xFFFFFF, 0.18)); c.g.restoreGState()
        c.text("NEXT MATCH", PFont.headline, size: 30, color: PC.c(0x14171B), in: CGRect(x: 50, y: 8, width: 190, height: 56), track: 2)
    })
    o.append(asset("banner.lowerthird", "Lower Third", C, 900, 150, tags: ["lower third", "caption", "title"]) { c in
        c.slab(CGRect(x: 8, y: 12, width: 640, height: 74), skew: 26, tone: 1, glowEdge: true)
        c.slab(CGRect(x: 8, y: 90, width: 520, height: 44), skew: 18, tone: 0, accent: c.a.hot, cap: 8)
        c.hazard(c.para(CGRect(x: 660, y: 40, width: 120, height: 14), skew: 12), stripe: 8, alpha: 0.9)
        c.line([CGPoint(x: 660, y: 62), CGPoint(x: 880, y: 62)], PC.c(c.a.primary, 0.6), 1.2)
    })
    o.append(asset("banner.ticker", "Ticker Strip", C, 1920, 60, tags: ["ticker", "scroll", "news"], maxScale: 1) { c in
        let p = c.rc(0, 6, 1920, 48); c.vgrad(p, [(0, PC.c(PC.s3, 0.95)), (1, PC.c(PC.s0, 0.95))])
        c.line([CGPoint(x: 0, y: 6), CGPoint(x: 1920, y: 6)], PC.c(c.a.primary), 2); c.line([CGPoint(x: 0, y: 54), CGPoint(x: 1920, y: 54)], PC.c(0xFFFFFF, 0.12), 1)
        let lab = c.para(CGRect(x: 0, y: 6, width: 220, height: 48), skew: 20); c.fill(lab, PC.c(c.a.primary))
        c.text("UPDATES", PFont.headline, size: 26, color: PC.c(0x14171B), in: CGRect(x: 8, y: 6, width: 200, height: 48), track: 3)
    })
    o.append(asset("banner.mapname", "Map Name Strip", C, 460, 64, tags: ["map", "location"]) { c in
        c.slab(CGRect(x: 6, y: 6, width: 448, height: 52), skew: 18, tone: 1, cap: 8)
        c.text("MAP", PFont.mono, size: 12, color: PC.c(c.a.primary), in: CGRect(x: 36, y: 8, width: 60, height: 16), align: .left)
    })
    o.append(asset("banner.round", "Round Counter", C, 220, 90, tags: ["round", "counter", "score"]) { c in
        let p = c.chamfer(CGRect(x: 4, y: 4, width: 212, height: 82), 14, 4, 14, 4); c.dropShadow(p, PC.c(PC.s1)); c.plate(p, tone: 1)
        c.glowStroke(c.chamfer(CGRect(x: 10, y: 10, width: 200, height: 70), 10, 2, 10, 2), PC.c(c.a.primary, 0.8), 1.2, radius: 4)
        c.text("ROUND", PFont.tag, size: 16, color: PC.c(c.a.primary), in: CGRect(x: 10, y: 14, width: 200, height: 20), track: 4)
    })
    o.append(asset("banner.scorebox", "Score Tile", C, 130, 110, tags: ["score", "tile", "digit"]) { c in
        let p = c.chamfer(CGRect(x: 4, y: 4, width: 122, height: 102), 14, 4, 14, 4); c.dropShadow(p, PC.c(PC.s1)); c.plate(p, tone: 1)
        c.vgrad(c.chamfer(CGRect(x: 12, y: 12, width: 106, height: 86), 8, 2, 8, 2), [(0, PC.c(0x05080A)), (1, PC.c(0x14181C))]); c.fill(c.rc(4, 100, 122, 3), PC.c(c.a.primary))
    })
    // Social
    let socials: [(String, String)] = [("youtube", "YouTube"), ("instagram", "Instagram"), ("discord", "Discord"), ("twitch", "Twitch")]
    for (i, s) in socials.enumerated() {
        o.append(asset("social.\(s.0)", "\(s.1) Handle Bar", C, 480, 76, tags: ["social", s.0, "handle"]) { c in
            c.slab(CGRect(x: 6, y: 8, width: 468, height: 60), skew: 18, tone: 0, cap: 0)
            c.socialGlyph(i, CGRect(x: 22, y: 12, width: 52, height: 52))
            c.fill(c.poly([86, 8, 90, 8, 78, 68, 74, 68]), PC.c(c.a.primary))
        })
        o.append(asset("social.\(s.0).glyph", "\(s.1) Glyph", C, 128, 128, tags: ["social", s.0, "logo"]) { c in c.socialGlyph(i, CGRect(x: 14, y: 14, width: 100, height: 100)) })
    }
    o.append(asset("banner.sponsor", "Sponsor Strip", C, 640, 100, tags: ["sponsor", "partner", "logo"]) { c in
        c.slab(CGRect(x: 6, y: 8, width: 628, height: 84), skew: 20, tone: 1, cap: 0)
        let slot = c.chamfer(CGRect(x: 360, y: 20, width: 240, height: 60), 8, 2, 8, 2); c.fill(slot, PC.c(0x05080A, 0.8)); c.stroke(slot, PC.c(c.a.primary, 0.7), 1.2)
        c.text("PRESENTED BY", PFont.tag, size: 26, color: PC.c(PC.s6), in: CGRect(x: 40, y: 20, width: 300, height: 60), align: .left, track: 4)
        c.hazard(c.rc(40, 14, 120, 5), stripe: 6, alpha: 0.9)
    })
    o.append(asset("button.subscribe", "Subscribe Button", C, 380, 100, tags: ["subscribe", "button", "youtube", "cta"]) { c in
        let p = c.chamfer(CGRect(x: 6, y: 8, width: 368, height: 80), 14, 4, 14, 4); c.dropShadow(p, PC.c(0, 0.9), dy: 5, blur: 12)
        c.vgrad(p, [(0, PC.c(0xFF4A3A)), (1, PC.c(0xB0100A))]); c.stroke(p, PC.c(0, 0.5), 2); c.g.saveGState(); c.g.addPath(p); c.g.clip(); c.fill(c.rc(0, 8, 400, 28), PC.c(0xFFFFFF, 0.16)); c.g.restoreGState()
        c.bell(CGPoint(x: 56, y: 46), 22)
        c.text("SUBSCRIBE", PFont.headline, size: 42, color: PC.white, in: CGRect(x: 90, y: 8, width: 270, height: 80), track: 3, shadow: true)
    })
    o.append(asset("button.like", "Like Button", C, 240, 100, tags: ["like", "button", "cta"]) { c in
        let p = c.chamfer(CGRect(x: 6, y: 8, width: 228, height: 80), 14, 4, 14, 4); c.dropShadow(p, PC.c(0, 0.9), dy: 5, blur: 12)
        c.plate(p, tone: 1); c.glowStroke(p, PC.c(c.a.primary, 0.9), 1.6, radius: 8); c.thumb(CGRect(x: 24, y: 26, width: 44, height: 44), color: PC.c(c.a.primary))
        c.text("LIKE", PFont.headline, size: 40, color: PC.white, in: CGRect(x: 80, y: 8, width: 140, height: 80), track: 3, shadow: true)
    })
    o.append(asset("button.follow", "Follow Button", C, 300, 100, tags: ["follow", "button", "cta"]) { c in
        let p = c.chamfer(CGRect(x: 6, y: 8, width: 288, height: 80), 14, 4, 14, 4); c.dropShadow(p, PC.c(0, 0.9), dy: 5, blur: 12)
        c.vgrad(p, [(0, PC.c(c.a.primary)), (1, PC.c(c.a.hot))]); c.stroke(p, PC.c(0, 0.5), 2); c.g.saveGState(); c.g.addPath(p); c.g.clip(); c.fill(c.rc(0, 8, 400, 28), PC.c(0xFFFFFF, 0.18)); c.g.restoreGState()
        c.text("FOLLOW", PFont.headline, size: 42, color: PC.white, in: CGRect(x: 6, y: 8, width: 288, height: 80), track: 4, shadow: true)
    })
    // Baked big banners
    o.append(asset("banner.brb", "BRB", C, 1000, 280, tags: ["brb", "be right back", "break"]) { c in bigBanner(c, "BE RIGHT BACK", sub: "STREAM WILL RESUME SHORTLY", hot: false, titleSize: 120) })
    o.append(asset("banner.startingsoon", "STARTING SOON", C, 1100, 280, tags: ["starting soon", "intro", "countdown"]) { c in bigBanner(c, "STARTING SOON", sub: "STAND BY - DROP INCOMING", hot: false, fire: true, titleSize: 130) })
    o.append(asset("banner.gameover", "GAME OVER", C, 1000, 280, tags: ["game over", "end"]) { c in bigBanner(c, "GAME OVER", sub: "BETTER LUCK NEXT DROP", hot: true, titleSize: 140) })
    o.append(asset("banner.eliminated", "ELIMINATED", C, 1000, 260, tags: ["eliminated", "death", "out"]) { c in
        bigBanner(c, "ELIMINATED", sub: nil, hot: true, glyph: { c, r in drawSkull(c, center: CGPoint(x: r.midX, y: r.midY), size: 120, color: PC.c(c.a.hot)) }, titleSize: 140)
    })
    o.append(asset("banner.chickendinner", "WINNER WINNER CHICKEN DINNER", C, 1200, 300, tags: ["winner", "chicken dinner", "win", "victory"]) { c in
        bigBanner(c, "CHICKEN DINNER", sub: "WINNER WINNER", hot: false, glyph: { c, r in
            if let a = PropsCatalog.byID["icon.chicken"] { c.g.saveGState(); c.g.translateBy(x: 0, y: 0); c.g.draw(a.image(scale: 1, theme: c.a), in: CGRect(x: r.minX - 10, y: r.minY - 10, width: r.width + 30, height: r.height + 30)); c.g.restoreGState() } }, titleSize: 140)
    })
    o.append(asset("banner.squadwipe", "SQUAD WIPE", C, 1000, 280, tags: ["squad wipe", "wipe", "kill"]) { c in
        bigBanner(c, "SQUAD WIPE", sub: "ALL ENEMIES DOWN", hot: true, glyph: { c, r in drawSkull(c, center: CGPoint(x: r.midX, y: r.midY), size: 120, color: PC.c(c.a.hot)) }, fire: true, titleSize: 140)
    })
    for n in 2...5 {
        o.append(asset("banner.kill\(n)", "KILL x\(n)", C, 520, 150, tags: ["kill", "streak", "x\(n)"]) { c in
            let p = c.chamfer(CGRect(x: 10, y: 20, width: 500, height: 112), 24, 6, 24, 6)
            c.dropShadow(p, PC.c(PC.s1), dy: 5, blur: 14); c.plate(p, tone: 1, seed: UInt64(n)); c.glowStroke(p, PC.c(c.a.hot, 0.9), 1.8, radius: 10)
            c.g.saveGState(); c.g.addPath(p); c.g.clip(); c.grad([(0, PC.c(c.a.hot, 0.45)), (0.6, PC.c(c.a.hot, 0))], CGPoint(x: 10, y: 0), CGPoint(x: 300, y: 0)); c.g.restoreGState()
            drawSkull(c, center: CGPoint(x: 80, y: 76), size: 78, color: PC.white)
            c.text("KILL", PFont.headline, size: 78, color: PC.white, in: CGRect(x: 140, y: 26, width: 210, height: 100), align: .left, track: 3, stencil: true, shadow: true)
            c.text("x\(n)", PFont.italic, size: 90, color: PC.c(c.a.glow), in: CGRect(x: 340, y: 22, width: 160, height: 108), align: .left, glow: PC.c(c.a.primary), glowR: 12, gradient: (PC.c(c.a.glow), PC.c(c.a.primary)))
        })
    }
    return o
}
