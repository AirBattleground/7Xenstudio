// CoreText/CoreGraphics drawing of overlays, slate and labels into cached CGImages.
import Foundation
import CoreGraphics
import CoreText

enum Art {
    static let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    static let teal: UInt32 = 0x2DD4C4

    static func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
    }

    /// Draws in a top-left-origin space of `width` x `height` design units; the bitmap is `scale` pixels per unit.
    static func image(width: CGFloat, height: CGFloat, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let pw = max(1, Int(ceil(width * scale))), ph = max(1, Int(ceil(height * scale)))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true); ctx.setShouldSmoothFonts(false)
        draw(ctx)
        return ctx.makeImage()
    }

    static func line(_ s: String, size: CGFloat, bold: Bool = true, color c: CGColor) -> CTLine {
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium") as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: c]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
    }
    static func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    static func draw(_ l: CTLine, _ ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l, ctx)
    }
    /// Centred text, squeezed horizontally when wider than maxW (canvas fillText maxWidth behaviour).
    static func drawCentered(_ l: CTLine, _ ctx: CGContext, cx: CGFloat, baseline: CGFloat, maxW: CGFloat) {
        let w = width(l)
        ctx.saveGState()
        if w > maxW {
            ctx.translateBy(x: cx - maxW / 2, y: 0); ctx.scaleBy(x: maxW / w, y: 1)
            draw(l, ctx, x: 0, baseline: baseline)
        } else { draw(l, ctx, x: cx - w / 2, baseline: baseline) }
        ctx.restoreGState()
    }

    static func roundedPath(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

    // MARK: pieces (S = pixels per 1280-design unit)

    static func mask(w: Int, h: Int, radius: CGFloat) -> CGImage? {
        image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            c.setFillColor(color(0xFFFFFF)); c.addPath(roundedPath(CGRect(x: 0, y: 0, width: w, height: h), radius)); c.fillPath()
        }
    }
    static func border(w: Int, h: Int, radius: CGFloat, lineWidth: CGFloat) -> CGImage? {
        image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            c.setStrokeColor(color(teal, 0.55)); c.setLineWidth(lineWidth)
            c.addPath(roundedPath(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: lineWidth / 2, dy: lineWidth / 2), radius)); c.strokePath()
        }
    }
    static func label(_ text: String, w: Int, h: Int) -> CGImage? {
        image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            let l = line(text, size: max(14, (CGFloat(h) * 0.045).rounded()), color: color(0xFFFFFF, 0.55))
            drawCentered(l, c, cx: CGFloat(w) / 2, baseline: CGFloat(h) / 2 + 6, maxW: CGFloat(w) * 0.92)
        }
    }
    static func slateText(title: String, text: String, w: Int, h: Int) -> CGImage? {
        image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            let fw = CGFloat(w), fh = CGFloat(h)
            drawCentered(line(title.uppercased(), size: (fh * 0.035).rounded(), color: color(teal)), c, cx: fw / 2, baseline: fh * 0.4, maxW: fw)
            drawCentered(line(text.uppercased(), size: (fh * 0.12).rounded(), color: color(0xFFFFFF)), c, cx: fw / 2, baseline: fh * 0.55, maxW: fw * 0.9)
        }
    }
    static func liveBug(time: String, S: CGFloat) -> CGImage? {
        image(width: 188, height: 34, scale: S) { c in
            c.setFillColor(color(0xE5252A)); c.fill(CGRect(x: 0, y: 0, width: 80, height: 34))
            c.setFillColor(color(0x000000, 0.65)); c.fill(CGRect(x: 80, y: 0, width: 108, height: 34))
            draw(line("● LIVE", size: 22, color: color(0xFFFFFF)), c, x: 8, baseline: 25)
            draw(line(time, size: 22, color: color(0xFFFFFF)), c, x: 90, baseline: 25)
        }
    }
    /// Returns the image and its width in design units.
    static func lowerThird(title: String, subtitle: String, S: CGFloat) -> (CGImage, CGFloat)? {
        let t = line(title, size: 30, color: color(0xFFFFFF))
        let w = max(320, width(t) + 48)
        guard let img = image(width: 8 + w, height: 64, scale: S, { c in
            c.setFillColor(color(teal)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 64))
            c.setFillColor(color(0x040A0C, 0.88)); c.fill(CGRect(x: 8, y: 0, width: w, height: 64))
            draw(t, c, x: 24, baseline: 32)
            draw(line(subtitle.uppercased(), size: 18, color: color(teal)), c, x: 24, baseline: 54)
        }) else { return nil }
        return (img, 8 + w)
    }
    static func tickerBar(S: CGFloat) -> CGImage? {
        image(width: 1280, height: 44, scale: S) { c in
            c.setFillColor(color(0x040A0C, 0.92)); c.fill(CGRect(x: 0, y: 0, width: 1280, height: 44))
            c.setFillColor(color(0xE5252A)); c.fill(CGRect(x: 0, y: 0, width: 96, height: 44))
            draw(line("LIVE", size: 20, color: color(0xFFFFFF)), c, x: 24, baseline: 29)
        }
    }
    /// One scroll period repeated enough times to fill the bar. Returns (image, periodWidth in design units).
    static func tickerStrip(text: String, S: CGFloat) -> (CGImage, CGFloat)? {
        let l = line("\(text)   ◆   ", size: 20, color: color(0xFFFFFF))
        let w = max(20, width(l))
        let reps = Int(ceil(1280 / w)) + 1
        guard let img = image(width: w * CGFloat(reps), height: 44, scale: S, { c in
            for i in 0..<reps { draw(l, c, x: CGFloat(i) * w, baseline: 29) }
        }) else { return nil }
        return (img, w)
    }
}
