// "OPUS Advanced Studio" built-in art: AirBattleground logos (extracted from the brand key art) and the luxury
// black / gunmetal / gold / crimson broadcast kit (plates, dial, cards, crown, rows). All CoreGraphics, theme-independent.
import Foundation
import CoreGraphics
import ImageIO

/// AirBattleground palette.
enum ABG {
    static let gold1: UInt32 = 0xF7E39A, gold2: UInt32 = 0xD4A845, gold3: UInt32 = 0x8A6420
    static let red: UInt32 = 0xE0141E, black: UInt32 = 0x050506, gun: UInt32 = 0x15181C, gun2: UInt32 = 0x23272D
    static var gold1C: RGBA { RGBA(hex: gold1) }
    static var gold2C: RGBA { RGBA(hex: gold2) }
    static var gold3C: RGBA { RGBA(hex: gold3) }
    static var redC: RGBA { RGBA(hex: red) }
    /// Metallic gold ramp (top -> bottom) used by plates and text.
    static let metal: [(CGFloat, UInt32)] = [(0, 0xFBF0C0), (0.32, 0xEDCD72), (0.5, 0xD4A845), (0.53, 0xB8892F), (0.82, 0x8A6420), (1, 0xC69B45)]
    static func metalCG(_ a: CGFloat = 1) -> [(CGFloat, CGColor)] { metal.map { ($0.0, PC.c($0.1, a)) } }
}

enum AdvancedStudioAssets {
    // MARK: logo images (decoded once)
    private static func decode(_ b64: String) -> CGImage? {
        guard let d = Data(base64Encoded: b64), let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    nonisolated(unsafe) static let logoFull = decode(ABGLogoData.full)
    nonisolated(unsafe) static let logoMark = decode(ABGLogoData.mark)
    nonisolated(unsafe) static let logoWord = decode(ABGLogoData.wordmark)

    /// Draws a CGImage into the (flipped, top-left origin) asset context.
    static func drawImage(_ img: CGImage?, _ c: PCtx, _ r: CGRect) {
        guard let img else { return }
        c.g.saveGState()
        c.g.interpolationQuality = .high
        c.g.translateBy(x: r.minX, y: r.maxY); c.g.scaleBy(x: 1, y: -1)
        c.g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        c.g.restoreGState()
    }

    static func all() -> [BuiltinAsset] {
        var a: [BuiltinAsset] = []
        func logo(_ id: String, _ name: String, _ img: CGImage?) {
            let w = CGFloat(img?.width ?? 400), h = CGFloat(img?.height ?? 120)
            a.append(asset(id, name, .icons, w, h, tags: ["airbattleground", "abg", "logo", "brand"], maxScale: 2, themed: false) { c in drawImage(img, c, c.rect) })
        }
        logo("abg.logo.full", "AirBattleground Logo", logoFull)
        logo("abg.logo.mark", "AirBattleground AB Mark", logoMark)
        logo("abg.logo.wordmark", "AirBattleground Wordmark", logoWord)

        a.append(asset("adv.bg.luxe", "OPUS Luxe Background", .backgrounds, 1920, 1080, tags: ["opus", "gold", "black", "luxury"], maxScale: 1, themed: false, luxeBackground))
        a.append(asset("adv.bg.winner", "OPUS Winner Background", .backgrounds, 1920, 1080, tags: ["opus", "gold", "red", "winner"], maxScale: 1, themed: false, winnerBackground))
        a.append(asset("adv.panel.gold", "OPUS Gold Panel", .banners, 1000, 1080, tags: ["opus", "gold", "panel"], maxScale: 1, themed: false, goldPanel))
        a.append(asset("adv.dial.face", "OPUS Dial Face", .hud, 640, 640, tags: ["opus", "dial", "countdown"], themed: false, dialFace))
        a.append(asset("adv.crown", "OPUS Crown", .icons, 360, 240, tags: ["opus", "crown", "winner"], themed: false, crown))
        a.append(asset("adv.hex.slot", "OPUS Logo Slot", .frames, 320, 320, tags: ["opus", "hex", "logo"], themed: false, hexSlot))
        a.append(asset("adv.card.player", "OPUS Player Card", .frames, 340, 430, tags: ["opus", "card", "player"], themed: false, playerCard))
        a.append(asset("adv.frame.mvp", "OPUS MVP Frame", .frames, 560, 720, tags: ["opus", "mvp", "frame"], themed: false, mvpFrame))
        a.append(asset("adv.social", "OPUS Social Strip", .banners, 560, 64, tags: ["opus", "social"], themed: false, socialStrip))
        a.append(asset("adv.live", "OPUS LIVE Tag", .hud, 150, 46, tags: ["opus", "live"], themed: false, liveTag))
        for (id, tone) in [("adv.row.gold", 1), ("adv.row.silver", 2), ("adv.row.bronze", 3), ("adv.row.dark", 0)] {
            a.append(asset(id, "OPUS Standings Row \(tone)", .banners, 600, 64, tags: ["opus", "row", "standings"], themed: false) { c in row(c, tone: tone) })
        }
        for (w, h) in plateSizes {
            a.append(asset("adv.plate.\(Int(w))x\(Int(h))", "OPUS Plate \(Int(w))x\(Int(h))", .banners, w, h, tags: ["opus", "plate"], themed: false) { c in plate(c) })
        }
        for (w, h) in goldPlateSizes {
            a.append(asset(goldPlateID(Double(w), Double(h)), "OPUS Gold Plate \(Int(w))x\(Int(h))", .banners, w, h, tags: ["opus", "plate", "gold"], themed: false) { c in goldPlate(c) })
        }
        return a
    }
    /// Dark chamfered plates in the exact sizes the scenes use (corners never stretch).
    static let plateSizes: [(CGFloat, CGFloat)] = [(520, 84), (820, 70), (460, 60), (330, 64), (700, 90), (240, 64), (600, 44)]
    static func plateID(_ w: Double, _ h: Double) -> String { "adv.plate.\(Int(w))x\(Int(h))" }
    static let goldPlateSizes: [(CGFloat, CGFloat)] = [(170, 84), (300, 56), (170, 70), (330, 64), (420, 64), (360, 60), (1120, 130)]
    static func goldPlateID(_ w: Double, _ h: Double) -> String { "adv.plate.gold.\(Int(w))x\(Int(h))" }

    // MARK: art

    static func luxeBackground(_ c: PCtx) {
        let r = c.rect
        c.fill(CGPath(rect: r, transform: nil), PC.c(0x040405))
        c.radial(CGPoint(x: r.midX * 0.9, y: r.midY * 0.95), 0, 1150, [(0, PC.c(0x22252B)), (0.45, PC.c(0x111317)), (1, PC.c(0x040405))])
        // brushed carbon diagonal weave
        c.g.saveGState()
        var y: CGFloat = -1920
        var rng = PRNG(41)
        while y < 1080 {
            let p = c.poly([CGPoint(x: 0, y: y), CGPoint(x: 1920, y: y + 1920 * 0.55), CGPoint(x: 1920, y: y + 1920 * 0.55 + 2), CGPoint(x: 0, y: y + 2)])
            c.fill(p, PC.c(0xFFFFFF, rng.r(0.006, 0.02)))
            y += 6
        }
        c.g.restoreGState()
        // faint big diagonal facets like the key art
        let facets: [[CGFloat]] = [[0, 0, 640, 0, 120, 1080, 0, 1080], [1500, 0, 1920, 0, 1920, 1080, 1060, 1080]]
        for (i, f) in facets.enumerated() {
            c.vgrad(c.poly(f), [(0, PC.c(0xFFFFFF, i == 0 ? 0.035 : 0.025)), (1, PC.c(0xFFFFFF, 0.0))])
        }
        // thin gold + red slash accents at the edges
        for (pts, col, a) in [([CGFloat(70), 1080, 420, 0, 428, 0, 78, 1080], ABG.gold2, 0.35), ([CGFloat(120), 1080, 470, 0, 474, 0, 124, 1080], ABG.red, 0.45),
                              ([CGFloat(1820), 0, 1470, 1080, 1476, 1080, 1826, 0], ABG.gold2, 0.3)] as [([CGFloat], UInt32, CGFloat)] {
            c.g.saveGState(); c.setGlow(PC.c(col, a), 10); c.fill(c.poly(pts), PC.c(col, a)); c.g.restoreGState()
        }
        // vignette
        c.radial(CGPoint(x: r.midX, y: r.midY), 500, 1250, [(0, PC.c(0, 0)), (1, PC.c(0, 0.75))])
    }

    static func winnerBackground(_ c: PCtx) {
        let r = c.rect
        c.fill(CGPath(rect: r, transform: nil), PC.c(0x030303))
        c.radial(CGPoint(x: r.midX, y: 470), 0, 1100, [(0, PC.c(0x3A2A10)), (0.3, PC.c(0x1C140A)), (0.62, PC.c(0x0C0607)), (1, PC.c(0x030303))])
        c.radial(CGPoint(x: r.midX, y: 1180), 0, 900, [(0, PC.c(ABG.red, 0.28)), (1, PC.c(ABG.red, 0))])
        // radiating sunburst wedges (static; god rays animate above)
        c.g.saveGState()
        let ctr = CGPoint(x: r.midX, y: 470)
        for i in 0..<36 {
            let a0 = CGFloat(i) * .pi * 2 / 36, a1 = a0 + .pi / 72
            let p = c.poly([ctr, CGPoint(x: ctr.x + cos(a0) * 2400, y: ctr.y + sin(a0) * 2400), CGPoint(x: ctr.x + cos(a1) * 2400, y: ctr.y + sin(a1) * 2400)])
            c.fill(p, PC.c(ABG.gold2, 0.035))
        }
        c.g.restoreGState()
        c.radial(CGPoint(x: r.midX, y: r.midY), 420, 1200, [(0, PC.c(0, 0)), (1, PC.c(0, 0.8))])
    }

    static func goldPanel(_ c: PCtx) {
        // slanted gold slab: left edge leans like the key art
        let p = c.poly([CGPoint(x: 330, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 1000, y: 1080), CGPoint(x: 0, y: 1080)])
        c.grad([(0, PC.c(0xF6DE8E)), (0.35, PC.c(0xE2BD62)), (0.6, PC.c(0xC99B3E)), (1, PC.c(0x9C7128))], CGPoint(x: 200, y: 0), CGPoint(x: 900, y: 1080), clip: p)
        // diagonal satin sheen bands
        c.g.saveGState(); c.g.addPath(p); c.g.clip()
        for (x0, w, a) in [(CGFloat(250), CGFloat(220), CGFloat(0.22)), (560, 90, 0.16), (760, 320, 0.10)] {
            let band = c.poly([CGPoint(x: x0 + 330, y: 0), CGPoint(x: x0 + 330 + w, y: 0), CGPoint(x: x0 + w, y: 1080), CGPoint(x: x0, y: 1080)])
            c.hgrad(band, [(0, PC.c(0xFFFFFF, 0)), (0.5, PC.c(0xFFF8E0, a)), (1, PC.c(0xFFFFFF, 0))])
        }
        c.brushed(p, alpha: 0.05, seed: 11)
        c.g.restoreGState()
        // dark bevel + red edge stripe
        let edge = c.poly([CGPoint(x: 330, y: 0), CGPoint(x: 346, y: 0), CGPoint(x: 16, y: 1080), CGPoint(x: 0, y: 1080)])
        c.fill(edge, PC.c(0x2A1E0A, 0.85))
        c.innerShadow(p, blur: 30, alpha: 0.35)
    }

    static func dialFace(_ c: PCtx) {
        let ctr = CGPoint(x: 320, y: 320)
        // outer metallic bevel ring
        c.g.saveGState(); c.g.setShadow(offset: CGSize(width: 0, height: -10 * c.scale), blur: 30 * c.scale, color: PC.c(0, 0.7))
        c.fill(c.circle(ctr, 312), PC.c(0x0B0B0C)); c.g.restoreGState()
        c.grad(ABG.metalCG(), CGPoint(x: 320, y: 8), CGPoint(x: 320, y: 632), clip: c.ringPath(c.circle(ctr, 312), c.circle(ctr, 296)), evenOdd: true)
        c.grad([(0, PC.c(0x3A2C12)), (1, PC.c(0x0D0B07))], CGPoint(x: 320, y: 20), CGPoint(x: 320, y: 620), clip: c.ringPath(c.circle(ctr, 296), c.circle(ctr, 288)), evenOdd: true)
        // glossy black face
        c.radial(CGPoint(x: 320, y: 250), 0, 300, [(0, PC.c(0x26282C)), (0.55, PC.c(0x111214)), (1, PC.c(0x060607))], clip: c.circle(ctr, 288))
        // inner gold hairline + printed fine ticks
        c.stroke(c.circle(ctr, 228), PC.c(ABG.gold2, 0.55), 1.5)
        c.stroke(c.circle(ctr, 206), PC.c(ABG.gold3, 0.45), 1)
        for i in 0..<60 {
            let a = CGFloat(i) / 60 * .pi * 2
            let r0: CGFloat = i % 5 == 0 ? 236 : 242, r1: CGFloat = 252
            let p = CGMutablePath(); p.move(to: CGPoint(x: ctr.x + sin(a) * r0, y: ctr.y - cos(a) * r0)); p.addLine(to: CGPoint(x: ctr.x + sin(a) * r1, y: ctr.y - cos(a) * r1))
            c.stroke(p, PC.c(i % 5 == 0 ? ABG.gold1 : ABG.gold3, i % 5 == 0 ? 0.8 : 0.5), i % 5 == 0 ? 2.5 : 1.2)
        }
        // glass highlight
        c.g.saveGState(); c.g.addPath(c.circle(ctr, 286)); c.g.clip()
        let gl = CGMutablePath(); gl.addEllipse(in: CGRect(x: 60, y: -140, width: 520, height: 420))
        c.vgrad(gl, [(0, PC.c(0xFFFFFF, 0.10)), (1, PC.c(0xFFFFFF, 0))])
        c.g.restoreGState()
        // red marker at 12 o'clock
        c.glowFill(c.poly([CGPoint(x: 312, y: 30), CGPoint(x: 328, y: 30), CGPoint(x: 320, y: 46)]), PC.c(ABG.red), radius: 8)
    }

    static func crown(_ c: PCtx) {
        let pts: [CGPoint] = [CGPoint(x: 30, y: 200), CGPoint(x: 18, y: 70), CGPoint(x: 100, y: 140), CGPoint(x: 180, y: 28),
                              CGPoint(x: 260, y: 140), CGPoint(x: 342, y: 70), CGPoint(x: 330, y: 200)]
        let body = c.poly(pts)
        c.g.saveGState(); c.setGlow(PC.c(ABG.gold2, 0.8), 18); c.fill(body, PC.c(ABG.gold2)); c.g.restoreGState()
        c.grad(ABG.metalCG(), CGPoint(x: 180, y: 28), CGPoint(x: 180, y: 200), clip: body)
        let band = c.chamfer(CGRect(x: 26, y: 184, width: 308, height: 40), 8)
        c.grad(ABG.metalCG(), CGPoint(x: 180, y: 184), CGPoint(x: 180, y: 224), clip: band)
        c.stroke(band, PC.c(0x3A2808, 0.8), 2); c.stroke(body, PC.c(0x3A2808, 0.8), 2)
        for (p, r) in [(CGPoint(x: 18, y: 66), CGFloat(13)), (CGPoint(x: 180, y: 24), 16), (CGPoint(x: 342, y: 66), 13)] {
            c.radial(p, 0, r, [(0, PC.c(0xFFF6D0)), (0.6, PC.c(ABG.gold2)), (1, PC.c(ABG.gold3))], clip: c.circle(p, r))
        }
        for x in [CGFloat(110), 180, 250] {
            let gem = c.poly([CGPoint(x: x, y: 190), CGPoint(x: x + 12, y: 204), CGPoint(x: x, y: 218), CGPoint(x: x - 12, y: 204)])
            c.glowFill(gem, PC.c(ABG.red), radius: 6); c.fill(c.poly([CGPoint(x: x, y: 192), CGPoint(x: x + 6, y: 202), CGPoint(x: x - 4, y: 200)]), PC.c(0xFFFFFF, 0.6))
        }
    }

    static func hexSlot(_ c: PCtx) {
        func hex(_ r: CGFloat) -> CGPath {
            c.poly((0..<6).map { i -> CGPoint in let a = CGFloat(i) * .pi / 3 - .pi / 2; return CGPoint(x: 160 + cos(a) * r, y: 160 + sin(a) * r) })
        }
        c.g.saveGState(); c.setGlow(PC.c(ABG.gold2, 0.6), 22); c.fill(hex(150), PC.c(0x0A0A0B)); c.g.restoreGState()
        c.grad(ABG.metalCG(), CGPoint(x: 160, y: 10), CGPoint(x: 160, y: 310), clip: c.ringPath(hex(150), hex(136)), evenOdd: true)
        c.radial(CGPoint(x: 160, y: 130), 0, 150, [(0, PC.c(0x23252A)), (1, PC.c(0x08090A))], clip: hex(134))
        c.stroke(hex(124), PC.c(ABG.gold3, 0.6), 1.5)
    }

    static func playerCard(_ c: PCtx) {
        let r = CGRect(x: 6, y: 6, width: 328, height: 418)
        let p = c.chamfer(r, 26, 0, 26, 0)
        c.dropShadow(p, PC.c(0x0A0B0D), dy: 10, blur: 24, alpha: 0.7)
        c.vgrad(p, [(0, PC.c(0x24272D)), (0.55, PC.c(0x111316)), (1, PC.c(0x07080A))])
        c.brushed(p, alpha: 0.05, seed: 21)
        c.radial(CGPoint(x: 170, y: 150), 0, 190, [(0, PC.c(ABG.gold2, 0.16)), (1, PC.c(ABG.gold2, 0))], clip: p)
        // gold frame
        c.g.saveGState(); c.g.addPath(p); c.g.setLineWidth(5); c.g.replacePathWithStrokedPath(); c.g.clip()
        c.grad(ABG.metalCG(), CGPoint(x: 0, y: 0), CGPoint(x: 340, y: 430)); c.g.restoreGState()
        // top accent bar + red notch
        c.grad(ABG.metalCG(), CGPoint(x: 0, y: 6), CGPoint(x: 0, y: 14), clip: c.chamfer(CGRect(x: 32, y: 6, width: 220, height: 8), 0, 0, 8, 0))
        c.fill(c.poly([CGPoint(x: 258, y: 6), CGPoint(x: 300, y: 6), CGPoint(x: 292, y: 14), CGPoint(x: 250, y: 14)]), PC.c(ABG.red))
        // stat zone divider
        c.hgrad(CGPath(rect: CGRect(x: 26, y: 300, width: 288, height: 2), transform: nil), [(0, PC.c(ABG.gold2, 0)), (0.5, PC.c(ABG.gold2, 0.9)), (1, PC.c(ABG.gold2, 0))])
        c.fill(CGPath(rect: CGRect(x: 169, y: 318, width: 2, height: 84), transform: nil), PC.c(ABG.gold3, 0.6))
    }

    static func mvpFrame(_ c: PCtx) {
        let r = CGRect(x: 10, y: 10, width: 540, height: 700)
        let p = c.chamfer(r, 40, 0, 40, 0)
        c.dropShadow(p, PC.c(0x0A0B0D), dy: 12, blur: 30, alpha: 0.75)
        c.vgrad(p, [(0, PC.c(0x2A2418)), (0.35, PC.c(0x15161A)), (1, PC.c(0x08090B))])
        c.radial(CGPoint(x: 280, y: 250), 0, 330, [(0, PC.c(ABG.gold2, 0.22)), (1, PC.c(ABG.gold2, 0))], clip: p)
        if let m = logoMark {
            c.g.saveGState(); c.g.addPath(p); c.g.clip(); c.g.setAlpha(0.10)
            drawImage(m, c, CGRect(x: 40, y: 90, width: 480, height: 254)); c.g.restoreGState()
        }
        c.g.saveGState(); c.g.addPath(p); c.g.setLineWidth(8); c.g.replacePathWithStrokedPath(); c.g.clip()
        c.grad(ABG.metalCG(), CGPoint(x: 0, y: 0), CGPoint(x: 560, y: 720)); c.g.restoreGState()
        c.stroke(c.chamfer(r.insetBy(dx: 16, dy: 16), 30, 0, 30, 0), PC.c(ABG.gold3, 0.55), 1.5)
        // corner ornaments
        for (x, y, sx, sy) in [(CGFloat(26), CGFloat(686), CGFloat(1), CGFloat(-1)), (534, 34, -1, 1)] {
            c.line([CGPoint(x: x, y: y + sy * 70), CGPoint(x: x, y: y), CGPoint(x: x + sx * 70, y: y)], PC.c(ABG.gold1), 4)
        }
        // stat area band
        c.vgrad(CGPath(rect: CGRect(x: 26, y: 520, width: 508, height: 170), transform: nil), [(0, PC.c(0, 0.0)), (1, PC.c(0, 0.45))])
        c.hgrad(CGPath(rect: CGRect(x: 40, y: 520, width: 480, height: 2), transform: nil), [(0, PC.c(ABG.gold2, 0)), (0.5, PC.c(ABG.gold2, 1)), (1, PC.c(ABG.gold2, 0))])
        c.fill(CGPath(rect: CGRect(x: 279, y: 545, width: 2, height: 120), transform: nil), PC.c(ABG.gold3, 0.7))
    }

    static func socialStrip(_ c: PCtx) {
        let r = CGRect(x: 2, y: 2, width: 556, height: 60)
        let p = c.para(r, skew: 22)
        c.fill(p, PC.c(0x0A0B0D, 0.75))
        c.g.saveGState(); c.g.addPath(p); c.g.setLineWidth(2); c.g.replacePathWithStrokedPath(); c.g.clip()
        c.hgrad(CGPath(rect: r, transform: nil), [(0, PC.c(ABG.gold2, 0.9)), (0.7, PC.c(ABG.gold3, 0.5)), (1, PC.c(ABG.red, 0.9))]); c.g.restoreGState()
        let gold = PC.c(ABG.gold1)
        // instagram
        let ig = CGRect(x: 44, y: 16, width: 30, height: 30)
        c.stroke(c.rrect(ig, 9), gold, 2.6); c.stroke(c.circle(CGPoint(x: ig.midX, y: ig.midY), 7), gold, 2.6); c.fill(c.circle(CGPoint(x: ig.maxX - 7, y: ig.minY + 7), 2), gold)
        // youtube
        let yt = CGRect(x: 96, y: 18, width: 38, height: 27)
        c.fill(c.rrect(yt, 8), gold); c.fill(c.poly([CGPoint(x: 110, y: 24), CGPoint(x: 122, y: 31.5), CGPoint(x: 110, y: 39)]), PC.c(0x0A0B0D))
        // globe
        let gc = CGPoint(x: 172, y: 31)
        c.stroke(c.circle(gc, 14), gold, 2.4); c.stroke(CGPath(ellipseIn: CGRect(x: gc.x - 6, y: gc.y - 14, width: 12, height: 28), transform: nil), gold, 2)
        c.line([CGPoint(x: gc.x - 14, y: gc.y), CGPoint(x: gc.x + 14, y: gc.y)], gold, 2)
        c.fill(CGPath(rect: CGRect(x: 206, y: 16, width: 2, height: 30), transform: nil), PC.c(ABG.gold3, 0.8))
    }

    static func liveTag(_ c: PCtx) {
        let p = c.chamfer(CGRect(x: 2, y: 2, width: 146, height: 42), 10, 0, 10, 0)
        c.g.saveGState(); c.setGlow(PC.c(ABG.red, 0.8), 12); c.fill(p, PC.c(ABG.red)); c.g.restoreGState()
        c.vgrad(p, [(0, PC.c(0xFF4A4F)), (0.5, PC.c(ABG.red)), (1, PC.c(0x9A0A10))])
        c.fill(c.circle(CGPoint(x: 30, y: 23), 7), PC.c(0xFFFFFF))
        c.text("LIVE", [PFont.resolve(["AvenirNextCondensed-HeavyItalic", "Impact"])], size: 30, color: PC.white, in: CGRect(x: 44, y: 4, width: 96, height: 38), align: .center)
    }

    static func row(_ c: PCtx, tone: Int) {
        let r = CGRect(x: 1, y: 2, width: 598, height: 60)
        let p = c.para(r, skew: 16)
        c.vgrad(p, tone == 0 ? [(0, PC.c(0x1C1F24, 0.92)), (1, PC.c(0x0C0D10, 0.92))] : [(0, PC.c(0x2A2620, 0.95)), (1, PC.c(0x111013, 0.95))])
        let tint: [(CGFloat, UInt32)] = tone == 1 ? ABG.metal : tone == 2 ? [(0, 0xFFFFFF), (0.5, 0xC9CED6), (0.52, 0x9AA2AD), (1, 0xD8DCE2)]
            : tone == 3 ? [(0, 0xF6C79A), (0.5, 0xC27A3E), (0.52, 0x9A5A28), (1, 0xD08E55)] : [(0, 0x3A3F47), (1, 0x22262B)]
        // rank block
        let blk = c.para(CGRect(x: 1, y: 2, width: 80, height: 60), skew: 16)
        c.grad(tint.map { ($0.0, PC.c($0.1)) }, CGPoint(x: 0, y: 2), CGPoint(x: 0, y: 62), clip: blk)
        // top hairline
        let hair = CGPath(rect: CGRect(x: 14, y: 2, width: 584, height: 1.5), transform: nil)
        c.hgrad(hair, [(0, PC.c(tone == 0 ? 0x5A6068 : (tone == 2 ? 0xE6E9EE : tone == 3 ? 0xE0A070 : ABG.gold1), 0.9)), (1, PC.c(0xFFFFFF, 0))])
        if tone != 0 { c.hgrad(p, [(0, PC.c(tint[2].1, 0.22)), (0.6, PC.c(tint[2].1, 0.0))]) }
        // total cell
        let tot = c.para(CGRect(x: 494, y: 2, width: 105, height: 60), skew: 16)
        c.fill(tot, PC.c(tone == 0 ? 0x2A2E35 : 0x3A2E14, 0.85))
    }

    static func plate(_ c: PCtx) {
        let r = c.rect.insetBy(dx: 2, dy: 2)
        let cut = min(18, r.height * 0.3)
        let p = c.chamfer(r, cut, 0, cut, 0)
        c.vgrad(p, [(0, PC.c(0x1E2126, 0.94)), (0.5, PC.c(0x121418, 0.94)), (1, PC.c(0x08090B, 0.94))])
        c.brushed(p, alpha: 0.04, seed: 5)
        c.g.saveGState(); c.g.addPath(p); c.g.setLineWidth(2.5); c.g.replacePathWithStrokedPath(); c.g.clip()
        c.hgrad(CGPath(rect: c.rect, transform: nil), [(0, PC.c(ABG.gold1)), (0.5, PC.c(ABG.gold3, 0.7)), (1, PC.c(ABG.gold2))]); c.g.restoreGState()
        // red notch on the bottom-left chamfer and a gold pin stripe
        c.fill(c.poly([CGPoint(x: r.minX, y: r.maxY - cut), CGPoint(x: r.minX + cut, y: r.maxY), CGPoint(x: r.minX + cut + 26, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - cut - 26)]), PC.c(ABG.red))
        c.hgrad(CGPath(rect: CGRect(x: r.minX + cut + 10, y: r.minY + 6, width: r.width * 0.4, height: 1.5), transform: nil), [(0, PC.c(ABG.gold1, 0.7)), (1, PC.c(ABG.gold1, 0))])
    }

    static func goldPlate(_ c: PCtx) {
        let r = c.rect.insetBy(dx: 1, dy: 1)
        let cut = min(14, r.height * 0.3)
        let p = c.chamfer(r, cut, 0, cut, 0)
        c.grad(ABG.metalCG(), CGPoint(x: 0, y: r.minY), CGPoint(x: 0, y: r.maxY), clip: p)
        c.stroke(p, PC.c(0x4A3510, 0.9), 1.5)
        c.hgrad(CGPath(rect: CGRect(x: r.minX + cut, y: r.minY + 3, width: r.width - cut * 2, height: 2), transform: nil), [(0, PC.c(0xFFFFFF, 0)), (0.5, PC.c(0xFFFFFF, 0.7)), (1, PC.c(0xFFFFFF, 0))])
    }
}
