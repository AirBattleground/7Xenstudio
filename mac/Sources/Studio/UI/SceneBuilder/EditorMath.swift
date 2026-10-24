// Pure geometry for the scene editor: handles, resize/rotate, snapping, hit-testing, align & distribute.
// No UI types here so everything is unit-testable. Coordinates are canvas pixels (origin top-left, y down).
import Foundation
import CoreGraphics

/// Selection handle identifiers.
enum EditorHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotate
    /// Unit position (0...1) on the box this handle sits at.
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0); case .top: CGPoint(x: 0.5, y: 0); case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5); case .bottomRight: CGPoint(x: 1, y: 1); case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1); case .left: CGPoint(x: 0, y: 0.5); case .rotate: CGPoint(x: 0.5, y: 0)
        }
    }
    var isCorner: Bool { switch self { case .topLeft, .topRight, .bottomLeft, .bottomRight: true; default: false } }
    var affectsX: Bool { switch self { case .top, .bottom, .rotate: false; default: true } }
    var affectsY: Bool { switch self { case .left, .right, .rotate: false; default: true } }
    static let resizing: [EditorHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
}

enum AlignMode: CaseIterable { case left, centerH, right, top, centerV, bottom }
enum DistributeAxis { case horizontal, vertical }

/// A guide line drawn while snapping (vertical = constant x).
struct GuideLine: Equatable {
    var vertical: Bool
    var position: Double
    var from: Double
    var to: Double
}
/// User/ruler guide.
struct EditorGuide: Hashable, Codable, Identifiable {
    var id = UUID().uuidString
    var vertical: Bool
    var position: Double
}

struct SnapResult: Equatable {
    var dx = 0.0, dy = 0.0
    var lines: [GuideLine] = []
}

enum EditorMath {
    // MARK: rotation helpers
    static func rotate(_ p: CGPoint, about c: CGPoint, degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180, s = sin(r), co = cos(r)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }
    /// The four corners (tl, tr, br, bl) of a rotated box, rotation about its centre.
    static func corners(_ r: CGRect, rotation: Double) -> [CGPoint] {
        let c = CGPoint(x: r.midX, y: r.midY)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .map { rotation == 0 ? $0 : rotate($0, about: c, degrees: rotation) }
    }
    /// Axis-aligned bounding box of a rotated box.
    static func boundingBox(_ r: CGRect, rotation: Double) -> CGRect {
        if rotation.truncatingRemainder(dividingBy: 360) == 0 { return r }
        return union(corners(r, rotation: rotation).map { CGRect(origin: $0, size: .zero) })
    }
    static func union(_ rects: [CGRect]) -> CGRect {
        guard var u = rects.first else { return .zero }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    // MARK: handles
    /// World position of a handle. `rotateOffset` is how far above the top edge the rotate knob floats (canvas px).
    static func handlePoint(_ h: EditorHandle, rect r: CGRect, rotation: Double, rotateOffset: Double = 28) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = CGPoint(x: r.minX + r.width * h.unit.x, y: r.minY + r.height * h.unit.y)
        if h == .rotate { p.y -= rotateOffset }
        return rotation == 0 ? p : rotate(p, about: c, degrees: rotation)
    }
    /// Which handle (if any) is under `p`. `radius` is in canvas px (already divided by zoom by the caller).
    static func hitHandle(_ p: CGPoint, rect: CGRect, rotation: Double, radius: Double, rotateOffset: Double = 28) -> EditorHandle? {
        // rotate knob wins when overlapping; corners win over edges
        let order: [EditorHandle] = [.rotate, .topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for h in order {
            let hp = handlePoint(h, rect: rect, rotation: rotation, rotateOffset: rotateOffset)
            if hypot(hp.x - p.x, hp.y - p.y) <= radius { return h }
        }
        return nil
    }
    static func contains(_ p: CGPoint, rect: CGRect, rotation: Double) -> Bool {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let q = rotation == 0 ? p : rotate(p, about: c, degrees: -rotation)
        return rect.contains(q)
    }

    /// New rect when dragging `handle` to world point `to`. Rotation is about the centre, so the opposite handle stays fixed in world space.
    /// `keepAspect` preserves the original ratio on corner drags (edges ignore it); `fromCenter` resizes symmetrically.
    static func resize(rect r: CGRect, rotation: Double, handle h: EditorHandle, to p: CGPoint, keepAspect: Bool = false, fromCenter: Bool = false, minSize: Double = 8) -> CGRect {
        guard h != .rotate else { return r }
        let c = CGPoint(x: r.midX, y: r.midY)
        let q = rotation == 0 ? p : rotate(p, about: c, degrees: -rotation)     // pointer in the box's local (unrotated) frame
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        let sx: CGFloat = h.unit.x == 0 ? -1 : h.unit.x == 1 ? 1 : 0
        let sy: CGFloat = h.unit.y == 0 ? -1 : h.unit.y == 1 ? 1 : 0
        if sx < 0 { minX = q.x; if fromCenter { maxX = 2 * c.x - q.x } } else if sx > 0 { maxX = q.x; if fromCenter { minX = 2 * c.x - q.x } }
        if sy < 0 { minY = q.y; if fromCenter { maxY = 2 * c.y - q.y } } else if sy > 0 { maxY = q.y; if fromCenter { minY = 2 * c.y - q.y } }
        var w = maxX - minX, hgt = maxY - minY
        if keepAspect, h.isCorner, r.width > 0, r.height > 0 {
            let ar = r.width / r.height
            // use whichever dimension changed proportionally more
            let kw = abs(w) / r.width, kh = abs(hgt) / r.height
            let k = max(kw, kh)
            w = r.width * k * (w < 0 ? -1 : 1); hgt = w == 0 ? 0 : abs(w) / ar * (hgt < 0 ? -1 : 1)
            if sx < 0 { minX = maxX - w } else { maxX = minX + w }
            if sy < 0 { minY = maxY - hgt } else { maxY = minY + hgt }
            if fromCenter { minX = c.x - w / 2; maxX = c.x + w / 2; minY = c.y - hgt / 2; maxY = c.y + hgt / 2 }
        } else if keepAspect, !h.isCorner, r.width > 0, r.height > 0 {
            // edge drag with aspect: scale the other dimension about the centre
            let ar = r.width / r.height
            if h.affectsX { let nh = abs(maxX - minX) / ar; minY = c.y - nh / 2; maxY = c.y + nh / 2 }
            else { let nw = abs(maxY - minY) * ar; minX = c.x - nw / 2; maxX = c.x + nw / 2 }
        }
        var nx0 = min(minX, maxX), nx1 = max(minX, maxX), ny0 = min(minY, maxY), ny1 = max(minY, maxY)
        if nx1 - nx0 < minSize { if sx < 0 { nx0 = nx1 - minSize } else { nx1 = nx0 + minSize } }
        if ny1 - ny0 < minSize { if sy < 0 { ny0 = ny1 - minSize } else { ny1 = ny0 + minSize } }
        let local = CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0)
        if rotation == 0 { return local }
        // The local-frame rect is relative to the OLD centre; shift so the fixed (opposite) anchor stays put in world space.
        let newCenterLocal = CGPoint(x: local.midX, y: local.midY)
        let newCenterWorld = rotate(newCenterLocal, about: c, degrees: rotation)
        return CGRect(x: newCenterWorld.x - local.width / 2, y: newCenterWorld.y - local.height / 2, width: local.width, height: local.height)
    }

    /// Rotation (degrees) for dragging the rotate knob to `p`; `snap15` snaps to 15 degree steps.
    static func rotation(rect r: CGRect, to p: CGPoint, snap15: Bool) -> Double {
        let c = CGPoint(x: r.midX, y: r.midY)
        var deg = atan2(p.y - c.y, p.x - c.x) * 180 / .pi + 90      // knob sits above the box at 0 degrees
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg > 180 { deg -= 360 }; if deg <= -180 { deg += 360 }
        if snap15 { deg = (deg / 15).rounded() * 15 }
        else { for k in stride(from: -180.0, through: 180, by: 45) where abs(deg - k) < 2.5 { deg = k } }
        return deg
    }

    // MARK: snapping
    /// Snap the moving box (its axis-aligned bounds) against canvas edges/centre, safe area, guides and other layers.
    /// Returns the correction (dx, dy) to apply plus the guide lines to draw.
    static func snap(moving m: CGRect, others: [CGRect], canvas: CGSize, guides: [EditorGuide] = [], safeInset: Double? = nil, threshold: Double) -> SnapResult {
        var xs: [(pos: Double, span: ClosedRange<Double>)] = [(0, 0...canvas.height), (canvas.width / 2, 0...canvas.height), (canvas.width, 0...canvas.height)]
        var ys: [(pos: Double, span: ClosedRange<Double>)] = [(0, 0...canvas.width), (canvas.height / 2, 0...canvas.width), (canvas.height, 0...canvas.width)]
        if let s = safeInset {
            let ix = canvas.width * s, iy = canvas.height * s
            xs += [(ix, 0...canvas.height), (canvas.width - ix, 0...canvas.height)]
            ys += [(iy, 0...canvas.width), (canvas.height - iy, 0...canvas.width)]
        }
        for g in guides { if g.vertical { xs.append((g.position, 0...canvas.height)) } else { ys.append((g.position, 0...canvas.width)) } }
        for o in others {
            for x in [o.minX, o.midX, o.maxX] { xs.append((x, min(o.minY, m.minY)...max(o.maxY, m.maxY))) }
            for y in [o.minY, o.midY, o.maxY] { ys.append((y, min(o.minX, m.minX)...max(o.maxX, m.maxX))) }
        }
        var res = SnapResult()
        func best(_ edges: [Double], _ targets: [(pos: Double, span: ClosedRange<Double>)]) -> (delta: Double, pos: Double, span: ClosedRange<Double>)? {
            var b: (Double, Double, ClosedRange<Double>)? = nil
            for e in edges { for t in targets {
                let d = t.pos - e
                if abs(d) <= threshold, b == nil || abs(d) < abs(b!.0) - 0.0001 { b = (d, t.pos, t.span) }
            } }
            return b
        }
        let bx = best([m.minX, m.midX, m.maxX], xs)
        let by = best([m.minY, m.midY, m.maxY], ys)
        if let bx { res.dx = bx.delta }
        if let by { res.dy = by.delta }
        // gather every guide that coincides after the correction (so multiple aligned edges all light up)
        let moved = m.offsetBy(dx: res.dx, dy: res.dy)
        if bx != nil {
            for x in [moved.minX, moved.midX, moved.maxX] {
                for t in xs where abs(t.pos - x) < 0.5 {
                    let line = GuideLine(vertical: true, position: t.pos, from: min(t.span.lowerBound, moved.minY), to: max(t.span.upperBound, moved.maxY))
                    if !res.lines.contains(where: { $0.vertical && abs($0.position - t.pos) < 0.5 }) { res.lines.append(line) }
                }
            }
        }
        if by != nil {
            for y in [moved.minY, moved.midY, moved.maxY] {
                for t in ys where abs(t.pos - y) < 0.5 {
                    let line = GuideLine(vertical: false, position: t.pos, from: min(t.span.lowerBound, moved.minX), to: max(t.span.upperBound, moved.maxX))
                    if !res.lines.contains(where: { !$0.vertical && abs($0.position - t.pos) < 0.5 }) { res.lines.append(line) }
                }
            }
        }
        return res
    }

    /// Snap a single edge coordinate (used while resizing) to candidate lines.
    static func snapValue(_ v: Double, to candidates: [Double], threshold: Double) -> Double? {
        var best: Double? = nil
        for c in candidates where abs(c - v) <= threshold { if best == nil || abs(c - v) < abs(best! - v) { best = c } }
        return best
    }

    // MARK: align / distribute
    /// New rects after aligning. `bounds` = what to align to (selection bounds, or the canvas when a single layer is selected).
    static func align(_ rects: [CGRect], mode: AlignMode, to bounds: CGRect) -> [CGRect] {
        rects.map { r in
            var n = r
            switch mode {
            case .left: n.origin.x = bounds.minX
            case .centerH: n.origin.x = bounds.midX - r.width / 2
            case .right: n.origin.x = bounds.maxX - r.width
            case .top: n.origin.y = bounds.minY
            case .centerV: n.origin.y = bounds.midY - r.height / 2
            case .bottom: n.origin.y = bounds.maxY - r.height
            }
            return n
        }
    }
    /// Equalise the gaps between >= 3 rects along an axis, keeping the outermost two fixed. Output order matches input order.
    static func distribute(_ rects: [CGRect], axis: DistributeAxis) -> [CGRect] {
        guard rects.count >= 3 else { return rects }
        let idx = rects.indices.sorted { axis == .horizontal ? rects[$0].minX < rects[$1].minX : rects[$0].minY < rects[$1].minY }
        let first = rects[idx.first!], last = rects[idx.last!]
        let total = axis == .horizontal ? (last.maxX - first.minX) : (last.maxY - first.minY)
        let used = idx.reduce(0.0) { $0 + (axis == .horizontal ? rects[$1].width : rects[$1].height) }
        let gap = (total - used) / Double(rects.count - 1)
        var out = rects
        var cursor = axis == .horizontal ? first.minX : first.minY
        for i in idx {
            if axis == .horizontal { out[i].origin.x = cursor; cursor += rects[i].width + gap }
            else { out[i].origin.y = cursor; cursor += rects[i].height + gap }
        }
        return out
    }

    // MARK: view <-> canvas transform
    /// Maps between canvas px and view points for a zoomed/panned artboard. `origin` = view position of canvas (0,0).
    struct ViewMap: Equatable {
        var zoom: Double
        var origin: CGPoint
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom) }
        func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom) }
        func toView(_ r: CGRect) -> CGRect { CGRect(x: origin.x + r.minX * zoom, y: origin.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom) }
        /// Zoom about a view point, keeping the canvas point under it stationary.
        func zoomed(to z: Double, about v: CGPoint) -> ViewMap {
            let c = toCanvas(v)
            return ViewMap(zoom: z, origin: CGPoint(x: v.x - c.x * z, y: v.y - c.y * z))
        }
        /// Fit `canvas` into `view` with padding, centred.
        static func fit(canvas: CGSize, in view: CGSize, padding: Double = 40) -> ViewMap {
            let z = max(0.05, min((view.width - 2 * padding) / canvas.width, (view.height - 2 * padding) / canvas.height))
            return ViewMap(zoom: z, origin: CGPoint(x: (view.width - canvas.width * z) / 2, y: (view.height - canvas.height * z) / 2))
        }
    }
}
