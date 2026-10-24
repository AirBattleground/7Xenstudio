// Old fixed-layout Scene -> LayerScene. The result renders (nearly) identically: same slot geometry, rounded + teal border on framed slots,
// the same backdrop, slate / empty-slot art. Layer ids are stable ("<sceneId>#slotN") so repeated migration is idempotent.
import Foundation
import CoreGraphics

extension LayerScene {
    static let oldSlotCornerRadius = 12.0 * 1.5       // 12 design units at 1920/1280
    static let oldSlotBorder = 1.5 * 1.5
    static let oldAccent: UInt32 = 0x2DD4C4

    /// Convert an old scene. `slotNames` come from the layout ("Main", "Left", ...).
    static func migrate(_ s: Scene) -> LayerScene {
        let W = CGFloat(studioWidth), H = CGFloat(studioHeight)
        let rects = LayoutMath.rects(for: s.layout, width: W, height: H)
        let framed = rects.contains { $0.framed }
        var scene = LayerScene(id: s.id, name: s.name)
        scene.migratedFrom = s.id
        if framed {
            scene.background = .linear(Gradient.linear(RGBA(hex: 0x0B1A1D), RGBA(hex: 0x05080A), angle: Double(atan2(H, W)) * 180 / .pi))
        } else { scene.background = .solid(RGBA(hex: 0x06090C)) }
        let names = LayoutMath.slotNames(s.layout)
        for (i, sr) in rects.enumerated() {
            let r = CGRect(x: sr.rect.minX.rounded(), y: sr.rect.minY.rounded(), width: sr.rect.width.rounded(), height: sr.rect.height.rounded())
            let tf = Transform(x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
            let name = i < names.count ? names[i] : "Slot \(i + 1)"
            let rad = sr.framed ? oldSlotCornerRadius : 0
            let border = sr.framed ? Border(width: oldSlotBorder, color: RGBA(hex: oldAccent, alpha: 0.55)) : Border()
            let ref: SourceRef? = i < s.slots.count ? s.slots[i] : nil
            let lid = "\(s.id)#slot\(i)"
            guard let ref = ref else {
                var bg = Layer(id: lid, name: "\(name) (empty)", kind: .shape(ShapeSpec(.rect, fill: Fill(RGBA(hex: 0x11181C)))), transform: tf)
                bg.cornerRadius = rad; bg.border = border
                scene.layers.append(bg)
                var st = TextStyle("Empty slot", size: Double(max(14, (r.height * 0.045).rounded())), weight: 700, color: RGBA(1, 1, 1, 0.55))
                st.alignment = .center
                scene.layers.append(Layer(id: lid + "-label", name: "\(name) label", kind: .text(st), transform: tf))
                continue
            }
            var fit: SourceFit = s.fit(i) ? .fit : .fill
            if case .image = ref { fit = .fit }
            var l = Layer(id: lid, name: name, kind: .source(ref, fit: fit), transform: tf)
            l.cornerRadius = rad; l.border = border
            scene.layers.append(l)
        }
        return scene
    }
}
