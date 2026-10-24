// CoreGraphics art for the Team Status board, after the "AirBattleground Gold Esports Leaderboard" reference (837 x 1879):
// AB monogram | gold divider | AIRBATTLEGROUND wordmark (the real logo assets), a dark slanted social strip with a red slash,
// dark textured background with gold corner beams and red slashes, gold table head (# | TEAM | FIN. | TOT. PTS. | STATUS),
// alternating near-black / navy rows with angled rank boxes, logo boxes, FIN. / TOT. PTS. values and 4 player bars, and a
// double gold rule closing the panel. Everything is drawn in reference units (TeamBoardLayout), uniformly scaled.
// Pure functions, run off the render thread by the sprite store. The strip content (social handle / match title) is a
// separate sprite (slide(_:w:h:)) cross-faded by the renderer.
import Foundation
import CoreGraphics
import CoreText
import ImageIO

enum TeamBoardArt {
    // MARK: palette

    static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { Art.color(hex, a) }
    static func gradient(_ stops: [(CGFloat, UInt32)], alpha: CGFloat = 1) -> CGGradient {
        let comps = stops.flatMap { s -> [CGFloat] in let v = s.1; return [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, alpha] }
        return CGGradient(colorSpace: Art.cs, colorComponents: comps, locations: stops.map(\.0), count: stops.count)!
    }
    /// Polished gold (slabs, beams).
    static let gold = gradient([(0, 0xFFF1BE), (0.22, 0xF0CB6E), (0.5, 0xC28F35), (0.74, 0xE8C066), (1, 0x8A5F17)])
    /// Table head: left -> right lighting as in the reference.
    static let headGold = gradient([(0, 0xCF9B41), (0.12, 0xDDAC4F), (0.26, 0xF7CD71), (0.42, 0xE3B358), (0.47, 0xE6B85C), (0.62, 0xF0C56B),
                                    (0.74, 0xF6CB72), (0.86, 0xE9BA5D), (1, 0xD9A645)])
    static let goldLine = c(0xD9B25E)
    static let rowA0: UInt32 = 0x121314, rowA1: UInt32 = 0x0D0F10
    static let rowB0: UInt32 = 0x0F1620, rowB1: UInt32 = 0x16202C
    static let cream = c(0xF3E8C8)
    static let ink = c(0x130C02)

    // MARK: fonts (best installed one wins)

    static func firstFont(_ names: [String], size: CGFloat) -> CTFont {
        for n in names {
            let f = CTFontCreateWithName(n as CFString, size, nil)
            if (CTFontCopyPostScriptName(f) as String) == n { return f }
        }
        return CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, size, nil)
    }
    /// Squared bold display face: table head labels, rank numbers, FIN. / TOT. PTS. values.
    static func labelFont(_ s: CGFloat) -> CTFont { firstFont(["DINAlternate-Bold", "AvenirNextCondensed-Heavy", "Futura-CondensedExtraBold"], size: s) }
    static func rankFont(_ s: CGFloat) -> CTFont { firstFont(["DINAlternate-Bold", "AvenirNextCondensed-Heavy", "Impact"], size: s) }
    static func nameFont(_ s: CGFloat) -> CTFont { firstFont(["AvenirNextCondensed-Bold", "AvenirNextCondensed-DemiBold", "DINCondensed-Bold"], size: s) }
    static func handleFont(_ s: CGFloat) -> CTFont { firstFont(["AvenirNext-Medium", "HelveticaNeue-Medium"], size: s) }
    static func titleFont(_ s: CGFloat) -> CTFont { firstFont(["AvenirNextCondensed-DemiBold", "AvenirNextCondensed-Bold", "DINCondensed-Bold"], size: s) }

    /// `heavy` > 0: fill + stroke in the text colour (percent of the font size) to thicken a face (the reference's labels are heavier than DIN Bold).
    static func line(_ s: String, _ f: CTFont, _ color: CGColor, tracking: CGFloat = 0, heavy: CGFloat = 0) -> CTLine {
        var attrs: [CFString: Any] = [kCTFontAttributeName: f, kCTForegroundColorAttributeName: color]
        if tracking != 0 { attrs[kCTKernAttributeName] = tracking }
        if heavy > 0 { attrs[kCTStrokeWidthAttributeName] = -heavy }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
    }
    struct Metrics { var width: CGFloat; var ascent: CGFloat; var descent: CGFloat }
    static func metrics(_ l: CTLine) -> Metrics {
        var a: CGFloat = 0, d: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(l, &a, &d, nil))
        return Metrics(width: w, ascent: a, descent: d)
    }
    /// Draws a single line fitted (shrunk / squeezed) into `r`; `align` 0 = left, 0.5 = centre. Cap-height centred vertically.
    static func drawFitted(_ ctx: CGContext, _ text: String, font: (CGFloat) -> CTFont, size: CGFloat, color: CGColor, in r: CGRect,
                           align: CGFloat = 0, tracking: CGFloat = 0, minScale: CGFloat = 0.6, heavy: CGFloat = 0, widen: CGFloat = 1) {
        guard !text.isEmpty, r.width > 2, r.height > 2 else { return }
        var f = font(size)
        var l = line(text, f, color, tracking: tracking, heavy: heavy)
        var m = metrics(l)
        m.width *= widen
        if m.width > r.width {
            let k = max(minScale, r.width / m.width)
            f = font(size * k); l = line(text, f, color, tracking: tracking * k, heavy: heavy); m = metrics(l); m.width *= widen
        }
        let squeeze = (m.width > r.width ? r.width / m.width : 1) * widen
        let cap = CTFontGetCapHeight(f)
        let baseline = r.midY + cap / 2
        let w = m.width / widen * squeeze
        let x = r.minX + (r.width - w) * align
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline); ctx.scaleBy(x: squeeze, y: 1)
        ctx.textPosition = .zero
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }

    // MARK: paths & helpers

    static func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }
    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    static func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint, alpha: CGFloat = 1) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.setAlpha(alpha)
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    static func fillGold(_ ctx: CGContext, _ path: CGPath, from a: CGPoint, to b: CGPoint, alpha: CGFloat = 1) { fill(ctx, path, gold, from: a, to: b, alpha: alpha) }
    /// Brushed-metal streaks clipped to the current clip.
    static func brushed(_ ctx: CGContext, _ r: CGRect, color: CGColor, spacing: CGFloat, angle: CGFloat = -0.9) {
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(max(0.5, spacing * 0.25))
        let len = r.width + r.height
        var x = r.minX - r.height
        while x < r.maxX + r.height {
            ctx.move(to: P(x, r.maxY)); ctx.addLine(to: P(x + len * cos(angle) * -1, r.maxY + len * sin(angle)))
            x += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    /// Deterministic pseudo random 0..<1.
    struct LCG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((s >> 33) % 10_000) / 10_000 } }
    /// Cracked-leather / scale texture (thin gold cell outlines) inside the current clip.
    static func crackle(_ ctx: CGContext, _ r: CGRect, cell: CGFloat, color: CGColor, seed: UInt64) {
        var rng = LCG(s: seed)
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(0.7); ctx.setLineJoin(.round)
        var y = r.minY
        var row = 0
        while y < r.maxY + cell {
            var x = r.minX + (row % 2 == 0 ? 0 : cell / 2)
            while x < r.maxX + cell {
                // irregular cells, some missing, centres jittered: reads as cracked leather rather than a grid
                if rng.next() > 0.22 {
                    let n = 5 + Int(rng.next() * 3)
                    let cx = x + (rng.next() - 0.5) * cell * 0.5, cy = y + (rng.next() - 0.5) * cell * 0.5
                    let sz = cell * (0.75 + rng.next() * 0.5)
                    var pts: [CGPoint] = []
                    for k in 0..<n {
                        let a = CGFloat(k) / CGFloat(n) * .pi * 2 + rng.next() * 0.6
                        let rad = sz * (0.3 + rng.next() * 0.2)
                        pts.append(P(cx + cos(a) * rad, cy + sin(a) * rad))
                    }
                    ctx.addPath(poly(pts))
                }
                x += cell
            }
            y += cell * 0.86; row += 1
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    static func red(_ ctx: CGContext, _ p: CGPath, k: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 7 * k, color: c(0xFF1A1A, 0.85))
        ctx.addPath(p); ctx.setFillColor(c(0xE3141B)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.setFillColor(c(0xFF6A5A, 0.35)); ctx.addPath(p); ctx.fillPath()
        ctx.restoreGState()
    }
    /// Glowing gold stroke.
    static func glowStroke(_ ctx: CGContext, _ p: CGPath, width: CGFloat, color: CGColor = goldLine, glow: CGFloat, k: CGFloat, glowColor: CGColor = c(0xFFC24A, 0.75)) {
        ctx.saveGState()
        if glow > 0 { ctx.setShadow(offset: .zero, blur: glow * k, color: glowColor) }
        ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineJoin(.miter)
        ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()
    }
    /// Draws a CGImage into `r` (top-left origin context), aspect-fit.
    static func drawImage(_ ctx: CGContext, _ img: CGImage?, fit r: CGRect) {
        guard let img else { return }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let k = min(r.width / iw, r.height / ih)
        let dw = iw * k, dh = ih * k
        let d = CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: d.minX, y: d.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: d.width, height: d.height))
        ctx.restoreGState()
    }

    // MARK: board
    //
    // Three pieces, so the renderer can scroll the rows on the GPU without any per-frame CoreGraphics:
    //  - back:  background, brand header, table head, dark table area (+ "data stale" dot)   -- full layer size
    //  - rows:  the whole rows list (teams + empty filler rows), its top = the viewport top    -- w x contentHeightPx
    //  - front: the gold table frame + bottom rules (drawn over the rows)                       -- full layer size

    /// Full board without the strip content (rows at scroll `offset`, board px). `logos` maps logo URL -> image.
    static func board(_ data: TeamBoardData, players: Int, w: Int, h: Int, logos: [String: CGImage] = [:], scroll: Bool = true, offset: CGFloat = 0) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { ctx in
            draw(ctx, data, players: players, size: CGSize(width: w, height: h), logos: logos, scroll: scroll, offset: offset)
        }
    }

    static func draw(_ ctx: CGContext, _ data: TeamBoardData, players: Int, size: CGSize, logos: [String: CGImage], scroll: Bool = true, offset: CGFloat = 0) {
        let L = TeamBoardLayout(size: size, rows: data.teams.count, scroll: scroll)
        back(ctx, L, stale: data.stale)
        let vp = L.viewportRect
        ctx.saveGState()
        ctx.clip(to: vp)
        ctx.translateBy(x: 0, y: vp.minY - min(max(0, offset), L.travelPx))
        rows(ctx, L, data, players: players, logos: logos)
        ctx.restoreGState()
        front(ctx, L)
    }

    /// Back sprite (layer size).
    static func backImage(_ L: TeamBoardLayout, stale: Bool, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { ctx in back(ctx, L, stale: stale) }
    }
    /// Front sprite (layer size): the table frame, transparent elsewhere.
    static func frontImage(_ L: TeamBoardLayout, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { ctx in front(ctx, L) }
    }
    /// Tallest rows sprite; a longer list is rasterised at a lower scale (the GPU stretches it back).
    static let maxRowsSprite: CGFloat = 8192
    /// Rows sprite: the whole list, `L.contentHeightPx` tall in board pixels (top = the viewport top).
    static func rowsImage(_ data: TeamBoardData, players: Int, _ L: TeamBoardLayout, w: Int, logos: [String: CGImage]) -> CGImage? {
        let hc = L.contentHeightPx
        let s = min(1, maxRowsSprite / max(1, hc), CGFloat(SpriteRaster.maxSide) / CGFloat(max(1, w)))
        return Art.image(width: CGFloat(w), height: hc, scale: s) { ctx in rows(ctx, L, data, players: players, logos: logos) }
    }

    static func back(_ ctx: CGContext, _ L: TeamBoardLayout, stale: Bool) {
        let k = L.scale
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: L.originX, y: 0); ctx.scaleBy(x: k, y: k)
        let W = CGFloat(TeamBoardLayout.refW), PH = L.panelHeightRef
        let F = L.rowsBottomRef                     // bottom of the table area
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: PH))
        background(ctx, L, k: k)
        brandHeader(ctx, k: k)
        tableHead(ctx, k: k)
        let rowsTop = CGFloat(TeamBoardLayout.refRowsTop)
        ctx.setFillColor(c(0x07080A, 0.96)); ctx.fill(CGRect(x: 22, y: rowsTop - 4, width: 793, height: F - rowsTop + 4))
        // ---- "data stale" dot (no good answer for 15 s; the last good data stays on screen) ----------------------
        if stale {
            let dot = CGRect(x: 790, y: 232, width: 13, height: 13)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6 * k, color: c(0xFF8A00, 0.9))
            ctx.setFillColor(c(0xFF9F1A)); ctx.fillEllipse(in: dot)
            ctx.restoreGState()
            ctx.setStrokeColor(c(0x2A1600)); ctx.setLineWidth(1.2); ctx.strokeEllipse(in: dot)
        }
        ctx.restoreGState()
    }

    static func front(_ ctx: CGContext, _ L: TeamBoardLayout) {
        let k = L.scale
        ctx.saveGState()
        ctx.translateBy(x: L.originX, y: 0); ctx.scaleBy(x: k, y: k)
        let rowsTop = CGFloat(TeamBoardLayout.refRowsTop), F = L.rowsBottomRef
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(TeamBoardLayout.refW), height: L.panelHeightRef))
        // ---- frame: rows container + outer double rule (closes the panel) -------------------------------------------
        let inner = CGMutablePath()
        inner.move(to: P(22, rowsTop - 4)); inner.addLine(to: P(22, F - 16)); inner.addLine(to: P(38, F)); inner.addLine(to: P(797, F))
        inner.addLine(to: P(813, F - 16)); inner.addLine(to: P(813, rowsTop + 4)); inner.addLine(to: P(805, rowsTop - 4))
        glowStroke(ctx, inner, width: 1.6, glow: 5, k: k)
        let outer = poly([P(18, 254), P(805, 254), P(819, 268), P(819, F - 10), P(792, F + 17), P(45, F + 17), P(18, F - 10)])
        glowStroke(ctx, outer, width: 2.2, glow: 9, k: k)
        // hot glints on the bottom rules (as in the reference)
        for (y, a) in [(F, CGFloat(0.9)), (F + 17, 0.75)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10 * k, color: c(0xFF9A2A, a))
            ctx.setStrokeColor(c(0xFFF2C8, a)); ctx.setLineWidth(1.4)
            ctx.move(to: P(330, y)); ctx.addLine(to: P(520, y)); ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// The rows list in "rows space": board pixels with y = 0 at the viewport top, `L.contentHeightPx` tall.
    static func rows(_ ctx: CGContext, _ L: TeamBoardLayout, _ data: TeamBoardData, players: Int, logos: [String: CGImage]) {
        let k = L.scale
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: L.originX, y: -L.viewportRect.minY); ctx.scaleBy(x: k, y: k)
        let W = CGFloat(TeamBoardLayout.refW)
        let top = CGFloat(TeamBoardLayout.refRowsTop)
        let content = CGRect(x: 0, y: top, width: W, height: max(L.contentHeightRef, L.contentHeightPx / k))
        ctx.clip(to: content)
        ctx.setFillColor(c(0x07080A, 0.96)); ctx.fill(CGRect(x: 22, y: content.minY, width: 793, height: content.height))
        let n = data.teams.count
        for i in 0..<L.fillerRows { drawEmptyRow(ctx, L, n + i, k: k) }
        if data.teams.isEmpty {
            let band = CGRect(x: 40, y: top, width: W - 80, height: min(L.rowHRef * 3, content.height))
            drawFitted(ctx, data.message ?? "WAITING FOR TEAM DATA…", font: nameFont, size: 28, color: c(0xC9B27A), in: band, align: 0.5)
        }
        for (i, team) in data.teams.enumerated() {
            drawRow(ctx, L, i, team, players: players, logo: team.logoURL.flatMap { logos[$0] }, k: k, last: i == n - 1 && L.fillerRows == 0)
        }
        ctx.restoreGState()
    }

    /// Empty continuation row under the last team (few teams): the alternating row background and rule, no content.
    static func drawEmptyRow(_ ctx: CGContext, _ L: TeamBoardLayout, _ i: Int, k: CGFloat) {
        let r = L.rowRef(i)
        let y0 = r.minY, y1 = r.maxY, h = r.height
        let ch = min(7, h * 0.12)
        let bg = poly([P(r.minX, y0), P(r.maxX - ch, y0), P(r.maxX, y0 + ch), P(r.maxX, y1 - ch), P(r.maxX - ch, y1), P(r.minX, y1)])
        let navy = i % 2 == 1
        fill(ctx, bg, gradient(navy ? [(0, rowB0), (0.45, rowB1), (1, rowB0)] : [(0, rowA0), (1, rowA1)]),
             from: navy ? P(r.minX, 0) : P(0, y0), to: navy ? P(r.maxX, 0) : P(0, y1), alpha: 0.6)
        ctx.setStrokeColor(c(0xB89A58, 0.32)); ctx.setLineWidth(1.1)
        ctx.move(to: P(r.minX, y1)); ctx.addLine(to: P(r.maxX - ch, y1)); ctx.strokePath()
        ctx.setStrokeColor(c(0xC9A04A, 0.3)); ctx.setLineWidth(1.0)
        ctx.move(to: P(r.maxX - ch, y0)); ctx.addLine(to: P(r.maxX, y0 + ch)); ctx.addLine(to: P(r.maxX, y1 - ch)); ctx.addLine(to: P(r.maxX - ch, y1)); ctx.strokePath()
        // faint column ghosts keep the table structure readable
        ctx.setStrokeColor(c(0x6A6252, 0.28)); ctx.setLineWidth(1)
        for x in [TeamBoardLayout.rankR, TeamBoardLayout.sep1, TeamBoardLayout.sep2, TeamBoardLayout.sep3] {
            ctx.move(to: P(x, y0 + h * 0.3)); ctx.addLine(to: P(x, y1 - h * 0.3)); ctx.strokePath()
        }
    }

    // MARK: background, beams, footer

    static func background(_ ctx: CGContext, _ L: TeamBoardLayout, k: CGFloat) {
        let W = CGFloat(TeamBoardLayout.refW), PH = L.panelHeightRef, F = L.rowsBottomRef
        ctx.drawLinearGradient(gradient([(0, 0x0B0907), (0.5, 0x070605), (1, 0x0A0806)]), start: P(0, 0), end: P(W, PH), options: [])

        // header: dark diagonal plates with a cracked texture, a darker chevron behind the wordmark
        ctx.saveGState()
        let plates: [[CGPoint]] = [
            [P(150, 0), P(260, 0), P(30, 254), P(0, 254), P(0, 166)],
            [P(300, 0), P(420, 0), P(240, 200), P(160, 254), P(80, 254)],
            [P(560, 0), P(700, 0), P(837, 150), P(837, 254), P(760, 254)],
        ]
        for (n, pts) in plates.enumerated() {
            let p = poly(pts)
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            ctx.setFillColor(c(n == 1 ? 0x121010 : 0x15120D)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: 254))
            crackle(ctx, CGRect(x: 0, y: 0, width: W, height: 254), cell: 13, color: c(0xB8913F, n == 2 ? 0.16 : 0.12), seed: UInt64(11 + n))
            ctx.restoreGState()
        }
        // chevron edges (thin gold) behind the wordmark
        let chev = CGMutablePath(); chev.move(to: P(470, 254)); chev.addLine(to: P(645, 18)); chev.addLine(to: P(837, 236))
        glowStroke(ctx, chev, width: 1, color: c(0xC9A04A, 0.45), glow: 0, k: k)
        ctx.restoreGState()

        // top-left gold slab, parallel rule, red slash, small facets
        let tl = poly([P(0, 0), P(122, 0), P(0, 146)])
        fillGold(ctx, tl, from: P(0, 0), to: P(110, 120))
        ctx.saveGState(); ctx.addPath(tl); ctx.clip()
        brushed(ctx, CGRect(x: 0, y: 0, width: 130, height: 150), color: c(0xFFFFFF, 0.08), spacing: 4)
        ctx.restoreGState()
        glowStroke(ctx, { let p = CGMutablePath(); p.move(to: P(136, 0)); p.addLine(to: P(0, 162)); return p }(), width: 1.6, glow: 4, k: k)
        red(ctx, poly([P(141, 0), P(156, 0), P(110, 54), P(95, 54)]), k: k)
        red(ctx, poly([P(0, 182), P(28, 150), P(32, 154), P(0, 190)]), k: k)
        fillGold(ctx, poly([P(0, 232), P(42, 204), P(50, 212), P(0, 266)]), from: P(0, 204), to: P(50, 266))

        // top-right gold slab, parallel rule, red slash, facet
        let tr = poly([P(728, 0), P(837, 0), P(837, 136)])
        fillGold(ctx, tr, from: P(837, 0), to: P(740, 110))
        ctx.saveGState(); ctx.addPath(tr); ctx.clip()
        brushed(ctx, CGRect(x: 720, y: 0, width: 120, height: 140), color: c(0xFFFFFF, 0.08), spacing: 4, angle: -2.2)
        ctx.restoreGState()
        glowStroke(ctx, { let p = CGMutablePath(); p.move(to: P(712, 0)); p.addLine(to: P(837, 154)); return p }(), width: 1.6, glow: 4, k: k)
        red(ctx, poly([P(690, 0), P(707, 0), P(757, 70), P(741, 70)]), k: k)
        fillGold(ctx, poly([P(794, 190), P(837, 230), P(837, 260), P(786, 200)]), from: P(837, 190), to: P(786, 260))

        // ---- footer under the table -------------------------------------------------------------------------------
        let fy = F + 17
        guard PH > fy else { return }
        // dark diagonal plates with silver / gold streaks
        let bands: [([CGPoint], UInt32)] = [
            ([P(150, PH), P(260, fy), P(330, fy), P(220, PH)], 0x15130F),
            ([P(420, PH), P(500, fy), P(600, fy), P(520, PH)], 0x121212),
            ([P(600, PH), P(680, fy), P(720, fy), P(640, PH)], 0x181613),
        ]
        for (pts, col) in bands {
            let p = poly(pts)
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            ctx.setFillColor(c(col)); ctx.fill(CGRect(x: 0, y: fy, width: W, height: PH - fy))
            crackle(ctx, CGRect(x: 0, y: fy, width: W, height: PH - fy), cell: 12, color: c(0xB8913F, 0.1), seed: UInt64(col & 0xFF))
            ctx.restoreGState()
        }
        for (x0, col, a) in [(CGFloat(560), UInt32(0xCFCFCF), CGFloat(0.45)), (CGFloat(330), 0xC9A04A, 0.4), (CGFloat(120), 0xC9A04A, 0.3)] {
            ctx.setStrokeColor(c(col, a)); ctx.setLineWidth(1.2)
            ctx.move(to: P(x0, PH)); ctx.addLine(to: P(x0 + (PH - fy) * 0.85, fy)); ctx.strokePath()
        }
        // bottom-left: gold slab + red stripe
        fillGold(ctx, poly([P(0, F + 16), P(66, PH), P(0, PH)]), from: P(0, F + 16), to: P(66, PH))
        ctx.saveGState(); ctx.addPath(poly([P(0, F + 16), P(66, PH), P(0, PH)])); ctx.clip()
        brushed(ctx, CGRect(x: 0, y: F, width: 80, height: PH - F), color: c(0xFFFFFF, 0.08), spacing: 4); ctx.restoreGState()
        red(ctx, poly([P(0, F - 2), P(0, F + 8), P(86, PH), P(98, PH)]), k: k)
        glowStroke(ctx, { let p = CGMutablePath(); p.move(to: P(0, F + 22)); p.addLine(to: P(62, PH)); return p }(), width: 1, color: c(0xFFE7A6, 0.8), glow: 0, k: k)
        // bottom-right: red stripe + gold slab + hot spark
        red(ctx, poly([P(837, F - 8), P(837, F + 3), P(771, PH), P(759, PH)]), k: k)
        fillGold(ctx, poly([P(837, F + 30), P(837, PH), P(790, PH)]), from: P(837, F + 30), to: P(790, PH))
        ctx.saveGState(); ctx.addPath(poly([P(837, F + 30), P(837, PH), P(790, PH)])); ctx.clip()
        brushed(ctx, CGRect(x: 780, y: F, width: 60, height: PH - F), color: c(0xFFFFFF, 0.08), spacing: 4, angle: -2.2); ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14 * k, color: c(0xFF9A2A, 0.95))
        ctx.setStrokeColor(c(0xFFE9B0)); ctx.setLineWidth(1.6)
        ctx.move(to: P(735, PH - 2)); ctx.addLine(to: P(800, fy + 4)); ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: brand header (logo assets + social strip frame)

    static func brandHeader(_ ctx: CGContext, k: CGFloat) {
        typealias T = TeamBoardLayout
        // soft warm light behind the logos
        ctx.saveGState()
        let glow = CGGradient(colorsSpace: Art.cs, colors: [c(0xFFB43A, 0.16), c(0xFFB43A, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: P(420, 130), startRadius: 0, endCenter: P(420, 130), endRadius: 330, options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10 * k, color: c(0xFFB43A, 0.35))
        drawImage(ctx, AdvancedStudioAssets.logoMark, fit: T.markRect)
        drawImage(ctx, AdvancedStudioAssets.logoWord, fit: T.wordRect)
        ctx.restoreGState()
        // thin gold divider (fades out at both ends)
        let dv = CGRect(x: T.dividerX - 1, y: 74, width: 2, height: 102)
        ctx.saveGState(); ctx.clip(to: dv)
        ctx.drawLinearGradient(CGGradient(colorsSpace: Art.cs, colors: [c(0xE8C068, 0), c(0xF6D27C), c(0xE8C068, 0)] as CFArray, locations: [0, 0.5, 1])!,
                               start: P(0, dv.minY), end: P(0, dv.maxY), options: [])
        ctx.restoreGState()
        // social strip: dark slanted pill, gold edge, red slash at the right end
        let pill = poly([P(T.pillLeft + T.pillSlant, T.pillTop), P(T.pillRight, T.pillTop), P(T.pillRight - T.pillSlant, T.pillBottom), P(T.pillLeft, T.pillBottom)])
        fill(ctx, pill, gradient([(0, 0x18181A), (0.6, 0x0B0B0C), (1, 0x060606)]), from: P(0, T.pillTop), to: P(0, T.pillBottom), alpha: 0.96)
        glowStroke(ctx, pill, width: 1.5, glow: 6, k: k, glowColor: c(0xFFB43A, 0.55))
        ctx.saveGState(); ctx.addPath(pill); ctx.clip()
        red(ctx, poly([P(686, T.pillBottom), P(703, T.pillBottom), P(742, T.pillTop), P(725, T.pillTop)]), k: k)
        ctx.restoreGState()
    }

    // MARK: table head

    static func tableHead(_ ctx: CGContext, k: CGFloat) {
        let r = TeamBoardLayout.tableHeadRect
        let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        let head = poly([P(x0, y0), P(x1 - 12, y0), P(x1, y0 + 12), P(x1, y1 - 4), P(392, y1 - 4), P(386, y1 + 2), P(x0 + 8, y1 + 2), P(x0, y1 - 6)])
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12 * k, color: c(0xFFC24A, 0.55))
        ctx.addPath(head); ctx.setFillColor(c(0xD9A84C)); ctx.fillPath()
        ctx.restoreGState()
        fill(ctx, head, headGold, from: P(x0, 0), to: P(x1, 0))
        ctx.saveGState(); ctx.addPath(head); ctx.clip()
        // top sheen, bottom shade, bevel facet, brushed grain
        ctx.drawLinearGradient(CGGradient(colorsSpace: Art.cs, colors: [c(0xFFFFFF, 0.28), c(0xFFFFFF, 0.04), c(0x000000, 0), c(0x5A3A00, 0.18)] as CFArray,
                                          locations: [0, 0.3, 0.6, 1])!, start: P(0, y0), end: P(0, y1 + 2), options: [])
        ctx.setFillColor(c(0xFFF4D0, 0.22)); ctx.addPath(poly([P(352, y0), P(368, y0), P(408, y1 - 4), P(392, y1 - 4)])); ctx.fillPath()
        brushed(ctx, r, color: c(0xFFFFFF, 0.05), spacing: 3, angle: 0.02)
        ctx.setStrokeColor(c(0xFFF7D6, 0.85)); ctx.setLineWidth(1.4)
        ctx.move(to: P(x0, y0 + 0.8)); ctx.addLine(to: P(x1 - 12, y0 + 0.8)); ctx.strokePath()
        ctx.restoreGState()
        // labels + separators
        let size: CGFloat = 25
        let cols: [(String, CGFloat, CGFloat)] = [("#", 24, 108), ("TEAM", 108, 386), ("FIN.", 409, 520), ("TOT. PTS.", 520, 679), ("STATUS", 679, 815)]
        for (t, a, b) in cols {
            drawFitted(ctx, t, font: labelFont, size: size, color: ink, in: CGRect(x: a + 4, y: y0, width: b - a - 8, height: r.height), align: 0.5, tracking: 0.8, heavy: 5, widen: 1.12)
        }
        ctx.setStrokeColor(c(0x2A1C06, 0.85)); ctx.setLineWidth(1.6)
        for x in [108.0, 409, 520, 679] as [CGFloat] {
            ctx.move(to: P(x, y0 + 13)); ctx.addLine(to: P(x, y1 - 13)); ctx.strokePath()
        }
    }

    // MARK: rows

    static func glowColor(_ s: PlayerState, _ a: CGFloat) -> CGColor {
        switch s { case .alive: c(0xFFC84A, a); case .knocked: c(0xFF2020, a); case .eliminated: c(0xBBBBBB, a * 0.4) }
    }
    static func barGradient(_ s: PlayerState) -> CGGradient {
        switch s {
        case .alive: gradient([(0, 0x9A6E1E), (0.3, 0xF4D27A), (0.55, 0xFFF0B8), (0.8, 0xE0B04E), (1, 0x9A6E1E)])
        case .knocked: gradient([(0, 0x8A0A0C), (0.35, 0xFF3A2E), (0.55, 0xFF7A6A), (0.8, 0xD8141A), (1, 0x7A0508)])
        case .eliminated: gradient([(0, 0x4A4A4A), (0.45, 0x7A7A7A), (1, 0x484848)])
        }
    }

    static func drawRow(_ ctx: CGContext, _ L: TeamBoardLayout, _ i: Int, _ team: TeamBoardData.Team, players: Int, logo: CGImage?, k: CGFloat, last: Bool) {
        typealias T = TeamBoardLayout
        let r = L.rowRef(i)
        let h = r.height
        let out = team.isEliminated
        let y0 = r.minY, y1 = r.maxY
        let ch = min(7, h * 0.12)
        // background (right end chamfered)
        let bg = poly([P(r.minX, y0), P(r.maxX - ch, y0), P(r.maxX, y0 + ch), P(r.maxX, y1 - ch), P(r.maxX - ch, y1), P(r.minX, y1)])
        let navy = i % 2 == 1
        fill(ctx, bg, gradient(navy ? [(0, rowB0), (0.45, rowB1), (1, rowB0)] : [(0, rowA0), (1, rowA1)]),
             from: navy ? P(r.minX, 0) : P(0, y0), to: navy ? P(r.maxX, 0) : P(0, y1))
        ctx.saveGState(); ctx.addPath(bg); ctx.clip()
        ctx.drawLinearGradient(CGGradient(colorsSpace: Art.cs, colors: [c(0xFFFFFF, 0.035), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                               start: P(0, y0), end: P(0, y0 + h * 0.5), options: [])
        ctx.restoreGState()
        // thin gold rule between rows + right-end chamfer edges
        if !last {
            ctx.setStrokeColor(c(0xB89A58, 0.9)); ctx.setLineWidth(1.3)
            ctx.move(to: P(r.minX, y1)); ctx.addLine(to: P(r.maxX - ch, y1)); ctx.strokePath()
        }
        ctx.setStrokeColor(c(0xC9A04A, 0.75)); ctx.setLineWidth(1.2)
        ctx.move(to: P(r.maxX - ch, y0)); ctx.addLine(to: P(r.maxX, y0 + ch)); ctx.addLine(to: P(r.maxX, y1 - ch)); ctx.addLine(to: P(r.maxX - ch, y1)); ctx.strokePath()

        // everything inside the row fades for an eliminated team
        ctx.saveGState()
        if out { ctx.setAlpha(0.4); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        // rank box (angled bottom-right corner)
        let rb = CGRect(x: T.rankL, y: y0 + 1, width: T.rankR - T.rankL, height: h - 2)
        let cut = min(rb.height * 0.26, 16)
        let rankPath = poly([P(rb.minX, rb.minY), P(rb.maxX, rb.minY), P(rb.maxX, rb.maxY - cut), P(rb.maxX - cut, rb.maxY), P(rb.minX, rb.maxY)])
        fill(ctx, rankPath, gradient([(0, 0x22211E), (1, 0x131311)]), from: P(0, rb.minY), to: P(0, rb.maxY))
        ctx.setStrokeColor(out ? c(0x8A8A8A) : goldLine); ctx.setLineWidth(1.5)
        ctx.move(to: P(rb.maxX, rb.minY)); ctx.addLine(to: P(rb.maxX, rb.maxY - cut)); ctx.addLine(to: P(rb.maxX - cut, rb.maxY)); ctx.strokePath()
        let rank = team.rank ?? (i + 1)
        drawFitted(ctx, "\(rank)", font: rankFont, size: min(h * 0.52, 34), color: out ? c(0xB8B8B8) : cream, in: rb.insetBy(dx: 6, dy: 0), align: 0.5, heavy: 5, widen: 1.15)
        // logo box
        let lr = L.logoRef(i)
        ctx.setFillColor(c(0x1B1B1C)); ctx.fill(lr)
        if let logo {
            ctx.saveGState(); ctx.clip(to: lr.insetBy(dx: 1.5, dy: 1.5))
            drawImage(ctx, logo, fit: lr.insetBy(dx: 2, dy: 2))
            ctx.restoreGState()
        }
        ctx.setStrokeColor(c(0x6E6248, 0.95)); ctx.setLineWidth(1.2); ctx.stroke(lr.insetBy(dx: 0.6, dy: 0.6))
        // team name
        drawFitted(ctx, team.name.uppercased(), font: nameFont, size: min(h * 0.42, 27), color: out ? c(0x9A9A9A) : c(0xF7F1E1),
                   in: L.nameRef(i), align: 0, tracking: 0.5, minScale: 0.55)
        // column separators
        ctx.setStrokeColor(c(0x6A6252, 0.85)); ctx.setLineWidth(1.1)
        for x in [T.sep1, T.sep2, T.sep3] {
            ctx.move(to: P(x, y0 + h * 0.24)); ctx.addLine(to: P(x, y1 - h * 0.24)); ctx.strokePath()
        }
        // FIN. / TOT. PTS.
        let vs = min(h * 0.46, 30)
        let dash = c(0x6F6858)
        let fin = CGRect(x: T.sep1 + 4, y: y0, width: T.sep2 - T.sep1 - 8, height: h)
        let pts = CGRect(x: T.sep2 + 4, y: y0, width: T.sep3 - T.sep2 - 8, height: h)
        if let f = team.finishes { drawFitted(ctx, "\(f)", font: rankFont, size: vs, color: out ? c(0xB0B0B0) : cream, in: fin, align: 0.5, heavy: 2) }
        else { drawFitted(ctx, "-", font: rankFont, size: vs * 0.8, color: dash, in: fin, align: 0.5) }
        if let p = team.points { drawFitted(ctx, "\(p)", font: rankFont, size: vs, color: out ? c(0xB8B8B8) : c(0xF4CC6E), in: pts, align: 0.5, heavy: 2) }
        else { drawFitted(ctx, "-", font: rankFont, size: vs * 0.8, color: dash, in: pts, align: 0.5) }
        // status bars
        let bars = team.bars(players)
        for (n, br) in L.barRefs(i, count: players).enumerated() {
            let st = bars[n]
            let p = CGPath(roundedRect: br, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.saveGState()
            if !out, st != .eliminated { ctx.setShadow(offset: .zero, blur: 7 * k, color: glowColor(st, 0.7)) }
            ctx.addPath(p); ctx.setFillColor(c(0x000000)); ctx.fillPath()
            ctx.restoreGState()
            fill(ctx, p, barGradient(st), from: P(br.minX, 0), to: P(br.maxX, 0))
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            ctx.setFillColor(c(0xFFFFFF, st == .eliminated ? 0.05 : 0.12)); ctx.fill(CGRect(x: br.minX, y: br.minY, width: br.width, height: br.height * 0.4))
            ctx.restoreGState()
            ctx.setStrokeColor(st == .eliminated ? c(0x8A8A8A, 0.9) : (st == .knocked ? c(0xFFB0A8, 0.8) : c(0xFFF0C8, 0.85)))
            ctx.setLineWidth(1.1); ctx.addPath(p); ctx.strokePath()
        }
        if out { ctx.endTransparencyLayer() }
        ctx.restoreGState()
        if out { ctx.setFillColor(c(0x2A2A2A, 0.18)); ctx.addPath(bg); ctx.fillPath() }
    }

    // MARK: strip content (cross-faded sprites)

    /// The strip window content for `slide`, w x h pixels (the window is TeamBoardLayout.slideRef).
    static func slide(_ s: TeamBoardSlide, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { ctx in
            let R = TeamBoardLayout.slideRef
            let k = CGFloat(w) / R.width
            ctx.scaleBy(x: k, y: CGFloat(h) / R.height)
            let H = R.height
            switch s {
            case .social(let handle):
                // reference: Instagram 378, YouTube 431, globe 485, divider 521, text from 537 (centres, reference x)
                let ox = R.minX, cy = H / 2
                let gold = c(0xEDC66C)
                instagram(ctx, center: P(378 - ox, cy), size: 26, color: gold)
                youtube(ctx, center: P(431 - ox, cy), size: 28, color: gold)
                globe(ctx, center: P(485 - ox, cy), size: 26, color: gold)
                ctx.setStrokeColor(c(0xD9B25E, 0.8)); ctx.setLineWidth(1.4)
                ctx.move(to: P(521 - ox, cy - 13)); ctx.addLine(to: P(521 - ox, cy + 13)); ctx.strokePath()
                if !handle.isEmpty {
                    drawFitted(ctx, handle, font: handleFont, size: 19, color: c(0xEFE8D8), in: CGRect(x: 536 - ox, y: 0, width: R.width - (536 - ox), height: H), align: 0, minScale: 0.5)
                }
            case .title(let text):
                goldText(ctx, text, in: CGRect(x: 6, y: 0, width: R.width - 12, height: H), size: 22, k: k)
            }
        }
    }

    /// Centred gold-gradient text with a soft glow.
    static func goldText(_ ctx: CGContext, _ text: String, in box: CGRect, size: CGFloat, k: CGFloat) {
        var sz = size
        let track = sz * 0.1
        var f = titleFont(sz)
        var l = line(text, f, c(0xFFFFFF), tracking: track)
        var m = metrics(l)
        if m.width > box.width { let q = max(0.55, box.width / m.width); sz *= q; f = titleFont(sz); l = line(text, f, c(0xFFFFFF), tracking: track * q); m = metrics(l) }
        let squeeze = m.width > box.width ? box.width / m.width : 1
        let cap = CTFontGetCapHeight(f)
        let baseline = box.midY + cap / 2
        let x = box.minX + (box.width - m.width * squeeze) / 2
        // glow pass
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline); ctx.scaleBy(x: squeeze, y: 1); ctx.textPosition = .zero
        ctx.setShadow(offset: .zero, blur: sz * 0.4 * k, color: c(0xFFB938, 0.45))
        CTLineDraw(line(text, f, c(0xD9A53F), tracking: track * (sz / size)), ctx)
        ctx.restoreGState()
        // gradient fill clipped to the glyphs
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(l) as! [CTRun]
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs); CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = attrs[kCTFontAttributeName] as! CTFont
            for g in 0..<n {
                guard let gp = CTFontCreatePathForGlyph(rf, glyphs[g], nil) else { continue }
                path.addPath(gp, transform: CGAffineTransform(translationX: x + pos[g].x * squeeze, y: baseline).scaledBy(x: squeeze, y: -1))
            }
        }
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, 0xFFF6D2), (0.4, 0xF3CF76), (0.7, 0xD6A03C), (1, 0xF0CB6A)]),
                               start: P(0, baseline - cap), end: P(0, baseline), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func instagram(_ ctx: CGContext, center p: CGPoint, size s: CGFloat, color: CGColor) {
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(s * 0.1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: s * 0.05, dy: s * 0.05), cornerWidth: s * 0.28, cornerHeight: s * 0.28, transform: nil)); ctx.strokePath()
        ctx.strokeEllipse(in: CGRect(x: p.x - s * 0.22, y: p.y - s * 0.22, width: s * 0.44, height: s * 0.44))
        ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: p.x + s * 0.2, y: p.y - s * 0.3, width: s * 0.11, height: s * 0.11))
        ctx.restoreGState()
    }
    static func youtube(_ ctx: CGContext, center p: CGPoint, size s: CGFloat, color: CGColor) {
        let r = CGRect(x: p.x - s / 2, y: p.y - s * 0.36, width: s, height: s * 0.72)
        ctx.saveGState()
        ctx.setFillColor(color); ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)); ctx.fillPath()
        ctx.setFillColor(c(0x0B0A08)); ctx.addPath(poly([P(p.x - s * 0.12, p.y - s * 0.17), P(p.x + s * 0.18, p.y), P(p.x - s * 0.12, p.y + s * 0.17)])); ctx.fillPath()
        ctx.restoreGState()
    }
    static func globe(_ ctx: CGContext, center p: CGPoint, size s: CGFloat, color: CGColor) {
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s).insetBy(dx: s * 0.05, dy: s * 0.05)
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(s * 0.07)
        ctx.strokeEllipse(in: r)
        ctx.strokeEllipse(in: r.insetBy(dx: r.width * 0.28, dy: 0))
        ctx.move(to: P(r.midX, r.minY)); ctx.addLine(to: P(r.midX, r.maxY))
        ctx.move(to: P(r.minX, r.midY)); ctx.addLine(to: P(r.maxX, r.midY))
        for f in [0.27, 0.73] as [CGFloat] {
            let y = r.minY + r.height * f, half = r.width * 0.5 * sqrt(1 - pow((y - r.midY) / (r.height / 2), 2))
            ctx.move(to: P(r.midX - half, y)); ctx.addLine(to: P(r.midX + half, y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Board + current strip slide in one image (CPU previews: editor rasteriser, template thumbnails).
    static func composite(_ spec: TeamBoardSpec, vars: SceneVariables, defaults: [String: String] = [:], w: Int, h: Int, time: Double = 0) -> CGImage? {
        let data = TeamBoardHub.shared.data(for: spec)
        let slides = TeamBoardCarousel.slides(spec, data: data, vars: vars, defaults: defaults)
        let L = TeamBoardLayout(size: CGSize(width: w, height: h), rows: data.teams.count, scroll: spec.autoScroll)
        let cs = TeamBoardCarousel.state(time: time, count: slides.count, interval: spec.carouselInterval)
        let off = TeamBoardScroll.offset(time: time, travel: Double(L.travelPx), speed: TeamBoardScroll.speed(boardHeight: CGFloat(h), factor: spec.scrollSpeed))
        return Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { ctx in
            draw(ctx, data, players: spec.playersPerTeam, size: CGSize(width: w, height: h), logos: [:], scroll: spec.autoScroll, offset: CGFloat(off))
            let tr = L.titleRect
            if !slides.isEmpty, let t = slide(slides[cs.index], w: max(8, Int(tr.width.rounded())), h: max(8, Int(tr.height.rounded()))) {
                ctx.saveGState(); ctx.translateBy(x: tr.minX, y: tr.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(t, in: CGRect(x: 0, y: 0, width: tr.width, height: tr.height)); ctx.restoreGState()
            }
        }
    }

    // MARK: logos

    /// Team logos by URL (file:// or http(s)), fetched in the background; `version` bumps when one arrives.
    final class Logos: @unchecked Sendable {
        static let shared = Logos()
        private let lock = NSLock()
        private var images: [String: CGImage] = [:]
        private var loading = Set<String>()
        private(set) var version = 0
        func images(for urls: [String]) -> [String: CGImage] {
            lock.lock(); defer { lock.unlock() }
            var out: [String: CGImage] = [:]
            for u in urls {
                if let i = images[u] { out[u] = i }
                else if !loading.contains(u), let url = URL(string: u) { loading.insert(u); fetch(u, url) }
            }
            return out
        }
        var currentVersion: Int { lock.withLock { version } }
        private func fetch(_ key: String, _ url: URL) {
            Task.detached(priority: .utility) { [weak self] in
                var data: Data?
                if url.isFileURL { data = try? Data(contentsOf: url) }
                else { data = try? await URLSession.shared.data(from: url).0 }
                var img: CGImage?
                if let data, let src = CGImageSourceCreateWithData(data as CFData, nil) {
                    img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
                }
                guard let self else { return }
                self.lock.withLock {
                    if let img { self.images[key] = img; self.version += 1 }
                    // failed loads stay in `loading` (no retry storm); they retry after the next app start
                }
            }
        }
    }
}
