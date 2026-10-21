// Slot rectangles per layout. Port of src/web/engine/layouts.ts (designed on 1280x720, scaled to the output size).
import Foundation
import CoreGraphics

struct SlotRect: Equatable {
    var rect: CGRect          // top-left origin, pixels
    var framed: Bool          // drawn with border + rounded corners
}

enum LayoutMath {
    static let designW: CGFloat = 1280
    static let designH: CGFloat = 720
    static let gap: CGFloat = 16

    static func slotCount(_ kind: LayoutKind) -> Int { designRects(kind).count }
    static func slotNames(_ kind: LayoutKind) -> [String] {
        switch kind {
        case .full: return ["Main"]
        case .side: return ["Left", "Right"]
        case .pip: return ["Main", "Inset"]
        case .desk: return ["Game", "Host"]
        case .trio: return ["Big", "Top", "Bottom"]
        }
    }

    /// Slot rects for `kind` on a `width` x `height` canvas (top-left origin).
    static func rects(for kind: LayoutKind, width: CGFloat = CGFloat(studioWidth), height: CGFloat = CGFloat(studioHeight)) -> [SlotRect] {
        let sx = width / designW, sy = height / designH
        return designRects(kind).map {
            SlotRect(rect: CGRect(x: $0.rect.minX * sx, y: $0.rect.minY * sy, width: $0.rect.width * sx, height: $0.rect.height * sy), framed: $0.framed)
        }
    }

    /// Aspect-fill: the source sub-rect (in source pixels) that covers `dst` when scaled uniformly, centred.
    static func coverCrop(srcW: CGFloat, srcH: CGFloat, dstW: CGFloat, dstH: CGFloat) -> CGRect {
        let vr = srcW / srcH, rr = dstW / dstH
        var sw = srcW, sh = srcH
        if vr > rr { sw = sh * rr } else { sh = sw / rr }
        return CGRect(x: (srcW - sw) / 2, y: (srcH - sh) / 2, width: sw, height: sh)
    }

    private static func designRects(_ kind: LayoutKind) -> [SlotRect] {
        let W = designW, H = designH, G = gap
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ f: Bool = true) -> SlotRect {
            SlotRect(rect: CGRect(x: x, y: y, width: w, height: h), framed: f)
        }
        switch kind {
        case .full: return [r(0, 0, W, H, false)]
        case .side:
            let w = W / 2 - 1.5 * G, h = w * 9 / 16, y = (H - h) / 2
            return [r(G, y, w, h), r(W / 2 + G / 2, y, w, h)]
        case .pip: return [r(0, 0, W, H, false), r(W - 360 - 24, H - 203 - 24, 360, 203)]
        case .desk: return [r(G, G, 880, 495), r(880 + 2 * G, G, W - 880 - 3 * G, 495)]
        case .trio:
            let sw = W - 840 - 3 * G, sh = (H - 3 * G) / 2
            return [r(G, G, 840, H - 2 * G), r(840 + 2 * G, G, sw, sh), r(840 + 2 * G, G + sh + G, sw, sh)]
        }
    }
}

/// Stable key per source (two slots with the same phone share one player). Phone audio is registered under this key.
func engineSourceKey(_ s: SourceRef) -> String {
    switch s {
    case .device(let id): return "device:\(id)"
    case .camera: return "camera:"
    case .prop(let id): return "prop:\(id)"
    case .slate: return "slate:"
    case .image(let id): return "image:\(id)"
    case .web(let url): return "web:\(url)"
    }
}

/// "Starting soon" slate plays the intro prop when one is picked (port of resolveScene).
func resolveScene(_ s: Scene, introPropId: String?) -> Scene {
    guard let intro = introPropId else { return s }
    var o = s
    o.slots = s.slots.map { if case .slate? = $0 { return .prop(id: intro) } else { return $0 } }
    return o
}
