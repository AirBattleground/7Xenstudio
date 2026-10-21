#!/usr/bin/env swift
// Generates the 7XEN Studio app icon: 1024px PNG -> .iconset -> .icns.  Usage: swift scripts/make-icon.swift [out-dir]
import AppKit
import CoreGraphics
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build-icon", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1), CGColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Red tally glow
    let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.55), CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])
    ctx.restoreGState()

    // Monitor frame with tally border
    let mon = CGRect(x: 232, y: 330, width: 560, height: 315)
    let monPath = CGPath(roundedRect: mon, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.addPath(monPath); ctx.setFillColor(CGColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1)); ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)); ctx.setLineWidth(26)
    ctx.addPath(monPath); ctx.strokePath()

    // Big "7" inside
    let font = NSFont.systemFont(ofSize: 360, weight: .black) as CTFont
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "7", attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: mon.midX - b.width / 2 - b.minX, y: mon.midY - b.height / 2 - b.minY)
    CTLineDraw(line, ctx)

    // Stand + tally lamp
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
    ctx.fill(CGRect(x: 462, y: 262, width: 100, height: 44))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 372, y: 224, width: 280, height: 38), cornerWidth: 19, cornerHeight: 19, transform: nil)); ctx.fillPath()
    ctx.setFillColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 232 + 560 - 74, y: 645 + 22, width: 44, height: 44))

    // Top highlight
    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); ctx.setLineWidth(4); ctx.addPath(squircle); ctx.strokePath()
    ctx.restoreGState()

    let img = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print("Wrote \(out.path)/AppIcon.icns")
