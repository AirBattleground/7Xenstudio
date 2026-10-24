import Testing
import Foundation
import CoreGraphics
@testable import Studio

private func rect(_ n: String = "L", _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Layer {
    Layer.rect(n, x: x, y: y, w: w, h: h)
}

@Suite struct SceneBuilderMathTests {
    @Test func rotatedBoundingBox() {
        let bb = EditorMath.boundingBox(CGRect(x: 0, y: 0, width: 100, height: 50), rotation: 90)
        #expect(abs(bb.width - 50) < 0.001 && abs(bb.height - 100) < 0.001)
        #expect(abs(bb.midX - 50) < 0.001 && abs(bb.midY - 25) < 0.001)
    }
    @Test func handlePositionsAndHit() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let br = EditorMath.handlePoint(.bottomRight, rect: r, rotation: 0)
        #expect(br == CGPoint(x: 300, y: 200))
        #expect(EditorMath.hitHandle(CGPoint(x: 302, y: 199), rect: r, rotation: 0, radius: 6) == .bottomRight)
        #expect(EditorMath.hitHandle(CGPoint(x: 200, y: 150), rect: r, rotation: 0, radius: 6) == nil)
        let knob = EditorMath.handlePoint(.rotate, rect: r, rotation: 0, rotateOffset: 28)
        #expect(knob == CGPoint(x: 200, y: 72))
        #expect(EditorMath.hitHandle(knob, rect: r, rotation: 0, radius: 6) == .rotate)
        // rotated 90: top-centre moves to the right of the box
        let top = EditorMath.handlePoint(.top, rect: r, rotation: 90)
        #expect(abs(top.x - 250) < 0.001 && abs(top.y - 150) < 0.001)
    }
    @Test func resizeCornerAndEdge() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let a = EditorMath.resize(rect: r, rotation: 0, handle: .bottomRight, to: CGPoint(x: 400, y: 260))
        #expect(a == CGRect(x: 100, y: 100, width: 300, height: 160))
        let b = EditorMath.resize(rect: r, rotation: 0, handle: .left, to: CGPoint(x: 50, y: 999))
        #expect(b == CGRect(x: 50, y: 100, width: 250, height: 100))
        let c = EditorMath.resize(rect: r, rotation: 0, handle: .topLeft, to: CGPoint(x: 150, y: 120), fromCenter: true)
        #expect(c == CGRect(x: 150, y: 120, width: 100, height: 60))
    }
    @Test func resizeKeepsAspect() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 100)
        let a = EditorMath.resize(rect: r, rotation: 0, handle: .bottomRight, to: CGPoint(x: 400, y: 120), keepAspect: true)
        #expect(abs(a.width / a.height - 2) < 0.001)
        #expect(a.minX == 0 && a.minY == 0)
    }
    @Test func resizeRotatedKeepsOppositeCornerFixed() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let rot = 30.0
        let before = EditorMath.corners(r, rotation: rot)
        let target = EditorMath.handlePoint(.bottomRight, rect: r, rotation: rot)
        let moved = CGPoint(x: target.x + 20, y: target.y + 10)
        let nr = EditorMath.resize(rect: r, rotation: rot, handle: .bottomRight, to: moved)
        let after = EditorMath.corners(nr, rotation: rot)
        #expect(hypot(before[0].x - after[0].x, before[0].y - after[0].y) < 0.001)       // top-left stays put
        #expect(hypot(after[2].x - moved.x, after[2].y - moved.y) < 0.001)               // dragged corner follows the pointer
    }
    @Test func rotationAngleSnaps() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(abs(EditorMath.rotation(rect: r, to: CGPoint(x: 50, y: -100), snap15: false)) < 0.001)
        #expect(abs(EditorMath.rotation(rect: r, to: CGPoint(x: 200, y: 50), snap15: false) - 90) < 0.001)
        let free = EditorMath.rotation(rect: r, to: CGPoint(x: 120, y: -40), snap15: true)
        #expect(free.truncatingRemainder(dividingBy: 15) == 0)
    }
    @Test func snapToCanvasEdgeAndCentre() {
        let canvas = CGSize(width: 1920, height: 1080)
        let m = CGRect(x: 3, y: 500, width: 200, height: 100)
        let s = EditorMath.snap(moving: m, others: [], canvas: canvas, threshold: 6)
        #expect(s.dx == -3)
        #expect(s.lines.contains { $0.vertical && $0.position == 0 })
        let c = CGRect(x: 860, y: 400, width: 200, height: 100)      // centre x = 960
        #expect(EditorMath.snap(moving: c, others: [], canvas: canvas, threshold: 6).dx == 0)
        let c2 = CGRect(x: 864, y: 300, width: 200, height: 100)
        let s2 = EditorMath.snap(moving: c2, others: [], canvas: canvas, threshold: 6)
        #expect(s2.dx == -4)
    }
    @Test func snapToOtherLayerAndNoSnapOutsideThreshold() {
        let canvas = CGSize(width: 1920, height: 1080)
        let other = CGRect(x: 500, y: 300, width: 300, height: 200)
        let m = CGRect(x: 810, y: 600, width: 100, height: 100)   // left edge 10 px right of other.maxX (800)
        #expect(EditorMath.snap(moving: m, others: [other], canvas: canvas, threshold: 6).dx == 0)
        let m2 = CGRect(x: 804, y: 303, width: 100, height: 100)
        let s = EditorMath.snap(moving: m2, others: [other], canvas: canvas, threshold: 6)
        #expect(s.dx == -4 && s.dy == -3)
    }
    @Test func snapToGuide() {
        let g = EditorGuide(vertical: true, position: 400)
        let s = EditorMath.snap(moving: CGRect(x: 397, y: 10, width: 50, height: 50), others: [], canvas: CGSize(width: 1920, height: 1080), guides: [g], threshold: 6)
        #expect(s.dx == 3)
    }
    @Test func alignModes() {
        let rs = [CGRect(x: 10, y: 10, width: 100, height: 50), CGRect(x: 200, y: 80, width: 40, height: 20)]
        let bounds = EditorMath.union(rs)
        #expect(EditorMath.align(rs, mode: .left, to: bounds).map(\.minX) == [10, 10])
        #expect(EditorMath.align(rs, mode: .right, to: bounds).map(\.maxX) == [240, 240])
        #expect(EditorMath.align(rs, mode: .centerV, to: bounds).map(\.midY) == [bounds.midY, bounds.midY])
        #expect(EditorMath.align(rs, mode: .bottom, to: bounds).map(\.maxY) == [100, 100])
    }
    @Test func distributeEqualisesGaps() {
        let rs = [CGRect(x: 0, y: 0, width: 100, height: 10), CGRect(x: 120, y: 0, width: 50, height: 10), CGRect(x: 400, y: 0, width: 100, height: 10)]
        let out = EditorMath.distribute(rs, axis: .horizontal)
        let gap1 = out[1].minX - out[0].maxX, gap2 = out[2].minX - out[1].maxX
        #expect(abs(gap1 - gap2) < 0.001)
        #expect(out[0].minX == 0 && out[2].maxX == 500)
        // input order is preserved even when the array is not sorted
        let shuffled = [rs[2], rs[0], rs[1]]
        let o2 = EditorMath.distribute(shuffled, axis: .horizontal)
        #expect(o2[0].minX > o2[2].minX)
    }
    @Test func viewMapRoundTripAndZoomAboutPoint() {
        let m = EditorMath.ViewMap(zoom: 0.5, origin: CGPoint(x: 40, y: 30))
        let p = CGPoint(x: 800, y: 400)
        let back = m.toCanvas(m.toView(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        let anchor = CGPoint(x: 300, y: 200)
        let before = m.toCanvas(anchor)
        let z = m.zoomed(to: 2, about: anchor)
        let after = z.toCanvas(anchor)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        let fit = EditorMath.ViewMap.fit(canvas: CGSize(width: 1920, height: 1080), in: CGSize(width: 1000, height: 700), padding: 20)
        #expect(abs(fit.zoom - 960.0 / 1920) < 1e-9)
    }
}

@MainActor
@Suite struct SceneBuilderModelTests {
    func makeModel() -> SceneEditorModel {
        var s = LayerScene(name: "T")
        s.layers = [rect("A", 0, 0, 100, 100), rect("B", 200, 0, 100, 100), rect("C", 400, 0, 100, 100)]
        return SceneEditorModel(scene: s)
    }
    @Test func undoRedoEveryEdit() {
        let m = makeModel()
        let original = m.scene
        let id = m.scene.layers[0].id
        m.setRect(id, CGRect(x: 50, y: 50, width: 80, height: 80), coalesce: nil)
        m.select(id); m.duplicateSelected()
        #expect(m.scene.layers.count == 4)
        m.deleteSelected()
        #expect(m.scene.layers.count == 3)
        m.undo(); #expect(m.scene.layers.count == 4)
        m.undo(); #expect(m.scene.layers.count == 3)
        m.undo(); #expect(m.scene == original)
        #expect(!m.canUndo)
        m.redo(); m.redo(); m.redo()
        #expect(m.scene.layers.count == 3 && m.scene.layers[0].transform.x == 50)
        #expect(!m.canRedo)
    }
    @Test func newEditClearsRedo() {
        let m = makeModel()
        let id = m.scene.layers[0].id
        m.update(id, "A") { $0.opacity = 0.5 }
        m.undo(); #expect(m.canRedo)
        m.update(id, "B") { $0.opacity = 0.2 }
        #expect(!m.canRedo)
    }
    @Test func coalescedEditsAreOneStep() {
        let m = makeModel()
        let id = m.scene.layers[0].id
        for i in 1...10 { m.update(id, "Opacity", coalesce: "op") { $0.opacity = 1 - Double(i) / 20 } }
        m.undo()
        #expect(m.scene.layers[0].opacity == 1)
        #expect(!m.canUndo)
    }
    @Test func gestureIsOneUndoStep() {
        let m = makeModel()
        let id = m.scene.layers[0].id
        m.beginGesture("Move")
        for i in 1...20 { m.live { s in LayerTree.mutate(id, in: &s.layers) { $0.transform.x = Double(i) } } }
        m.endGesture()
        #expect(m.scene.layers[0].transform.x == 20)
        m.undo()
        #expect(m.scene.layers[0].transform.x == 0)
    }
    @Test func groupAndUngroupPreserveCanvasPosition() {
        let m = makeModel()
        m.selection = [m.scene.layers[0].id, m.scene.layers[1].id]
        m.group()
        #expect(m.scene.layers.count == 2)
        guard case .group(let kids) = m.scene.layers[0].kind else { Issue.record("not a group"); return }
        #expect(kids.count == 2)
        let gid = m.scene.layers[0].id
        #expect(m.scene.layers[0].transform.x == 0 && m.scene.layers[0].transform.w == 300)
        #expect(m.canvasRect(kids[1].id) == CGRect(x: 200, y: 0, width: 100, height: 100))
        m.selection = [gid]
        m.ungroup()
        #expect(m.scene.layers.count == 3)
        #expect(m.scene.layers.map(\.transform.x).sorted() == [0, 200, 400])
        m.undo(); m.undo()
        #expect(m.scene.layers.count == 3)
    }
    @Test func duplicateDeleteCopyPaste() {
        let m = makeModel()
        m.select(m.scene.layers[1].id)
        m.duplicateSelected()
        #expect(m.scene.layers.count == 4 && m.selection.count == 1 && m.selection[0] != m.scene.layers[1].id)
        #expect(m.scene.layers[2].transform.x == 224)            // offset 24, inserted above the original
        m.copy(); m.paste()
        #expect(m.scene.layers.count == 5)
        m.deleteSelected()
        #expect(m.scene.layers.count == 4)
        let ids = m.scene.layers.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
    @Test func reorder() {
        let m = makeModel()
        let a = m.scene.layers[0].id
        m.select(a); m.reorder(.front)
        #expect(m.scene.layers.last?.id == a)
        m.reorder(.back)
        #expect(m.scene.layers.first?.id == a)
        m.reorder(.forward)
        #expect(m.scene.layers[1].id == a)
        m.reorder(.backward)
        #expect(m.scene.layers[0].id == a)
    }
    @Test func dragReorderIntoGroupAndOut() {
        let m = makeModel()
        m.selection = [m.scene.layers[1].id, m.scene.layers[2].id]; m.group()
        let gid = m.scene.layers.last!.id
        let a = m.scene.layers[0].id
        #expect(m.move(a, relativeTo: gid, .into))
        guard case .group(let kids) = m.layer(gid)!.kind else { Issue.record("no group"); return }
        #expect(kids.count == 3)
        // moving a group into itself is refused
        #expect(!m.move(gid, relativeTo: kids[0].id, .above))
        // move out: canvas position is preserved
        let before = m.canvasRect(a)!
        #expect(m.move(a, relativeTo: gid, .above))
        #expect(m.scene.layers.contains { $0.id == a })
        #expect(m.canvasRect(a) == before)
    }
    @Test func alignAndDistributeOnModel() {
        let m = makeModel()
        m.selection = m.scene.layers.map(\.id)
        m.align(.top)
        #expect(m.scene.layers.allSatisfy { $0.transform.y == 0 })
        m.update(m.scene.layers[1].id, "move") { $0.transform.x = 120 }
        m.distribute(.horizontal)
        let xs = m.scene.layers.map(\.transform.x)
        #expect(xs == [0, 200, 400])
        // single layer aligns to the canvas
        m.select(m.scene.layers[0].id)
        m.align(.right)
        #expect(m.scene.layers[0].transform.x == 1820)
        m.align(.centerV)
        #expect(m.scene.layers[0].transform.y == 490)
    }
    @Test func nudgeFlipRotate() {
        let m = makeModel()
        m.select(m.scene.layers[0].id)
        m.nudge(dx: 10, dy: -1); m.nudge(dx: 10, dy: -1)
        #expect(m.scene.layers[0].transform.x == 20 && m.scene.layers[0].transform.y == -2)
        m.undo()                      // coalesced into one step
        #expect(m.scene.layers[0].transform.x == 0)
        m.flip(horizontal: true); #expect(m.scene.layers[0].transform.flipX)
        m.rotate90(); m.rotate90(); m.rotate90()
        #expect(m.scene.layers[0].transform.rotation == -90 || m.scene.layers[0].transform.rotation == 270 - 360)
    }
    @Test func hitTestingTopmostRotatedLockedHidden() {
        let m = makeModel()
        // overlap: C drawn over A at the same spot
        m.edit("setup") { s in s.layers[2].transform.x = 0; s.layers[1].transform.x = 500 }
        #expect(m.hitTest(CGPoint(x: 50, y: 50)) == m.scene.layers[2].id)
        m.toggleLock(m.scene.layers[2].id)
        #expect(m.hitTest(CGPoint(x: 50, y: 50)) == m.scene.layers[0].id)
        m.toggleVisible(m.scene.layers[0].id)
        #expect(m.hitTest(CGPoint(x: 50, y: 50)) == nil)
        #expect(m.hitTest(CGPoint(x: 900, y: 900)) == nil)
        // rotated 45: the box corner no longer hits, the diamond tip does
        m.edit("rot") { s in s.layers[1].transform = Transform(x: 500, y: 500, w: 100, h: 100, rotation: 45) }
        #expect(m.hitTest(CGPoint(x: 503, y: 503)) == nil)
        #expect(m.hitTest(CGPoint(x: 550, y: 480)) == m.scene.layers[1].id)
    }
    @Test func marqueeSelection() {
        let m = makeModel()
        m.selectRect(CGRect(x: 150, y: -10, width: 400, height: 50), extend: false)
        #expect(Set(m.selection) == Set([m.scene.layers[1].id, m.scene.layers[2].id]))
        m.selectRect(CGRect(x: 0, y: 0, width: 20, height: 20), extend: true)
        #expect(m.selection.count == 3)
    }
    @Test func fullScreenEffectLayersDoNotStealClicks() {
        var s = LayerScene(name: "T")
        s.layers = [rect("Base", 0, 0, 500, 500), Layer.effect("Vig", EffectSpec(.vignette))]
        let m = SceneEditorModel(scene: s)
        #expect(m.hitTest(CGPoint(x: 100, y: 100)) == s.layers[0].id)
    }
    @Test func sceneCodableRoundTripAfterEdits() throws {
        let m = makeModel()
        m.selection = [m.scene.layers[0].id, m.scene.layers[1].id]; m.group()
        m.edit("vars") { $0.variableDefaults["team1"] = "ALPHA" }
        let data = try JSONEncoder().encode(m.scene)
        let back = try JSONDecoder().decode(LayerScene.self, from: data)
        #expect(back == m.scene)
    }
    @Test func repositoryPersistsScenesAndTemplates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-repo-\(UUID().uuidString)")
        let repo = LayerSceneRepository(dir: dir)
        var s = LayerScene(name: "Saved"); s.layers = [rect("A", 1, 2, 3, 4)]
        repo.save(s)
        #expect(repo.load(s.id) == s)
        repo.delete(s.id)
        #expect(repo.load(s.id) == nil)
        repo.saveTemplate(s)
        #expect(repo.myTemplates().count == 1 && repo.myTemplates()[0].name == "Saved")
    }
    @Test func abgTeamSplit() {
        #expect(SceneEditorEnvironment.splitTeams("Alpha vs Bravo").0 == "Alpha")
        #expect(SceneEditorEnvironment.splitTeams("Alpha vs Bravo").1 == "Bravo")
        #expect(SceneEditorEnvironment.splitTeams("Round 3").0 == nil)
    }
}

@Suite struct SceneBuilderRasterizerTests {
    @Test func rendersLayersToPixels() throws {
        var s = LayerScene(name: "R", background: .solid(RGBA(0, 0, 0)))
        s.layers = [Layer.rect("Red", x: 0, y: 0, w: 960, h: 1080, fill: Fill(RGBA(1, 0, 0)))]
        let img = try #require(SceneRasterizer.render(s, width: 192))
        #expect(img.width == 192 && img.height == 108)
        func px(_ x: Int, _ y: Int) -> [UInt8] {
            let d = img.dataProvider!.data! as Data
            let o = y * img.bytesPerRow + x * 4
            return [d[o + 2], d[o + 1], d[o]]      // r g b (BGRA)
        }
        #expect(px(20, 50)[0] > 200 && px(20, 50)[1] < 30)       // left half red
        #expect(px(150, 50)[0] < 30)                             // right half background
    }
    @Test func textVariablesResolve() throws {
        var s = LayerScene(name: "R", background: .solid(RGBA(0, 0, 0)))
        s.layers = [Layer.text("T", "{{team1}}", x: 0, y: 400, w: 1920, h: 200)]
        var env = RasterEnv(); env.variables = SceneVariables(["team1": "ALPHA"])
        let a = try #require(SceneRasterizer.render(s, width: 480, env: env))
        env.variables = SceneVariables(["team1": ""])
        let b = try #require(SceneRasterizer.render(s, width: 480, env: env))
        #expect((a.dataProvider!.data! as Data) != (b.dataProvider!.data! as Data))
    }
}

@Suite struct SceneBuilderDump {
    @Test func dumpText() throws {
        var s = LayerScene(name: "R", background: .solid(RGBA(0.1, 0.1, 0.2)))
        var st = TextStyle("{{team1}} VS", size: 120, weight: 800)
        st.stroke = Stroke(width: 4, color: RGBA(1, 0.4, 0)); st.shadow = Shadow(color: RGBA(0, 0, 0, 0.8), blur: 12, dx: 0, dy: 6)
        st.gradient = Gradient.linear(RGBA(1, 0.9, 0.3), RGBA(1, 0.3, 0.1))
        s.layers = [Layer.text("T", "{{team1}} VS", x: 0, y: 300, w: 1920, h: 300, style: st)]
        var env = RasterEnv(); env.variables = SceneVariables(["team1": "ALPHA"])
        let img = try #require(SceneRasterizer.render(s, width: 960, env: env))
        BuiltinAssets.writePNG(img, to: URL(fileURLWithPath: "/tmp/sb-shots/text.png"))
    }
}
