// Observable editing state for one LayerScene: selection, undo/redo, clipboard, tree operations.
import Foundation
import CoreGraphics
import Observation

/// Layer-tree helpers (layers may be nested in groups; layers[0] is the bottom).
enum LayerTree {
    static func find(_ id: String, in layers: [Layer]) -> Layer? {
        for l in layers { if l.id == id { return l }; if case .group(let c) = l.kind, let f = find(id, in: c) { return f } }
        return nil
    }
    @discardableResult
    static func mutate(_ id: String, in layers: inout [Layer], _ body: (inout Layer) -> Void) -> Bool {
        for i in layers.indices {
            if layers[i].id == id { body(&layers[i]); return true }
            if case .group(var c) = layers[i].kind {
                if mutate(id, in: &c, body) { layers[i].kind = .group(c); return true }
            }
        }
        return false
    }
    /// Remove and return a layer by id.
    static func remove(_ id: String, from layers: inout [Layer]) -> Layer? {
        if let i = layers.firstIndex(where: { $0.id == id }) { return layers.remove(at: i) }
        for i in layers.indices {
            if case .group(var c) = layers[i].kind, let r = remove(id, from: &c) { layers[i].kind = .group(c); return r }
        }
        return nil
    }
    /// Id of the group containing `id` (nil = top level).
    static func parentID(of id: String, in layers: [Layer], parent: String? = nil) -> String?? {
        for l in layers {
            if l.id == id { return .some(parent) }
            if case .group(let c) = l.kind, let r = parentID(of: id, in: c, parent: l.id) { return r }
        }
        return nil
    }
    /// Offset of a group's local origin in canvas space (sum of ancestor origins).
    static func originOffset(ofParentOf id: String, in layers: [Layer]) -> CGPoint {
        var off = CGPoint.zero
        func walk(_ ls: [Layer], _ acc: CGPoint) -> Bool {
            for l in ls {
                if l.id == id { off = acc; return true }
                if case .group(let c) = l.kind, walk(c, CGPoint(x: acc.x + l.transform.x, y: acc.y + l.transform.y)) { return true }
            }
            return false
        }
        _ = walk(layers, .zero)
        return off
    }
    /// Parent group id (nil = top level) and index of a layer.
    static func location(of id: String, in layers: [Layer], parent: String? = nil) -> (parent: String?, index: Int)? {
        for (i, l) in layers.enumerated() {
            if l.id == id { return (parent, i) }
            if case .group(let c) = l.kind, let r = location(of: id, in: c, parent: l.id) { return r }
        }
        return nil
    }
    static func flatten(_ layers: [Layer]) -> [Layer] {
        layers.flatMap { l -> [Layer] in if case .group(let c) = l.kind { return [l] + flatten(c) }; return [l] }
    }
    static func insert(_ layer: Layer, into layers: inout [Layer], parent: String?, at index: Int?) {
        if let parent {
            _ = mutate(parent, in: &layers) { g in
                if case .group(var c) = g.kind { c.insert(layer, at: min(max(0, index ?? c.count), c.count)); g.kind = .group(c) }
            }
        } else { layers.insert(layer, at: min(max(0, index ?? layers.count), layers.count)) }
    }
    /// Deep copy with fresh ids.
    static func clone(_ l: Layer) -> Layer {
        var n = l; n.id = UUID().uuidString
        if case .group(let c) = l.kind { n.kind = .group(c.map(clone)) }
        n.animations = n.animations.map { var a = $0; a.id = UUID().uuidString; return a }
        return n
    }
}

@MainActor
@Observable
final class SceneEditorModel {
    var scene: LayerScene
    var selection: [String] = []
    var variables = SceneVariables.sample
    var guides: [EditorGuide] = []
    /// bumped on every scene change so views / rasteriser can cheaply notice
    private(set) var revision = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    struct Snapshot { var scene: LayerScene; var selection: [String]; var label: String }
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceTime = Date.distantPast
    @ObservationIgnored var clipboard: [Layer] = []
    @ObservationIgnored var onChange: ((LayerScene) -> Void)?
    var maxUndo = 200

    init(scene: LayerScene) { self.scene = scene }

    // MARK: undo / redo core
    /// Run an edit as one undo step. Edits sharing a `coalesce` key within 0.7 s (slider drags, arrow nudges) merge into one step.
    func edit(_ label: String, coalesce: String? = nil, _ body: (inout LayerScene) -> Void) {
        let now = Date()
        let merge = coalesce != nil && coalesce == lastCoalesceKey && now.timeIntervalSince(lastCoalesceTime) < 0.7 && !undoStack.isEmpty
        let before = scene
        var after = scene
        body(&after)
        guard after != before else { return }
        if !merge {
            undoStack.append(Snapshot(scene: before, selection: selection, label: label))
            if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        }
        redoStack.removeAll()
        lastCoalesceKey = coalesce; lastCoalesceTime = now
        scene = after
        pruneSelection(); touch()
    }
    /// Begin/end of a continuous gesture (drag): one undo step for the whole drag.
    @ObservationIgnored private var gestureBase: Snapshot?
    func beginGesture(_ label: String) { gestureBase = Snapshot(scene: scene, selection: selection, label: label) }
    func endGesture() {
        if let g = gestureBase, g.scene != scene {
            undoStack.append(g); redoStack.removeAll()
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            lastCoalesceKey = nil
        }
        gestureBase = nil
    }
    /// Live change during a gesture (no undo entry).
    func live(_ body: (inout LayerScene) -> Void) {
        var s = scene; body(&s)
        if s != scene { scene = s; touch() }
    }
    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(scene: scene, selection: selection, label: s.label))
        scene = s.scene; selection = s.selection; lastCoalesceKey = nil; pruneSelection(); touch()
    }
    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(scene: scene, selection: selection, label: s.label))
        scene = s.scene; selection = s.selection; lastCoalesceKey = nil; pruneSelection(); touch()
    }
    private func touch() { revision += 1; onChange?(scene) }
    private func pruneSelection() {
        let ids = Set(LayerTree.flatten(scene.layers).map(\.id))
        let p = selection.filter { ids.contains($0) }
        if p != selection { selection = p }
    }

    // MARK: lookup
    func layer(_ id: String) -> Layer? { LayerTree.find(id, in: scene.layers) }
    var selectedLayers: [Layer] { selection.compactMap(layer) }
    var primary: Layer? { selection.last.flatMap(layer) }
    func isSelected(_ id: String) -> Bool { selection.contains(id) }
    /// Rect of a layer in canvas space (adds ancestor group origins).
    func canvasRect(_ id: String) -> CGRect? {
        guard let l = layer(id) else { return nil }
        let o = LayerTree.originOffset(ofParentOf: id, in: scene.layers)
        return l.transform.rect.offsetBy(dx: o.x, dy: o.y)
    }
    var canvasSize: CGSize { CGSize(width: scene.canvas.w, height: scene.canvas.h) }

    // MARK: selection
    func select(_ id: String?, extend: Bool = false) {
        guard let id else { if !extend { selection = [] }; return }
        if extend { if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) } }
        else { selection = [id] }
    }
    func selectAll() { selection = scene.layers.filter { !$0.locked && $0.visible }.map(\.id) }
    func selectRect(_ r: CGRect, extend: Bool) {
        var hit: [String] = []
        for l in scene.layers where l.visible && !l.locked {
            let bb = EditorMath.boundingBox(l.transform.rect, rotation: l.transform.rotation)
            if bb.intersects(r) { hit.append(l.id) }
        }
        selection = extend ? Array(Set(selection + hit)) : hit
    }

    // MARK: hit testing
    /// Topmost visible, unlocked top-level layer under a canvas point.
    func hitTest(_ p: CGPoint) -> String? {
        for l in scene.layers.reversed() where l.visible && !l.locked {
            if EditorMath.contains(p, rect: l.transform.rect, rotation: l.transform.rotation) {
                // ignore fully transparent effect layers covering everything unless nothing else is hit
                if case .effect = l.kind, l.transform.w >= Double(scene.canvas.w) - 1 && l.transform.h >= Double(scene.canvas.h) - 1 { continue }
                return l.id
            }
        }
        return nil
    }

    // MARK: layer edits
    func update(_ id: String, _ label: String, coalesce: String? = nil, _ body: @escaping (inout Layer) -> Void) {
        edit(label, coalesce: coalesce.map { "\($0):\(id)" }) { s in LayerTree.mutate(id, in: &s.layers, body) }
    }
    func updateSelected(_ label: String, coalesce: String? = nil, _ body: @escaping (inout Layer) -> Void) {
        let ids = selection
        edit(label, coalesce: coalesce.map { "\($0):\(ids.joined())" }) { s in for id in ids { LayerTree.mutate(id, in: &s.layers, body) } }
    }
    @discardableResult
    func add(_ layer: Layer, label: String = "Add layer", select: Bool = true) -> String {
        var l = layer
        if LayerTree.find(l.id, in: scene.layers) != nil { l.id = UUID().uuidString }
        edit(label) { $0.layers.append(l) }
        if select { selection = [l.id] }
        return l.id
    }
    /// Add centred at a canvas point (used by drag & drop from the library).
    @discardableResult
    func add(_ layer: Layer, centeredAt p: CGPoint, label: String = "Add layer") -> String {
        var l = layer
        l.transform.x = p.x - l.transform.w / 2; l.transform.y = p.y - l.transform.h / 2
        return add(l, label: label)
    }
    func deleteSelected() {
        let ids = Set(selection)
        guard !ids.isEmpty else { return }
        edit(ids.count > 1 ? "Delete layers" : "Delete layer") { s in for id in ids { _ = LayerTree.remove(id, from: &s.layers) } }
        selection = []
    }
    func duplicateSelected(offset: Double = 24) {
        guard !selection.isEmpty else { return }
        var newIDs: [String] = []
        edit("Duplicate") { s in
            for id in selection {
                guard let src = LayerTree.find(id, in: s.layers) else { continue }
                var c = LayerTree.clone(src); c.name = src.name + " copy"
                c.transform.x += offset; c.transform.y += offset
                newIDs.append(c.id)
                if let pid = LayerTree.parentID(of: id, in: s.layers), let parent = pid {
                    LayerTree.insert(c, into: &s.layers, parent: parent, at: nil)
                } else {
                    let idx = s.layers.firstIndex { $0.id == id }.map { $0 + 1 }
                    LayerTree.insert(c, into: &s.layers, parent: nil, at: idx)
                }
            }
        }
        selection = newIDs
    }
    func copy() { clipboard = selectedLayers }
    func cut() { copy(); deleteSelected() }
    func paste() {
        guard !clipboard.isEmpty else { return }
        var ids: [String] = []
        edit("Paste") { s in
            for l in clipboard { var c = LayerTree.clone(l); c.transform.x += 24; c.transform.y += 24; ids.append(c.id); s.layers.append(c) }
        }
        selection = ids
        clipboard = clipboard.map { var c = $0; c.transform.x += 24; c.transform.y += 24; return c }   // successive pastes cascade
    }
    func group() {
        let top = scene.layers.filter { selection.contains($0.id) }
        guard top.count >= 1 else { return }
        let bounds = EditorMath.union(top.map { EditorMath.boundingBox($0.transform.rect, rotation: $0.transform.rotation) })
        var gid = ""
        edit("Group") { s in
            let idxs = s.layers.indices.filter { selection.contains(s.layers[$0].id) }
            guard let at = idxs.last else { return }
            var kids = idxs.map { s.layers[$0] }
            for i in kids.indices { kids[i].transform.x -= bounds.minX; kids[i].transform.y -= bounds.minY }
            var g = Layer.group("Group", kids, x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height)
            g.name = "Group \(LayerTree.flatten(s.layers).filter { $0.kind.typeName == "group" }.count + 1)"
            gid = g.id
            let removed = idxs.count
            for i in idxs.reversed() { s.layers.remove(at: i) }
            s.layers.insert(g, at: max(0, min(s.layers.count, at - removed + 1)))
        }
        if !gid.isEmpty { selection = [gid] }
    }
    func ungroup() {
        var out: [String] = []
        edit("Ungroup") { s in
            for id in selection {
                guard let i = s.layers.firstIndex(where: { $0.id == id }), case .group(let kids) = s.layers[i].kind else { continue }
                let g = s.layers[i]
                var moved = kids
                for k in moved.indices { moved[k].transform.x += g.transform.x; moved[k].transform.y += g.transform.y; moved[k].opacity *= g.opacity }
                out += moved.map(\.id)
                s.layers.replaceSubrange(i...i, with: moved)
            }
        }
        if !out.isEmpty { selection = out }
    }

    // MARK: z-order
    enum Order { case front, back, forward, backward }
    func reorder(_ o: Order) {
        guard !selection.isEmpty else { return }
        edit("Arrange") { s in
            var arr = s.layers
            let ids = selection
            switch o {
            case .front: let moved = arr.filter { ids.contains($0.id) }; arr.removeAll { ids.contains($0.id) }; arr += moved
            case .back: let moved = arr.filter { ids.contains($0.id) }; arr.removeAll { ids.contains($0.id) }; arr = moved + arr
            case .forward:
                for i in stride(from: arr.count - 2, through: 0, by: -1) where ids.contains(arr[i].id) && !ids.contains(arr[i + 1].id) { arr.swapAt(i, i + 1) }
            case .backward:
                for i in 1..<max(1, arr.count) where ids.contains(arr[i].id) && !ids.contains(arr[i - 1].id) { arr.swapAt(i, i - 1) }
            }
            s.layers = arr
        }
    }
    /// Drag-reorder: place `id` into `parent` (nil = top) at `index` (bottom-up index in that array).
    func move(_ id: String, toParent parent: String?, at index: Int) {
        edit("Reorder layers") { s in
            guard parent != id, let l = LayerTree.remove(id, from: &s.layers) else { return }
            LayerTree.insert(l, into: &s.layers, parent: parent, at: index)
        }
    }

    enum DropPosition { case above, below, into }
    /// Move `id` relative to `target` (above = higher z-order). Returns false when the move is invalid (into itself / its own child).
    @discardableResult
    func move(_ id: String, relativeTo target: String, _ pos: DropPosition) -> Bool {
        guard id != target, let moving = layer(id) else { return false }
        if case .group(let kids) = moving.kind, LayerTree.find(target, in: kids) != nil { return false }
        edit("Reorder layers") { s in
            let oldOff = LayerTree.originOffset(ofParentOf: id, in: s.layers)
            guard let l = LayerTree.remove(id, from: &s.layers) else { return }
            defer {
                let newOff = LayerTree.originOffset(ofParentOf: id, in: s.layers)
                if newOff != oldOff { LayerTree.mutate(id, in: &s.layers) { $0.transform.x += oldOff.x - newOff.x; $0.transform.y += oldOff.y - newOff.y } }
            }
            switch pos {
            case .into:
                if let t = LayerTree.find(target, in: s.layers), case .group = t.kind { LayerTree.insert(l, into: &s.layers, parent: target, at: nil) }
                else { s.layers.append(l) }
            case .above, .below:
                guard let loc = LayerTree.location(of: target, in: s.layers) else { s.layers.append(l); return }
                LayerTree.insert(l, into: &s.layers, parent: loc.parent, at: pos == .above ? loc.index + 1 : loc.index)
            }
        }
        return true
    }

    // MARK: transform
    func setRect(_ id: String, _ r: CGRect, label: String = "Transform", coalesce: String? = "xform") {
        update(id, label, coalesce: coalesce) { $0.transform.x = r.minX; $0.transform.y = r.minY; $0.transform.w = r.width; $0.transform.h = r.height }
    }
    func nudge(dx: Double, dy: Double) {
        guard !selection.isEmpty else { return }
        updateSelected("Nudge", coalesce: "nudge") { $0.transform.x += dx; $0.transform.y += dy }
    }
    func flip(horizontal: Bool) {
        updateSelected(horizontal ? "Flip horizontal" : "Flip vertical") { if horizontal { $0.transform.flipX.toggle() } else { $0.transform.flipY.toggle() } }
    }
    func rotate90(clockwise: Bool = true) {
        updateSelected("Rotate 90") { var r = $0.transform.rotation + (clockwise ? 90 : -90); r = r.truncatingRemainder(dividingBy: 360); if r > 180 { r -= 360 }; if r <= -180 { r += 360 }; $0.transform.rotation = r }
    }
    func toggleLock(_ id: String) { update(id, "Lock") { $0.locked.toggle() } }
    func toggleVisible(_ id: String) { update(id, "Visibility") { $0.visible.toggle() } }
    func rename(_ id: String, _ name: String) { update(id, "Rename") { $0.name = name } }

    func align(_ mode: AlignMode) {
        let top = scene.layers.filter { selection.contains($0.id) }
        guard !top.isEmpty else { return }
        let cs = canvasSize
        let bounds: CGRect = top.count == 1 ? CGRect(origin: .zero, size: cs)
            : EditorMath.union(top.map { EditorMath.boundingBox($0.transform.rect, rotation: $0.transform.rotation) })
        edit("Align") { s in
            for id in selection {
                LayerTree.mutate(id, in: &s.layers) { l in
                    let bb = EditorMath.boundingBox(l.transform.rect, rotation: l.transform.rotation)
                    let moved = EditorMath.align([bb], mode: mode, to: bounds)[0]
                    l.transform.x += moved.minX - bb.minX; l.transform.y += moved.minY - bb.minY
                }
            }
        }
    }
    func distribute(_ axis: DistributeAxis) {
        let top = scene.layers.filter { selection.contains($0.id) }
        guard top.count >= 3 else { return }
        let bbs = top.map { EditorMath.boundingBox($0.transform.rect, rotation: $0.transform.rotation) }
        let out = EditorMath.distribute(bbs, axis: axis)
        edit("Distribute") { s in
            for (i, l) in top.enumerated() {
                LayerTree.mutate(l.id, in: &s.layers) { $0.transform.x += out[i].minX - bbs[i].minX; $0.transform.y += out[i].minY - bbs[i].minY }
            }
        }
    }
    /// Scale the selection to cover/fit the whole canvas.
    func fillCanvas() {
        updateSelected("Fill canvas") { $0.transform.x = 0; $0.transform.y = 0; $0.transform.w = Double(self.scene.canvas.w); $0.transform.h = Double(self.scene.canvas.h); $0.transform.rotation = 0 }
    }

    // MARK: scene-level
    func setBackground(_ b: Background) { edit("Background") { $0.background = b } }
    func replaceScene(_ s: LayerScene, label: String = "Apply template") {
        edit(label) { $0 = s }
        selection = []
    }
    func addGuide(vertical: Bool, at pos: Double) { guides.append(EditorGuide(vertical: vertical, position: pos)) }
}
