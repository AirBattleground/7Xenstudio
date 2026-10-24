// CoreText / CoreGraphics rasterisation of text, shape and decorated-text layers into BGRA premultiplied CGImages (top-left origin).
// Runs off the render thread (SpriteStore). Pure functions of their inputs.
import Foundation
import CoreGraphics
import CoreText

enum SpriteRaster {
    static let maxSide = 4096

    // MARK: fonts

    /// CoreText weight trait for a 100...900 weight.
    static func weightTrait(_ w: Double) -> CGFloat {
        let stops: [(Double, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let x = min(900, max(100, w))
        for i in 1..<stops.count where x <= stops[i].0 {
            let (a, b) = (stops[i - 1], stops[i]); let t = CGFloat((x - a.0) / (b.0 - a.0))
            return a.1 + (b.1 - a.1) * t
        }
        return 0.62
    }
    static func font(_ name: String, size: CGFloat, weight: Double, italic: Bool) -> CTFont {
        var traits: [CFString: Any] = [kCTFontWeightTrait: weightTrait(weight)]
        if italic { traits[kCTFontSlantTrait] = 0.2 }
        let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: name, kCTFontTraitsAttribute: traits]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(desc, size, nil)
        // an unknown family silently falls back to Helvetica/Times; accept it. If the name is a PostScript name, try that.
        if CTFontCopyFamilyName(f) as String != name, let ps = Optional(CTFontCreateWithName(name as CFString, size, nil)), CTFontCopyPostScriptName(ps) as String == name { return ps }
        return f
    }

    // MARK: gradients

    static func cgGradient(_ g: Gradient) -> CGGradient? {
        let stops = g.stops.sorted { $0.pos < $1.pos }
        let comps = stops.flatMap { [CGFloat($0.color.r), CGFloat($0.color.g), CGFloat($0.color.b), CGFloat($0.color.a)] }
        return CGGradient(colorSpace: Art.cs, colorComponents: comps, locations: stops.map { CGFloat($0.pos) }, count: stops.count)
    }
    /// Paint a gradient over `rect` of the current clip.
    static func paint(_ g: Gradient, in ctx: CGContext, rect: CGRect) {
        guard let cg = cgGradient(g) else { return }
        if g.radial {
            let c = CGPoint(x: rect.minX + CGFloat(g.cx) * rect.width, y: rect.minY + CGFloat(g.cy) * rect.height)
            let r = CGFloat(g.radius) * hypot(rect.width, rect.height) / 2
            ctx.drawRadialGradient(cg, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(1, r), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            let a = g.angle * .pi / 180
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            let ext = abs(dx) * rect.width + abs(dy) * rect.height
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(cg, start: CGPoint(x: mid.x - dx * ext / 2, y: mid.y - dy * ext / 2),
                                   end: CGPoint(x: mid.x + dx * ext / 2, y: mid.y + dy * ext / 2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: shapes

    static func shapePath(_ s: ShapeSpec, rect r: CGRect) -> CGPath {
        switch s.kind {
        case .rect: return CGPath(rect: r, transform: nil)
        case .roundedRect:
            let rad = min(CGFloat(s.cornerRadius), min(r.width, r.height) / 2)
            return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .polygon:
            let n = max(3, s.sides), p = CGMutablePath()
            let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
            let inner = CGFloat(min(0.95, max(0, s.starInset)))
            let pts = inner > 0 ? n * 2 : n
            for i in 0..<pts {
                let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(pts)
                let k: CGFloat = (inner > 0 && i % 2 == 1) ? (1 - inner) : 1
                let pt = CGPoint(x: cx + cos(a) * rx * k, y: cy + sin(a) * ry * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath(); return p
        case .line:
            let p = CGMutablePath()
            if r.height <= CGFloat(s.lineWidth) * 1.5 { p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
            else { p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
            return p
        }
    }
    static func shape(_ s: ShapeSpec, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            let full = CGRect(x: 0, y: 0, width: w, height: h)
            let sw = CGFloat(max(0, s.stroke.width))
            if s.kind == .line {
                let lw = CGFloat(max(1, s.lineWidth))
                let r = full.insetBy(dx: lw / 2, dy: lw / 2)
                c.setLineWidth(lw); c.setLineCap(.round)
                c.addPath(shapePath(s, rect: r))
                if let g = s.fill.gradient {
                    c.replacePathWithStrokedPath(); c.clip(); paint(g, in: c, rect: full)
                } else { c.setStrokeColor(s.fill.color.cgColor); c.strokePath() }
                return
            }
            let r = full.insetBy(dx: sw / 2, dy: sw / 2)
            let path = shapePath(s, rect: r)
            c.saveGState()
            c.addPath(path); c.clip()
            if let g = s.fill.gradient { paint(g, in: c, rect: full) } else { c.setFillColor(s.fill.color.cgColor); c.fill(full) }
            c.restoreGState()
            if sw > 0 {
                c.saveGState()
                c.setLineWidth(sw); c.setLineJoin(.miter)
                if let g = s.stroke.gradient {
                    c.addPath(path); c.replacePathWithStrokedPath(); c.clip(); paint(g, in: c, rect: full)
                } else { c.setStrokeColor(s.stroke.color.cgColor); c.addPath(path); c.strokePath() }
                c.restoreGState()
            }
        }
    }

    // MARK: text

    struct Laid { var lines: [CTLine]; var widths: [CGFloat]; var ascents: [CGFloat]; var heights: [CGFloat]; var total: CGFloat }
    static func attributed(_ s: String, _ st: TextStyle, size: CGFloat, color: CGColor) -> NSAttributedString {
        let f = font(st.font, size: size, weight: st.weight, italic: st.italic)
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                     NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        if st.tracking != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = st.tracking }
        return NSAttributedString(string: s, attributes: attrs)
    }
    static func layout(_ str: NSAttributedString, width: CGFloat, lineSpacing: CGFloat) -> Laid {
        let ts = CTTypesetterCreateWithAttributedString(str)
        var lines: [CTLine] = [], widths: [CGFloat] = [], asc: [CGFloat] = [], hts: [CGFloat] = []
        var start = 0; let n = str.length
        var total: CGFloat = 0
        if n == 0 { return Laid(lines: [], widths: [], ascents: [], heights: [], total: 0) }
        while start < n {
            var count = CTTypesetterSuggestLineBreak(ts, start, Double(max(1, width)))
            if count <= 0 { count = 1 }
            // honour explicit newlines
            let sub = (str.string as NSString).substring(with: NSRange(location: start, length: count))
            if let nl = sub.firstIndex(of: "\n") { count = sub.distance(from: sub.startIndex, to: nl) + 1 }
            let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
            lines.append(line); widths.append(w); asc.append(a); hts.append(a + d + l)
            total += a + d + l + (start + count < n ? lineSpacing : 0)
            start += count
        }
        return Laid(lines: lines, widths: widths, ascents: asc, heights: hts, total: total)
    }

    /// Text sprite filling `w` x `h` (box size). The text is wrapped to the width and shrunk until it fits the height.
    static func text(_ st: TextStyle, string: String, w: Int, h: Int) -> CGImage? {
        let s = st.allCaps ? string.uppercased() : string
        return Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            drawText(c, st, s, rect: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    private struct Placed { var line: CTLine; var x: CGFloat; var baseline: CGFloat; var squeeze: CGFloat; var width: CGFloat; var top: CGFloat; var height: CGFloat }
    private static func drawPlaced(_ c: CGContext, _ pl: [Placed], mode: CGTextDrawingMode, fill: CGColor?, stroke: CGColor? = nil, lineWidth: CGFloat = 0) {
        for p in pl {
            c.saveGState()
            c.translateBy(x: p.x, y: p.baseline); c.scaleBy(x: p.squeeze, y: 1); c.translateBy(x: -p.x, y: -p.baseline)
            c.setTextDrawingMode(mode)
            if let f = fill { c.setFillColor(f) }
            if let s = stroke { c.setStrokeColor(s); c.setLineWidth(lineWidth); c.setLineJoin(.round) }
            c.textPosition = CGPoint(x: p.x, y: p.baseline)
            CTLineDraw(p.line, c)
            c.restoreGState()
        }
    }
    static func drawText(_ c: CGContext, _ st: TextStyle, _ s: String, rect: CGRect) {
        guard !s.isEmpty else { return }
        var size = CGFloat(st.size)
        let pad = CGFloat(max(st.stroke.width, 0)) / 2
        let avail = rect.insetBy(dx: pad, dy: pad)
        var laid = layout(attributed(s, st, size: size, color: st.color.cgColor), width: avail.width, lineSpacing: CGFloat(st.lineSpacing))
        var tries = 0
        let maxLines = st.maxLines.map { max(1, $0) } ?? Int.max
        while laid.total > avail.height + 0.5 || laid.lines.count > maxLines, size > 6, tries < 30 {      // shrink to fit (height, line cap)
            size *= 0.92; tries += 1
            laid = layout(attributed(s, st, size: size, color: st.color.cgColor), width: avail.width, lineSpacing: CGFloat(st.lineSpacing))
        }
        var y = avail.minY + (avail.height - laid.total) / 2
        var placed: [Placed] = []
        for (i, line) in laid.lines.enumerated() {
            let lw = laid.widths[i]
            var squeeze: CGFloat = 1
            var x: CGFloat
            switch st.alignment {
            case .left: x = avail.minX
            case .center: x = avail.minX + (avail.width - lw) / 2
            case .right: x = avail.maxX - lw
            }
            if lw > avail.width + 0.5 { squeeze = avail.width / lw; x = avail.minX }     // very long single word: squeeze instead of clipping
            placed.append(Placed(line: line, x: x, baseline: y + laid.ascents[i], squeeze: squeeze, width: lw * squeeze, top: y, height: laid.heights[i]))
            y += laid.heights[i] + CGFloat(st.lineSpacing)
        }
        c.saveGState()
        c.setShouldSmoothFonts(false)
        if st.shadow.isOn {
            c.saveGState()
            c.setShadow(offset: CGSize(width: st.shadow.dx, height: -st.shadow.dy), blur: CGFloat(st.shadow.blur), color: st.shadow.color.cgColor)
            drawPlaced(c, placed, mode: st.stroke.width > 0 ? .fillStroke : .fill, fill: st.color.cgColor, stroke: st.stroke.color.cgColor, lineWidth: CGFloat(st.stroke.width) * 2)
            c.restoreGState()
        }
        if st.stroke.width > 0 {
            drawPlaced(c, placed, mode: .stroke, fill: nil, stroke: st.stroke.color.cgColor, lineWidth: CGFloat(st.stroke.width) * 2)
        }
        if let g = st.gradient, let bounds = placed.map({ (p: Placed) in CGRect(x: p.x, y: p.top, width: p.width, height: p.height) }).reduce(nil as CGRect?, { (acc: CGRect?, r: CGRect) in acc.map { $0.union(r) } ?? r }) {
            // gradient text: gradient x text-alpha computed in a scratch bitmap, then drawn over the stroke / shadow
            let w = Int(ceil(rect.width)), h = Int(ceil(rect.height))
            let ink = Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { t in
                t.setShouldSmoothFonts(false)
                drawPlaced(t, placed, mode: .fill, fill: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            }
            let filled = Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { t in
                paint(g, in: t, rect: bounds)
                if let ink {
                    t.setBlendMode(.destinationIn)
                    t.translateBy(x: 0, y: CGFloat(h)); t.scaleBy(x: 1, y: -1)
                    t.draw(ink, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            if let filled {
                c.saveGState(); c.translateBy(x: rect.minX, y: rect.minY + CGFloat(h)); c.scaleBy(x: 1, y: -1)
                c.draw(filled, in: CGRect(x: 0, y: 0, width: w, height: h)); c.restoreGState()
            }
        } else {
            drawPlaced(c, placed, mode: .fill, fill: st.color.cgColor)
        }
        c.restoreGState()
    }

    /// Width of one line of text (px) -- used to build tickers.
    static func lineWidth(_ st: TextStyle, _ s: String) -> CGFloat {
        let l = CTLineCreateWithAttributedString(attributed(s, st, size: CGFloat(st.size), color: st.color.cgColor))
        return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    }

    /// Seamless ticker strip: the text repeated so that `periodWidth` scrolls forever. Returns (image, period px).
    static func tickerStrip(text: String, fontSize: CGFloat, color: RGBA, h: Int, minWidth: Int) -> (CGImage, CGFloat)? {
        var st = TextStyle(text, size: Double(fontSize), weight: 700, color: color)
        st.tracking = 1
        let item = text + "     \u{25C6}     "
        let w = max(40, lineWidth(st, item))
        let reps = max(1, Int(ceil(CGFloat(minWidth) / w)) + 1)
        let width = min(maxSide, Int(ceil(w * CGFloat(reps))))
        guard let img = Art.image(width: CGFloat(width), height: CGFloat(h), scale: 1, { c in
            c.setShouldSmoothFonts(false)
            let line = CTLineCreateWithAttributedString(attributed(item, st, size: fontSize, color: color.cgColor))
            var a: CGFloat = 0, d: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &a, &d, nil)
            let base = (CGFloat(h) - (a + d)) / 2 + a
            for i in 0..<reps { c.textPosition = CGPoint(x: CGFloat(i) * w, y: base); CTLineDraw(line, c) }
        }) else { return nil }
        return (img, w)
    }

    /// Kill-feed row: dark pill with an accent bar on the left and the line of text.
    static func killfeedLine(text: String, accent: RGBA, textColor: RGBA, fontSize: CGFloat, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            c.setFillColor(CGColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 0.78)); c.addPath(CGPath(rect: r, transform: nil)); c.fillPath()
            c.setFillColor(accent.cgColor); c.fill(CGRect(x: 0, y: 0, width: max(4, CGFloat(h) * 0.12), height: CGFloat(h)))
            var st = TextStyle(text, size: Double(fontSize), weight: 700, color: textColor)
            st.alignment = .left
            drawText(c, st, text, rect: CGRect(x: CGFloat(h) * 0.35, y: 0, width: CGFloat(w) - CGFloat(h) * 0.5, height: CGFloat(h)))
        }
    }
}
