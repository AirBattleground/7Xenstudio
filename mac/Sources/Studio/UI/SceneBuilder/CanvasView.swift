// Interactive artboard: zoom/pan, selection handles, drag/resize/rotate, snapping with smart guides, marquee,
// rulers + user guides, grid and safe-area overlays, drag & drop from the library. One AppKit view so event handling is predictable.
import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class CanvasState {
    var zoom: Double = 0.5
    var origin: CGPoint = .zero
    var showGrid = false
    var showSafe = true
    var showRulers = true
    var showGuides = true
    var snapOn = true
    var gridSize: Double = 40
    var spaceDown = false
    var fitRequested = true
    /// Animation / FX preview clock. nil = still frame.
    var previewClock: Double?
    var fxMotion = false
    var viewSize: CGSize = .zero
    var cursorCanvas: CGPoint?

    var map: EditorMath.ViewMap { EditorMath.ViewMap(zoom: zoom, origin: origin) }
    func fit(canvas: CGSize, rulers: Bool? = nil) {
        guard viewSize.width > 10 else { return }
        let inset: Double = (rulers ?? showRulers) ? 22 : 0
        let m = EditorMath.ViewMap.fit(canvas: canvas, in: CGSize(width: viewSize.width - inset, height: viewSize.height - inset), padding: 36)
        zoom = m.zoom; origin = CGPoint(x: m.origin.x + inset, y: m.origin.y + inset)
    }
    func zoom(to z: Double, about v: CGPoint? = nil) {
        let nz = min(8, max(0.05, z))
        let c = v ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let m = map.zoomed(to: nz, about: c)
        zoom = m.zoom; origin = m.origin
    }
}

/// What the library drops onto the canvas.
enum LibraryDrag {
    static let prefix = "7xen-lib:"
    static func builtin(_ id: String) -> String { prefix + "builtin:" + id }
    static func prop(_ id: String) -> String { prefix + "prop:" + id }
    static func tool(_ name: String) -> String { prefix + "tool:" + name }
    static func source(_ json: String) -> String { prefix + "source:" + json }
    static func parse(_ s: String) -> (kind: String, value: String)? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count)
        guard let i = rest.firstIndex(of: ":") else { return nil }
        return (String(rest[..<i]), String(rest[rest.index(after: i)...]))
    }
}

struct CanvasView: NSViewRepresentable {
    var model: SceneEditorModel
    var state: CanvasState
    var env: SceneEditorEnvironment

    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model, state: state, env: env) }
    func updateNSView(_ v: CanvasNSView, context: Context) {
        _ = model.revision; _ = state.zoom; _ = state.origin; _ = state.showGrid; _ = state.showSafe; _ = state.showRulers; _ = state.showGuides
        _ = model.selection; _ = model.guides.count; _ = state.previewClock; _ = model.variables
        v.refresh()
    }
}

final class CanvasNSView: NSView {
    let model: SceneEditorModel
    let state: CanvasState
    let env: SceneEditorEnvironment
    private var sceneImage: CGImage?
    private var renderedRev = -1, renderedWidth = 0
    private var rendering = false, again = false
    private var lastClock: Double?
    private var snapLines: [GuideLine] = []
    private var marquee: CGRect?
    private var hover: String?
    private var hoverHandle: EditorHandle?
    private var hud: String?
    private var hudPoint: CGPoint = .zero
    private var timer: Timer?

    enum Drag {
        case none, pan(start: CGPoint, origin: CGPoint)
        case move(start: CGPoint, initial: [String: CGPoint], bounds: CGRect, dup: Bool)
        case resize(handle: EditorHandle, rect: CGRect, rotation: Double, initial: [String: CGRect], aspectLayer: Bool)
        case rotate(initial: [String: Double], startAngle: Double, center: CGPoint)
        case marquee(start: CGPoint, extend: Bool)
        case guide(id: String?, vertical: Bool)
    }
    private var drag = Drag.none
    private var didDup = false

    @MainActor init(model: SceneEditorModel, state: CanvasState, env: SceneEditorEnvironment) {
        self.model = model; self.state = state; self.env = env
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.05, green: 0.052, blue: 0.06, alpha: 1).cgColor
        registerForDraggedTypes([.string, .fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var rulerInset: CGFloat { state.showRulers ? 22 : 0 }
    private var map: EditorMath.ViewMap { state.map }
    private var cs: CGSize { model.canvasSize }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated {
            state.viewSize = bounds.size
            if state.fitRequested, bounds.width > 10 { state.fit(canvas: cs); state.fitRequested = false }
        }
        needsDisplay = true
    }

    // MARK: rendering
    @MainActor func refresh() {
        if state.fitRequested, bounds.width > 10 { state.fit(canvas: cs); state.fitRequested = false }
        scheduleRender()
        updateTimer()
        needsDisplay = true
    }
    @MainActor private func updateTimer() {
        let need = state.previewClock != nil || state.fxMotion
        if need, timer == nil {
            let start = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let t = CACurrentMediaTime() - start
                    if self.state.previewClock != nil { self.state.previewClock = t; if t > 6 { self.state.previewClock = nil } }
                    self.lastClock = nil
                    self.scheduleRender(force: true)
                }
            }
        } else if !need, let t = timer { t.invalidate(); timer = nil }
    }
    @MainActor private func targetWidth() -> Int {
        let backing = window?.backingScaleFactor ?? 2
        let w = Double(cs.width) * state.zoom * backing
        return Int(min(1920, max(480, (w / 160).rounded(.up) * 160)))
    }
    @MainActor func scheduleRender(force: Bool = false) {
        let w = targetWidth()
        if !force, model.revision == renderedRev, w == renderedWidth, lastClock == state.previewClock, !state.fxMotion { return }
        if rendering { again = true; return }
        rendering = true
        let rev = model.revision
        let scene = model.scene
        var e = env.rasterEnv(for: scene, variables: model.variables)
        if let c = state.previewClock { e.showClock = c; e.time = c }
        else if state.fxMotion { e.time = CACurrentMediaTime().truncatingRemainder(dividingBy: 1000); e.showClock = nil }
        let clock = state.previewClock
        // the real engine draws the canvas (identical to the stream); while an object is being dragged / resized the CoreGraphics rasteriser
        // keeps interaction instant.
        var interacting = false
        if case .none = drag {} else { interacting = true }
        let still = env.app.services.stillRenderer()
        let vars = SceneVariables(model.variables.values.merging(scene.variableDefaults) { cur, _ in cur })
        let animated = state.previewClock != nil || state.fxMotion
        let pc = state.previewClock, fxT = CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)
        let ew = min(w, 1280)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var img: CGImage?
            if !interacting {
                let t = pc ?? (animated ? fxT : 4)
                let ac: AnimClock? = pc.map { AnimClock(sinceShow: $0, sinceTake: $0, time: $0) }
                img = still(scene, CGSize(width: Double(ew), height: Double(ew) * Double(scene.canvas.h) / Double(max(1, scene.canvas.w))), vars, t, ac)
            }
            if img == nil { img = SceneRasterizer.render(scene, width: w, env: e) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rendering = false
                    self.sceneImage = img; self.renderedRev = rev; self.renderedWidth = w; self.lastClock = clock
                    self.needsDisplay = true
                    if self.again || self.model.revision != rev { self.again = false; self.scheduleRender() }
                }
            }
        }
    }

    // MARK: drawing
    private let accent = NSColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 1)
    private let magenta = NSColor(red: 1.0, green: 0.25, blue: 0.7, alpha: 1)

    override func draw(_ dirty: NSRect) {
        MainActor.assumeIsolated { drawAll() }
    }
    @MainActor private func drawAll() {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let m = map
        let art = m.toView(CGRect(origin: .zero, size: cs))
        // artboard shadow + image
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: CGColor(gray: 0, alpha: 0.6))
        g.setFillColor(CGColor(gray: 0.02, alpha: 1)); g.fill(art)
        g.restoreGState()
        if let img = sceneImage {
            g.saveGState(); g.clip(to: art)
            g.interpolationQuality = .high
            g.translateBy(x: art.minX, y: art.maxY); g.scaleBy(x: 1, y: -1)
            g.draw(img, in: CGRect(x: 0, y: 0, width: art.width, height: art.height))
            g.restoreGState()
        }
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); g.setLineWidth(1); g.stroke(art.insetBy(dx: -0.5, dy: -0.5))

        g.saveGState()
        g.clip(to: art.insetBy(dx: -2000, dy: -2000).intersection(bounds))
        if state.showGrid { drawGrid(g, art) }
        if state.showSafe { drawSafe(g, art) }
        if state.showGuides { drawGuides(g, art) }
        drawSelection(g)
        for l in snapLines { drawGuideLine(g, l, color: magenta) }
        if let mq = marquee {
            let r = m.toView(mq)
            g.setFillColor(accent.withAlphaComponent(0.12).cgColor); g.fill(r)
            g.setStrokeColor(accent.cgColor); g.setLineWidth(1); g.stroke(r)
        }
        g.restoreGState()
        if state.showRulers { drawRulers(g) }
        if let h = hud { drawHUD(g, h, at: hudPoint) }
    }

    @MainActor private func drawGrid(_ g: CGContext, _ art: CGRect) {
        let step = state.gridSize * state.zoom
        guard step >= 6 else { return }
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.07)); g.setLineWidth(1)
        var x = art.minX; while x <= art.maxX { g.move(to: CGPoint(x: x, y: art.minY)); g.addLine(to: CGPoint(x: x, y: art.maxY)); x += step }
        var y = art.minY; while y <= art.maxY { g.move(to: CGPoint(x: art.minX, y: y)); g.addLine(to: CGPoint(x: art.maxX, y: y)); y += step }
        g.strokePath()
    }
    @MainActor private func drawSafe(_ g: CGContext, _ art: CGRect) {
        g.setLineWidth(1); g.setLineDash(phase: 0, lengths: [5, 4])
        g.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 0.55)); g.stroke(art.insetBy(dx: art.width * 0.05, dy: art.height * 0.05))     // action safe 90 %
        g.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 0.6, alpha: 0.5)); g.stroke(art.insetBy(dx: art.width * 0.10, dy: art.height * 0.10))     // title safe 80 %
        g.setLineDash(phase: 0, lengths: [])
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        g.move(to: CGPoint(x: art.midX, y: art.minY)); g.addLine(to: CGPoint(x: art.midX, y: art.maxY))
        g.move(to: CGPoint(x: art.minX, y: art.midY)); g.addLine(to: CGPoint(x: art.maxX, y: art.midY)); g.strokePath()
    }
    @MainActor private func drawGuides(_ g: CGContext, _ art: CGRect) {
        for gd in model.guides {
            g.setStrokeColor(CGColor(red: 0.2, green: 0.9, blue: 1, alpha: 0.85)); g.setLineWidth(1)
            if gd.vertical { let x = map.toView(CGPoint(x: gd.position, y: 0)).x; g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: bounds.height)) }
            else { let y = map.toView(CGPoint(x: 0, y: gd.position)).y; g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: bounds.width, y: y)) }
            g.strokePath()
        }
    }
    @MainActor private func drawGuideLine(_ g: CGContext, _ l: GuideLine, color: NSColor) {
        g.setStrokeColor(color.cgColor); g.setLineWidth(1)
        if l.vertical {
            let x = (map.toView(CGPoint(x: l.position, y: 0)).x).rounded() + 0.5
            g.move(to: CGPoint(x: x, y: map.toView(CGPoint(x: 0, y: l.from)).y)); g.addLine(to: CGPoint(x: x, y: map.toView(CGPoint(x: 0, y: l.to)).y))
        } else {
            let y = (map.toView(CGPoint(x: 0, y: l.position)).y).rounded() + 0.5
            g.move(to: CGPoint(x: map.toView(CGPoint(x: l.from, y: 0)).x, y: y)); g.addLine(to: CGPoint(x: map.toView(CGPoint(x: l.to, y: 0)).x, y: y))
        }
        g.strokePath()
    }

    @MainActor private func quad(_ rect: CGRect, _ rot: Double) -> [CGPoint] { EditorMath.corners(rect, rotation: rot).map { map.toView($0) } }
    @MainActor private func strokeQuad(_ g: CGContext, _ pts: [CGPoint], _ color: NSColor, width: CGFloat = 1, dash: [CGFloat] = []) {
        guard pts.count == 4 else { return }
        g.setStrokeColor(color.cgColor); g.setLineWidth(width); g.setLineDash(phase: 0, lengths: dash)
        g.move(to: pts[0]); for p in pts.dropFirst() { g.addLine(to: p) }; g.closePath(); g.strokePath(); g.setLineDash(phase: 0, lengths: [])
    }

    @MainActor private func selectionFrame() -> (rect: CGRect, rotation: Double)? {
        let sel = model.selectedLayers
        guard !sel.isEmpty else { return nil }
        if sel.count == 1, let r = model.canvasRect(sel[0].id) { return (r, sel[0].transform.rotation) }
        let rects = sel.compactMap { l in model.canvasRect(l.id).map { EditorMath.boundingBox($0, rotation: l.transform.rotation) } }
        return (EditorMath.union(rects), 0)
    }

    @MainActor private func drawSelection(_ g: CGContext) {
        if let h = hover, !model.isSelected(h), let r = model.canvasRect(h), let l = model.layer(h) {
            strokeQuad(g, quad(r, l.transform.rotation), accent.withAlphaComponent(0.7), width: 1)
        }
        let sel = model.selectedLayers
        guard !sel.isEmpty else { return }
        for l in sel { if let r = model.canvasRect(l.id) { strokeQuad(g, quad(r, l.transform.rotation), accent, width: sel.count > 1 ? 1 : 1.5, dash: l.locked ? [4, 3] : []) } }
        guard let f = selectionFrame() else { return }
        if sel.count > 1 { strokeQuad(g, quad(f.rect, 0), accent.withAlphaComponent(0.8), width: 1, dash: [5, 3]) }
        if sel.allSatisfy({ $0.locked }) { return }
        // handles
        let off = 28.0 / state.zoom
        let top = map.toView(EditorMath.handlePoint(.top, rect: f.rect, rotation: f.rotation))
        let knob = map.toView(EditorMath.handlePoint(.rotate, rect: f.rect, rotation: f.rotation, rotateOffset: off))
        g.setStrokeColor(accent.cgColor); g.setLineWidth(1); g.move(to: top); g.addLine(to: knob); g.strokePath()
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        g.setStrokeColor(accent.cgColor); g.setLineWidth(1.5); g.strokeEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        for h in EditorHandle.resizing {
            let p = map.toView(EditorMath.handlePoint(h, rect: f.rect, rotation: f.rotation))
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            g.setFillColor(NSColor.white.cgColor); g.fill(r)
            g.setStrokeColor(accent.cgColor); g.setLineWidth(1.5); g.stroke(r)
        }
    }

    @MainActor private func drawRulers(_ g: CGContext) {
        let R = rulerInset
        let bg = CGColor(red: 0.098, green: 0.102, blue: 0.118, alpha: 1)
        g.setFillColor(bg); g.fill(CGRect(x: 0, y: 0, width: bounds.width, height: R)); g.fill(CGRect(x: 0, y: 0, width: R, height: bounds.height))
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.1)); g.setLineWidth(1)
        g.move(to: CGPoint(x: 0, y: R - 0.5)); g.addLine(to: CGPoint(x: bounds.width, y: R - 0.5)); g.move(to: CGPoint(x: R - 0.5, y: 0)); g.addLine(to: CGPoint(x: R - 0.5, y: bounds.height)); g.strokePath()
        let z = state.zoom
        var step = 100.0
        for s in [10.0, 20, 50, 100, 200, 500, 1000] { if s * z >= 60 { step = s; break } }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.45)]
        let minor = step / 5
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        var v = (-map.origin.x / z / minor).rounded(.down) * minor
        while map.toView(CGPoint(x: v, y: 0)).x < bounds.width {
            let x = map.toView(CGPoint(x: v, y: 0)).x
            if x > R { let major = Int((v / step).rounded()) * Int(step) == Int(v.rounded()) && v.truncatingRemainder(dividingBy: step) == 0
                g.move(to: CGPoint(x: x + 0.5, y: major ? 6 : 15)); g.addLine(to: CGPoint(x: x + 0.5, y: R))
                if major { ("\(Int(v))" as NSString).draw(at: CGPoint(x: x + 3, y: 1), withAttributes: attrs) } }
            v += minor
        }
        v = (-map.origin.y / z / minor).rounded(.down) * minor
        while map.toView(CGPoint(x: 0, y: v)).y < bounds.height {
            let y = map.toView(CGPoint(x: 0, y: v)).y
            if y > R { let major = v.truncatingRemainder(dividingBy: step) == 0
                g.move(to: CGPoint(x: major ? 6 : 15, y: y + 0.5)); g.addLine(to: CGPoint(x: R, y: y + 0.5))
                if major {
                    g.saveGState(); g.translateBy(x: 1, y: y - 3); g.rotate(by: -.pi / 2)
                    ("\(Int(v))" as NSString).draw(at: .zero, withAttributes: attrs); g.restoreGState()
                } }
            v += minor
        }
        g.strokePath()
        // cursor + selection extents
        if let f = selectionFrame() {
            let bb = EditorMath.boundingBox(f.rect, rotation: f.rotation)
            g.setFillColor(accent.withAlphaComponent(0.35).cgColor)
            g.fill(CGRect(x: map.toView(CGPoint(x: bb.minX, y: 0)).x, y: 0, width: bb.width * z, height: R))
            g.fill(CGRect(x: 0, y: map.toView(CGPoint(x: 0, y: bb.minY)).y, width: R, height: bb.height * z))
        }
        g.setFillColor(bg); g.fill(CGRect(x: 0, y: 0, width: R, height: R))
    }

    @MainActor private func drawHUD(_ g: CGContext, _ text: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        var r = CGRect(x: p.x + 14, y: p.y + 14, width: sz.width + 14, height: sz.height + 8)
        if r.maxX > bounds.maxX { r.origin.x = p.x - 14 - r.width }
        if r.maxY > bounds.maxY { r.origin.y = p.y - 14 - r.height }
        g.setFillColor(CGColor(gray: 0, alpha: 0.78)); g.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); g.fillPath()
        s.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 4))
    }

    // MARK: mouse
    @MainActor private func canvasPoint(_ e: NSEvent) -> CGPoint { map.toCanvas(convert(e.locationInWindow, from: nil)) }
    @MainActor private var threshold: Double { 6 / state.zoom }

    @MainActor private func handleHit(_ p: CGPoint) -> EditorHandle? {
        guard let f = selectionFrame(), !model.selectedLayers.allSatisfy(\.locked) else { return nil }
        return EditorMath.hitHandle(p, rect: f.rect, rotation: f.rotation, radius: 8 / state.zoom, rotateOffset: 28 / state.zoom)
    }

    override func mouseDown(with e: NSEvent) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            let vp = convert(e.locationInWindow, from: nil)
            let p = map.toCanvas(vp)
            didDup = false
            if state.spaceDown || e.buttonNumber == 2 { drag = .pan(start: vp, origin: state.origin); NSCursor.closedHand.set(); return }
            if state.showRulers {
                if vp.y < rulerInset && vp.x > rulerInset { drag = .guide(id: nil, vertical: false); newGuide(vertical: false, at: p.y); return }
                if vp.x < rulerInset && vp.y > rulerInset { drag = .guide(id: nil, vertical: true); newGuide(vertical: true, at: p.x); return }
            }
            if let gd = model.guides.first(where: { abs(($0.vertical ? vp.x - map.toView(CGPoint(x: $0.position, y: 0)).x : vp.y - map.toView(CGPoint(x: 0, y: $0.position)).y)) < 3 }), hitLayer(p) == nil, handleHit(p) == nil {
                drag = .guide(id: gd.id, vertical: gd.vertical); return
            }
            if let h = handleHit(p), let f = selectionFrame() {
                let sel = model.selectedLayers
                model.beginGesture(h == .rotate ? "Rotate" : "Resize")
                if h == .rotate {
                    drag = .rotate(initial: Dictionary(uniqueKeysWithValues: sel.map { ($0.id, $0.transform.rotation) }),
                                   startAngle: atan2(p.y - f.rect.midY, p.x - f.rect.midX), center: CGPoint(x: f.rect.midX, y: f.rect.midY))
                } else {
                    let single = sel.count == 1
                    let aspect: Bool = single && { if case .image = sel[0].kind { return true }; if case .source = sel[0].kind { return false }; return false }()
                    drag = .resize(handle: h, rect: f.rect, rotation: f.rotation,
                                   initial: Dictionary(uniqueKeysWithValues: sel.compactMap { l in model.canvasRect(l.id).map { (l.id, $0) } }), aspectLayer: aspect)
                }
                return
            }
            if let id = hitLayer(p) {
                let extend = e.modifierFlags.contains(.shift)
                let dupNow = e.modifierFlags.contains(.option) && !extend
                if extend { model.select(id, extend: true) }
                else if !model.isSelected(id) { model.select(id) }
                if e.clickCount == 2 { NotificationCenter.default.post(name: .sceneEditorFocusInspector, object: id) }
                if dupNow { model.duplicateSelected(offset: 0) }
                let sel = model.selectedLayers.filter { !$0.locked }
                guard !sel.isEmpty, !(extend && !model.isSelected(id)) else { drag = .none; needsDisplay = true; return }
                model.beginGesture("Move")
                let rects = sel.compactMap { l in model.canvasRect(l.id).map { EditorMath.boundingBox($0, rotation: l.transform.rotation) } }
                drag = .move(start: p, initial: Dictionary(uniqueKeysWithValues: sel.map { ($0.id, CGPoint(x: $0.transform.x, y: $0.transform.y)) }),
                             bounds: EditorMath.union(rects), dup: false)
            } else {
                if !e.modifierFlags.contains(.shift) { model.select(nil) }
                drag = .marquee(start: p, extend: e.modifierFlags.contains(.shift))
            }
            needsDisplay = true
        }
    }

    @MainActor private func hitLayer(_ p: CGPoint) -> String? { model.hitTest(p) }
    @MainActor private func newGuide(vertical: Bool, at pos: Double) {
        let g = EditorGuide(vertical: vertical, position: pos)
        model.guides.append(g); drag = .guide(id: g.id, vertical: vertical)
    }

    override func mouseDragged(with e: NSEvent) {
        MainActor.assumeIsolated {
            let vp = convert(e.locationInWindow, from: nil)
            let p = map.toCanvas(vp)
            hudPoint = vp
            switch drag {
            case .none: break
            case .pan(let s, let o): state.origin = CGPoint(x: o.x + vp.x - s.x, y: o.y + vp.y - s.y)
            case .guide(let id, let vertical):
                guard let id, let i = model.guides.firstIndex(where: { $0.id == id }) else { break }
                if (vertical && vp.x < rulerInset) || (!vertical && vp.y < rulerInset) { model.guides[i].position = -9999 } else { model.guides[i].position = (vertical ? p.x : p.y).rounded() }
                hud = "\(Int(model.guides[i].position))"
            case .marquee(let s, let extend):
                marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                model.selectRect(marquee!, extend: extend)
            case .move(let start, let initial, let bounds, _):
                var dx = p.x - start.x, dy = p.y - start.y
                if e.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
                snapLines = []
                if state.snapOn, !e.modifierFlags.contains(.command) {
                    let ids = Set(initial.keys)
                    let others = model.scene.layers.filter { $0.visible && !ids.contains($0.id) }.map { EditorMath.boundingBox($0.transform.rect, rotation: $0.transform.rotation) }
                    var snapped = bounds.offsetBy(dx: dx, dy: dy)
                    if state.showGrid, state.gridSize > 0 {
                        // grid snap is a soft candidate set
                        _ = snapped
                    }
                    let res = EditorMath.snap(moving: snapped, others: others, canvas: cs, guides: model.guides, safeInset: state.showSafe ? 0.05 : nil, threshold: threshold)
                    dx += res.dx; dy += res.dy; snapLines = res.lines
                    snapped = bounds.offsetBy(dx: dx, dy: dy)
                }
                let targets: [(String, CGPoint)] = initial.map { ($0.key, $0.value) }
                model.live { s in
                    for (id, o) in targets { LayerTree.mutate(id, in: &s.layers) { $0.transform.x = (o.x + dx).rounded(); $0.transform.y = (o.y + dy).rounded() } }
                }
                hud = "X \(Int(bounds.minX + dx))  Y \(Int(bounds.minY + dy))"
            case .resize(let h, let rect, let rot, let initial, _):
                snapLines = []
                var pt = p
                let multi = initial.count > 1
                if state.snapOn, rot == 0, !e.modifierFlags.contains(.command) {
                    let ids = Set(initial.keys)
                    let others = model.scene.layers.filter { !ids.contains($0.id) && $0.visible }.map { $0.transform.rect }
                    let xs: [Double] = [0, Double(cs.width) / 2, Double(cs.width)] + others.flatMap { [Double($0.minX), Double($0.midX), Double($0.maxX)] }
                    let ys: [Double] = [0, Double(cs.height) / 2, Double(cs.height)] + others.flatMap { [Double($0.minY), Double($0.midY), Double($0.maxY)] }
                    if h.affectsX, let sx = EditorMath.snapValue(Double(pt.x), to: xs, threshold: threshold) { pt.x = sx; snapLines.append(GuideLine(vertical: true, position: sx, from: 0, to: cs.height)) }
                    if h.affectsY, let sy = EditorMath.snapValue(Double(pt.y), to: ys, threshold: threshold) { pt.y = sy; snapLines.append(GuideLine(vertical: false, position: sy, from: 0, to: cs.width)) }
                }
                let nr = EditorMath.resize(rect: rect, rotation: rot, handle: h, to: pt, keepAspect: e.modifierFlags.contains(.shift) || (multi && h.isCorner), fromCenter: e.modifierFlags.contains(.option))
                model.live { s in
                    for (id, r0) in initial {
                        let off = LayerTree.originOffset(ofParentOf: id, in: s.layers)
                        let r: CGRect
                        if multi {
                            let sx = nr.width / max(1, rect.width), sy = nr.height / max(1, rect.height)
                            r = CGRect(x: nr.minX + (r0.minX - rect.minX) * sx, y: nr.minY + (r0.minY - rect.minY) * sy, width: r0.width * sx, height: r0.height * sy)
                        } else { r = nr }
                        LayerTree.mutate(id, in: &s.layers) { $0.transform.x = r.minX - off.x; $0.transform.y = r.minY - off.y; $0.transform.w = r.width; $0.transform.h = r.height }
                    }
                }
                hud = "\(Int(nr.width)) × \(Int(nr.height))"
            case .rotate(let initial, let startAngle, let center):
                let a = atan2(p.y - center.y, p.x - center.x)
                let delta = (a - startAngle) * 180 / .pi
                model.live { s in
                    for (id, r0) in initial {
                        var r = r0 + delta
                        if e.modifierFlags.contains(.shift) { r = (r / 15).rounded() * 15 }
                        else { for k in stride(from: -180.0, through: 180, by: 45) where abs(r.truncatingRemainder(dividingBy: 360) - k) < 2 { r = k } }
                        r = r.truncatingRemainder(dividingBy: 360); if r > 180 { r -= 360 }; if r < -180 { r += 360 }
                        LayerTree.mutate(id, in: &s.layers) { $0.transform.rotation = (r * 10).rounded() / 10 }
                    }
                }
                hud = String(format: "%.0f°", model.primary?.transform.rotation ?? 0)
            }
            scheduleRender(); needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        MainActor.assumeIsolated {
            if case .guide(let id, _) = drag, let id, let i = model.guides.firstIndex(where: { $0.id == id }), model.guides[i].position == -9999 { model.guides.remove(at: i) }
            if case .move = drag { model.endGesture() }
            else if case .resize = drag { model.endGesture() }
            else if case .rotate = drag { model.endGesture() }
            drag = .none; snapLines = []; marquee = nil; hud = nil
            scheduleRender(); needsDisplay = true
            NSCursor.arrow.set()
        }
    }
    override func otherMouseDown(with e: NSEvent) { mouseDown(with: e) }
    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func mouseMoved(with e: NSEvent) {
        MainActor.assumeIsolated {
            let p = canvasPoint(e)
            state.cursorCanvas = p
            let h = handleHit(p)
            let l = h == nil ? hitLayer(p) : nil
            if h != hoverHandle || l != hover { hoverHandle = h; hover = l; needsDisplay = true }
            if state.spaceDown { NSCursor.openHand.set() }
            else if let h {
                switch h {
                case .rotate: NSCursor.crosshair.set()
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                default: NSCursor.crosshair.set()
                }
            } else if l != nil { NSCursor.arrow.set() }
            else { NSCursor.arrow.set() }
        }
    }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { hover = nil; needsDisplay = true } }

    override func scrollWheel(with e: NSEvent) {
        MainActor.assumeIsolated {
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                let f = pow(1.0 + 0.01, Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 6))
                state.zoom(to: state.zoom * f, about: convert(e.locationInWindow, from: nil))
            } else {
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8
                state.origin = CGPoint(x: state.origin.x + e.scrollingDeltaX * k, y: state.origin.y + e.scrollingDeltaY * k)
            }
            needsDisplay = true
        }
    }
    override func magnify(with e: NSEvent) {
        MainActor.assumeIsolated { state.zoom(to: state.zoom * (1 + Double(e.magnification)), about: convert(e.locationInWindow, from: nil)); needsDisplay = true }
    }

    // MARK: context menu
    override func menu(for e: NSEvent) -> NSMenu? {
        MainActor.assumeIsolated {
            let p = canvasPoint(e)
            if let id = hitLayer(p), !model.isSelected(id) { model.select(id) }
            let m = NSMenu()
            func item(_ t: String, _ key: String = "", _ f: @escaping @MainActor () -> Void) {
                let i = ClosureMenuItem(title: t, key: key, handler: f); m.addItem(i)
            }
            let has = !model.selection.isEmpty
            if has {
                item("Duplicate", "d") { self.model.duplicateSelected() }
                item("Copy", "c") { self.model.copy() }
                item("Delete", "") { self.model.deleteSelected() }
                m.addItem(.separator())
                item("Bring to Front") { self.model.reorder(.front) }
                item("Send to Back") { self.model.reorder(.back) }
                item("Group", "g") { self.model.group() }
                item("Ungroup") { self.model.ungroup() }
                m.addItem(.separator())
                item("Flip Horizontal") { self.model.flip(horizontal: true) }
                item("Flip Vertical") { self.model.flip(horizontal: false) }
                item("Rotate 90°") { self.model.rotate90() }
                item("Fill Canvas") { self.model.fillCanvas() }
                if let id = model.selection.last, let l = model.layer(id) { item(l.locked ? "Unlock" : "Lock") { self.model.toggleLock(id) } }
            }
            item("Paste", "v") { self.model.paste() }
            m.addItem(.separator())
            item("Fit to Window", "0") { self.state.fit(canvas: self.cs) }
            return m
        }
    }

    // MARK: drag & drop
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            let vp = convert(s.draggingLocation, from: nil)
            let p = map.toCanvas(vp)
            let pb = s.draggingPasteboard
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                env.importFiles(urls, at: p, into: model); return true
            }
            if let str = pb.string(forType: .string), let (kind, value) = LibraryDrag.parse(str) {
                env.addFromLibrary(kind: kind, value: value, at: p, into: model); return true
            }
            return false
        }
    }
}

extension Notification.Name { static let sceneEditorFocusInspector = Notification.Name("sceneEditorFocusInspector") }

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(title: String, key: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}

// MARK: - keyboard shortcuts (editor-wide, ignore while a text field is being edited)

@MainActor
final class EditorKeyboard {
    private var monitor: Any?
    private weak var model: SceneEditorModel?
    private weak var state: CanvasState?
    var onSave: (() -> Void)?

    func start(model: SceneEditorModel, state: CanvasState) {
        stop()
        self.model = model; self.state = state
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handle(e) ? nil : e }
        }
    }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }; state?.spaceDown = false }

    private func typing(_ w: NSWindow?) -> Bool {
        guard let r = w?.firstResponder else { return false }
        return r is NSText || r is NSTextView
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let model, let state, let w = e.window, w.attachedSheet == nil, w.isKeyWindow else { return false }
        if typing(w) { return false }
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let ch = e.charactersIgnoringModifiers ?? ""
        if e.type == .keyUp { if ch == " " { state.spaceDown = false; return true }; return false }
        if ch == " " && !cmd { state.spaceDown = true; return true }
        if cmd {
            switch ch.lowercased() {
            case "z": shift ? model.redo() : model.undo(); return true
            case "d": model.duplicateSelected(); return true
            case "g": shift ? model.ungroup() : model.group(); return true
            case "c": model.copy(); return true
            case "x": model.cut(); return true
            case "v": model.paste(); return true
            case "a": model.selectAll(); return true
            case "l": if let id = model.selection.last { model.toggleLock(id) }; return true
            case "s": onSave?(); return true
            case "0": state.fit(canvas: model.canvasSize); return true
            case "1": state.zoom(to: 1); return true
            case "=", "+": state.zoom(to: state.zoom * 1.25); return true
            case "-": state.zoom(to: state.zoom / 1.25); return true
            case "]": model.reorder(.front); return true
            case "[": model.reorder(.back); return true
            default: return false
            }
        }
        switch e.keyCode {
        case 123: model.nudge(dx: shift ? -10 : -1, dy: 0); return true
        case 124: model.nudge(dx: shift ? 10 : 1, dy: 0); return true
        case 125: model.nudge(dx: 0, dy: shift ? 10 : 1); return true
        case 126: model.nudge(dx: 0, dy: shift ? -10 : -1); return true
        case 51, 117: model.deleteSelected(); return true
        case 53: model.selection = []; return true
        default: break
        }
        if ch == "]" { model.reorder(.forward); return true }
        if ch == "[" { model.reorder(.backward); return true }
        return false
    }
}
