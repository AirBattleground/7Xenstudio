import Testing
import Metal
import Foundation
import CoreVideo
import CoreGraphics
@testable import Studio

// MARK: helpers

private func sceneComp() -> MetalCompositor? {
    guard let c = MetalCompositor() else { return nil }
    c.layers.sprites.sync = true
    return c
}
private func solid(_ hex: UInt32) -> Fill { Fill(RGBA(hex: hex)) }
private func lscene(_ layers: [Layer], bg: UInt32 = 0x000000) -> LayerScene {
    LayerScene(id: "t", name: "t", background: .solid(RGBA(hex: bg)), layers: layers)
}
private func rend(_ c: MetalCompositor, _ s: LayerScene, time: Double = 0, vars: SceneVariables = SceneVariables(), clock: AnimClock? = nil) -> CVPixelBuffer {
    var r = FrameRequest(); r.layerProgram = s; r.time = time; r.variables = vars; r.programClock = clock
    return renderSync(c, r)
}
private func px(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) { pixel(pb, x, y) }
private func lum(_ p: (r: Int, g: Int, b: Int)) -> Int { p.r + p.g + p.b }
private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: UInt32, _ edit: ((inout Layer) -> Void)? = nil) -> Layer {
    var l = Layer.rect("r", x: x, y: y, w: w, h: h, fill: solid(hex)); edit?(&l); return l
}

// MARK: model

@Suite struct SceneModelTests {
    @Test func lenientDecodeOfEmptyAndPartialJSON() throws {
        let d = JSONDecoder()
        let s = try d.decode(LayerScene.self, from: Data("{}".utf8))
        #expect(s.canvas.w == 1920 && s.layers.isEmpty)
        let l = try d.decode(Layer.self, from: Data(#"{"name":"A","opacity":0.5,"kind":{"type":"text","text":{"string":"Hi","size":40}},"future":{"x":1}}"#.utf8))
        #expect(l.name == "A" && l.opacity == 0.5)
        if case .text(let t) = l.kind { #expect(t.string == "Hi" && t.size == 40 && t.weight == 700) } else { Issue.record("not text") }
        // garbage in a field falls back to the default instead of failing the whole scene
        let g = try d.decode(Layer.self, from: Data(#"{"opacity":"bad","blend":"nope","transform":{"x":5}}"#.utf8))
        #expect(g.opacity == 1 && g.blend == .normal && g.transform.x == 5 && g.transform.w == 1920)
    }
    @Test func roundTripKeepsEverything() throws {
        var l = Layer.text("T", "{{team1}} vs {{team2}}", x: 10, y: 20, w: 300, h: 80)
        l.animations = [.fadeIn(), .pulse()]; l.glow = Glow(radius: 12); l.chromaKey = ChromaKey(); l.mask = Mask(.hexagon)
        l.effects = [Effect(.glitch, amount: 0.3)]
        let group = Layer.group("G", [l, Layer.effect("fx", EffectSpec(.fireEmitter, seed: 7))])
        var s = LayerScene(name: "S", layers: [group, Layer.source("cam", .camera, x: 0, y: 0, w: 100, h: 50)])
        s.background = .radial(Gradient.radial(RGBA(hex: 0x112233), RGBA(hex: 0x000000))); s.transitionIn = SceneTransition(.slide)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(LayerScene.self, from: data)
        #expect(back == s)
        #expect(back.sourceRefs == [.camera])
    }
    @Test func variableBindings() {
        let v = SceneVariables(["team1": "ALPHA", "score1": "12"])
        #expect(v.resolve("{{team1}} {{ score1 }} - {{team2}}") == "ALPHA 12 - ")
        #expect(v.resolve("{{team2}}", defaults: ["team2": "BRAVO"]) == "BRAVO")
        #expect(v.resolve("no braces") == "no braces")
        #expect(v.resolve("{{unclosed") == "{{unclosed")
    }
    @Test func tweenAndAnimationValues() {
        #expect(Tween.ease(.linear, 0.25) == 0.25)
        #expect(Tween.ease(.easeInOut, 0.5) == 0.5)
        #expect(Tween.ease(.easeOut, 0.5) > 0.5 && Tween.ease(.easeIn, 0.5) < 0.5)
        #expect(Tween.ease(.backOut, 1) == 1 && Tween.ease(.bounce, 1) == 1)
        var l = Layer.rect("a", x: 0, y: 0, w: 10, h: 10)
        l.animations = [Animation(trigger: .onShow, kind: .fade, duration: 1, delay: 0.5, easing: .linear, from: 0, to: 1)]
        #expect(l.animState(AnimClock(sinceShow: 0)).opacity == 0)
        #expect(abs(l.animState(AnimClock(sinceShow: 1.0)).opacity - 0.5) < 1e-9)
        #expect(l.animState(AnimClock(sinceShow: 5)).opacity == 1)
        l.animations = [Animation.slideIn(from: 300, direction: 180, dur: 1)]
        let s0 = l.animState(AnimClock(sinceShow: 0)), s1 = l.animState(AnimClock(sinceShow: 9))
        #expect(abs(s0.dx + 300) < 1e-6 && abs(s1.dx) < 1e-6)          // enters from the left moving... 300 px at t=0, 0 at rest
        l.animations = [Animation.fadeOut(0.4)]
        #expect(l.animState(AnimClock(sinceShow: 5)).opacity == 1)       // onHide inactive
        #expect(l.animState(AnimClock(sinceShow: 5, sinceHide: 0.4)).opacity == 0)
        l.animations = [Animation.pulse(period: 2, amount: 0.1)]
        let p = l.animState(AnimClock(sinceShow: 1, time: 1)).scale      // half period of a ping-pong: peak
        #expect(abs(p - 1.1) < 1e-6)
        l.animations = [Animation(trigger: .onShow, kind: .typewriter, duration: 1, easing: .linear, from: 0, to: 1)]
        #expect(abs(l.animState(AnimClock(sinceShow: 0.25)).typewriter - 0.25) < 1e-9)
    }
}

// MARK: migration

@Suite struct SceneMigrationTests {
    @Test func everyOldLayoutMigratesWithItsGeometry() {
        for kind in LayoutKind.allCases {
            let n = LayoutMath.slotCount(kind)
            let slots: [SourceRef?] = (0..<n).map { .device(id: "d\($0)") }
            let old = Scene(id: "o-\(kind.rawValue)", name: "Old", layout: kind, slots: slots)
            let ls = LayerScene.migrate(old)
            #expect(ls.id == old.id && ls.migratedFrom == old.id && ls.layers.count == n)
            let rects = LayoutMath.rects(for: kind)
            for (i, sr) in rects.enumerated() {
                let l = ls.layers[i]
                #expect(l.transform.rect == CGRect(x: sr.rect.minX.rounded(), y: sr.rect.minY.rounded(), width: sr.rect.width.rounded(), height: sr.rect.height.rounded()))
                #expect((l.cornerRadius > 0) == sr.framed && (l.border.width > 0) == sr.framed)
                if case .source(let r, let fit) = l.kind { #expect(r == .device(id: "d\(i)") && fit == .fill) } else { Issue.record("slot \(i) not a source layer") }
            }
            if rects.contains(where: { $0.framed }) { #expect(ls.background.kind == .linearGradient) } else { #expect(ls.background.kind == .solid) }
            #expect(LayerScene.migrate(old) == ls)       // idempotent: stable ids
        }
    }
    @Test func fitsEmptySlotsAndSlate() {
        var old = Scene(id: "x", name: "x", layout: .side, slots: [.slate, nil])
        old.setFit(0, true)
        let ls = LayerScene.migrate(old)
        if case .source(let r, let fit) = ls.layers[0].kind { #expect(r == .slate && fit == .fit) } else { Issue.record("slate not a source") }
        #expect(ls.layers.count == 3)                      // slate + (empty background + label)
        if case .text(let t) = ls.layers[2].kind { #expect(t.string == "Empty slot") } else { Issue.record("no empty label") }
        let img = Scene(id: "i", name: "i", layout: .full, slots: [.image(id: "p")])
        if case .source(_, let fit) = LayerScene.migrate(img).layers[0].kind { #expect(fit == .fit) }
    }
    @Test func oldStoreFileStillLoadsAndShowsLayerScenes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scene-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StudioStore(dir: dir)
        let old = Scene(id: "legacy", name: "Legacy", layout: .pip, slots: [.camera, .device(id: "a")])
        store.upsert(old)
        #expect(store.layerScenes.isEmpty)
        #expect(store.allLayerScenes.map(\.id) == ["legacy"])
        // native scene + override of the old one
        var native = LayerScene(id: "native", name: "Native"); native.layers = [rect(0, 0, 10, 10, 0xFF0000)]
        store.upsert(native)
        var override = LayerScene.migrate(old); override.name = "Edited"
        store.upsert(override)
        #expect(store.allLayerScenes.map(\.name) == ["Edited", "Native"])
        let reopened = try StudioStore(dir: dir)
        #expect(reopened.scenes.count == 1 && reopened.layerScenes.count == 2)
        #expect(reopened.layerScene("legacy")?.name == "Edited" && reopened.layerScene("native") != nil)
        // a store file written before layer scenes existed has no key
        let doc = try JSONDecoder().decode(StoreDoc.self, from: Data(#"{"scenes":[{"id":"a","name":"A","layout":"full","slots":[]}]}"#.utf8))
        #expect(doc.layerScenes.isEmpty && doc.scenes.count == 1)
    }
}

// MARK: rendering

@Suite(.serialized) struct SceneRenderTests {
    @Test func solidRectPositionAndBackground() {
        guard let c = sceneComp() else { return }
        let out = rend(c, lscene([rect(100, 200, 300, 150, 0xFF0000)], bg: 0x0000FF))
        #expect(near(px(out, 250, 275), 255, 0, 0))
        #expect(near(px(out, 99, 275), 0, 0, 255) && near(px(out, 401, 275), 0, 0, 255))
        #expect(near(px(out, 250, 199), 0, 0, 255) && near(px(out, 250, 351), 0, 0, 255))
    }
    @Test func rotationQuarterTurnSwapsExtents() {
        guard let c = sceneComp() else { return }
        // 400x100 box centred at (500,500), rotated 90 degrees -> occupies 100 wide x 400 tall
        let l = rect(300, 450, 400, 100, 0x00FF00) { $0.transform.rotation = 90 }
        let out = rend(c, lscene([l]))
        #expect(near(px(out, 500, 320), 0, 255, 0) && near(px(out, 500, 680), 0, 255, 0))
        #expect(near(px(out, 350, 500), 0, 0, 0) && near(px(out, 650, 500), 0, 0, 0))
        // 45 degrees: the corner of the unrotated box is now empty, the diagonal reaches further
        let d = rect(300, 450, 400, 100, 0x00FF00) { $0.transform.rotation = 45 }
        let o2 = rend(c, lscene([d]))
        #expect(near(px(o2, 500, 500), 0, 255, 0) && near(px(o2, 640, 640), 0, 255, 0))
        #expect(near(px(o2, 305, 455), 0, 0, 0))
    }
    @Test func cropTrimsSourceBeforeFill() {
        guard let c = sceneComp() else { return }
        let prov = FakeProvider(); c.provider = prov
        // left half red, right half blue, 1000x1000
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1000, 1000, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
        for y in 0..<1000 { for x in 0..<1000 { let p = base + y * bpr + x * 4; let red = x < 500; p[0] = red ? 0 : 255; p[1] = 0; p[2] = red ? 255 : 0; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        prov.sources[.camera] = FakeSource(.camera, pb)
        var l = Layer.source("s", .device(id: "z"), x: 100, y: 100, w: 400, h: 400, fit: .fill)
        prov.sources[.device(id: "z")] = FakeSource(.device(id: "z"), pb)
        let full = rend(c, lscene([l]))
        #expect(near(px(full, 150, 300), 255, 0, 0) && near(px(full, 450, 300), 0, 0, 255))
        l.crop = Crop(l: 0.5)                              // keep only the blue half
        let cropped = rend(c, lscene([l]))
        #expect(near(px(cropped, 150, 300), 0, 0, 255) && near(px(cropped, 450, 300), 0, 0, 255))
    }
    @Test func masksAndBorder() {
        guard let c = sceneComp() else { return }
        let circ = rect(100, 100, 400, 400, 0xFFFFFF) { $0.mask = Mask(.circle) }
        var o = rend(c, lscene([circ]))
        #expect(near(px(o, 300, 300), 255, 255, 255))
        #expect(near(px(o, 108, 108), 0, 0, 0))                       // corner outside the circle
        #expect(near(px(o, 300, 102), 255, 255, 255))                 // top of the circle
        let hexa = rect(100, 100, 400, 400, 0xFFFFFF) { $0.mask = Mask(.hexagon) }
        o = rend(c, lscene([hexa]))
        #expect(near(px(o, 300, 300), 255, 255, 255) && near(px(o, 104, 104), 0, 0, 0))
        let par = rect(100, 100, 400, 400, 0xFFFFFF) { $0.mask = Mask(.parallelogram, skew: 0.5) }   // top shifted right
        o = rend(c, lscene([par]))
        #expect(near(px(o, 490, 110), 255, 255, 255) && near(px(o, 110, 110), 0, 0, 0))
        #expect(near(px(o, 110, 490), 255, 255, 255) && near(px(o, 490, 490), 0, 0, 0))
        let rr = rect(100, 100, 400, 400, 0xFFFFFF) { $0.cornerRadius = 100; $0.border = Border(width: 10, color: RGBA(hex: 0xFF0000)) }
        o = rend(c, lscene([rr]))
        #expect(near(px(o, 300, 300), 255, 255, 255))
        #expect(near(px(o, 300, 104), 255, 0, 0))                     // border ring, inside the box edge
        #expect(near(px(o, 101, 101), 0, 0, 0))                       // rounded corner is cut
    }
    @Test func blendModes() {
        guard let c = sceneComp() else { return }
        func blend(_ m: BlendMode, base: UInt32, top: UInt32) -> (r: Int, g: Int, b: Int) {
            let a = rect(0, 0, 400, 400, base), b = rect(0, 0, 400, 400, top) { $0.blend = m }
            return px(rend(c, lscene([a, b])), 200, 200)
        }
        #expect(near(blend(.normal, base: 0x336699, top: 0xFF0000), 255, 0, 0))
        let add = blend(.add, base: 0x401000, top: 0x100020)
        #expect(add.r > 0x40 && add.b > 0x10 && add.g >= 0x0E)
        let mul = blend(.multiply, base: 0xFFFFFF, top: 0x808080)
        #expect(near(mul, 128, 128, 128, tol: 6))
        #expect(near(blend(.multiply, base: 0xFF0000, top: 0x00FF00), 0, 0, 0))
        let scr = blend(.screen, base: 0x000000, top: 0x336699)
        #expect(near(scr, 0x33, 0x66, 0x99, tol: 4))
        let scr2 = blend(.screen, base: 0xFFFFFF, top: 0x336699)
        #expect(near(scr2, 255, 255, 255))
        let ov = blend(.overlay, base: 0x808080, top: 0x808080)
        #expect(near(ov, 128, 128, 128, tol: 12))
        let ovDark = blend(.overlay, base: 0x202020, top: 0x202020)       // dark base: multiply-like, darker than the base
        #expect(ovDark.r < 0x20)
    }
    @Test func opacityGroupAndColourAdjust() {
        guard let c = sceneComp() else { return }
        let half = rect(0, 0, 100, 100, 0xFFFFFF) { $0.opacity = 0.5 }
        #expect(near(px(rend(c, lscene([half])), 50, 50), 128, 128, 128, tol: 6))
        // group at 50 %: two overlapping children inside must not double up
        let kids = [rect(0, 0, 100, 100, 0xFFFFFF), rect(20, 20, 60, 60, 0xFFFFFF)]
        var g = Layer.group("g", kids, x: 200, y: 0, w: 100, h: 100); g.opacity = 0.5
        let og = rend(c, lscene([g]))
        #expect(near(px(og, 250, 50), 128, 128, 128, tol: 6) && near(px(og, 205, 5), 128, 128, 128, tol: 6))
        // group children are positioned in group-local coordinates
        let moved = Layer.group("g2", [rect(10, 10, 20, 20, 0xFF0000)], x: 500, y: 500, w: 100, h: 100)
        let om = rend(c, lscene([moved]))
        #expect(near(px(om, 520, 520), 255, 0, 0) && near(px(om, 15, 15), 0, 0, 0))
        // saturation -1 -> grey; brightness
        let grey = rect(0, 0, 100, 100, 0xFF0000) { $0.colorAdjust = ColorAdjust(saturation: -1) }
        let pg = px(rend(c, lscene([grey])), 50, 50)
        #expect(abs(pg.r - pg.g) < 8 && abs(pg.g - pg.b) < 8 && pg.r > 40)
        let bright = rect(0, 0, 100, 100, 0x404040) { $0.colorAdjust = ColorAdjust(brightness: 0.25) }
        #expect(px(rend(c, lscene([bright])), 50, 50).r > 0x50)
    }
    @Test func shadowAndGlowDrawOutsideTheBox() {
        guard let c = sceneComp() else { return }
        let sh = rect(300, 300, 200, 200, 0xFFFFFF) { $0.shadow = Shadow(color: RGBA(1, 0, 0, 1), blur: 30, dx: 40, dy: 40) }
        let o = rend(c, lscene([sh]))
        #expect(px(o, 520, 520).r > 100 && px(o, 520, 520).g < 30)         // shadow offset down-right
        #expect(near(px(o, 250, 250), 0, 0, 0, tol: 10))                    // not up-left
        let gl = rect(300, 300, 200, 200, 0x202020) { $0.glow = Glow(color: RGBA(0, 1, 0), radius: 40, intensity: 1) }
        let og = rend(c, lscene([gl]))
        #expect(px(og, 510, 400).g > 60 && px(og, 700, 400).g < 10)
        #expect(near(px(og, 400, 400), 32, 32, 32, tol: 40))
    }
    @Test func chromaKeyRemovesGreen() {
        guard let c = sceneComp() else { return }
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.camera] = FakeSource(.camera, makeBGRA(640, 360, r: 0, g: 255, b: 0))
        var l = Layer.source("k", .device(id: "g"), x: 0, y: 0, w: 640, h: 360)
        prov.sources[.device(id: "g")] = FakeSource(.device(id: "g"), makeBGRA(640, 360, r: 0, g: 255, b: 0))
        let on = rect(0, 0, 640, 360, 0xFF00FF)
        l.chromaKey = ChromaKey()
        let o = rend(c, lscene([on, l]))
        #expect(near(px(o, 320, 180), 255, 0, 255, tol: 10))              // keyed out: magenta shows through
        l.chromaKey = nil
        #expect(near(px(rend(c, lscene([on, l])), 320, 180), 0, 255, 0))
    }
    @Test func textRendersAndBindsVariables() {
        guard let c = sceneComp() else { return }
        let t = Layer.text("t", "{{team1}}", x: 100, y: 100, w: 800, h: 200, style: TextStyle("x", size: 120, weight: 800, color: .white))
        let scene = lscene([t])
        func ink(_ v: SceneVariables) -> Int {
            let o = rend(c, scene, vars: v); var n = 0
            for y in stride(from: 100, to: 300, by: 2) { for x in stride(from: 100, to: 900, by: 2) where lum(px(o, x, y)) > 300 { n += 1 } }
            return n
        }
        let empty = ink(SceneVariables()), alpha = ink(SceneVariables(["team1": "ALPHA"])), long = ink(SceneVariables(["team1": "ALPHA BRAVO"]))
        #expect(empty == 0)
        #expect(alpha > 200)
        #expect(long > 0 && long != alpha)
        // typewriter: half the characters at t = 0.5
        var tw = t
        tw.animations = [Animation(trigger: .onShow, kind: .typewriter, duration: 1, easing: .linear, from: 0, to: 1)]
        var s2 = lscene([tw]); s2.variableDefaults = ["team1": "ABCDEFGH"]
        let half = rend(c, s2, clock: AnimClock(sinceShow: 0.5)), full = rend(c, s2, clock: AnimClock(sinceShow: 2))
        func count(_ o: CVPixelBuffer) -> Int { var n = 0; for y in stride(from: 100, to: 300, by: 2) { for x in stride(from: 100, to: 900, by: 2) where lum(px(o, x, y)) > 300 { n += 1 } }; return n }
        #expect(count(half) > 0 && count(half) < count(full))
    }
    @Test func shapesGradientsAndStroke() {
        guard let c = sceneComp() else { return }
        let g = Layer(name: "g", kind: .shape(ShapeSpec(.rect, fill: Fill(gradient: .linear(RGBA(hex: 0xFF0000), RGBA(hex: 0x0000FF), angle: 0)))), transform: Transform(x: 0, y: 0, w: 400, h: 100))
        let o = rend(c, lscene([g]))
        #expect(px(o, 10, 50).r > 200 && px(o, 10, 50).b < 50)
        #expect(px(o, 390, 50).b > 200 && px(o, 390, 50).r < 50)
        // multi-stop polygon with stroke goes through the sprite path
        let grad = Gradient(stops: [GradientStop(0, RGBA(hex: 0xFF0000)), GradientStop(0.5, RGBA(hex: 0x00FF00)), GradientStop(1, RGBA(hex: 0x0000FF))], angle: 0)
        let poly = Layer(name: "p", kind: .shape(ShapeSpec(.polygon, fill: Fill(gradient: grad), stroke: Stroke(width: 8, color: .white), sides: 6)), transform: Transform(x: 100, y: 300, w: 400, h: 400))
        let op = rend(c, lscene([poly]))
        #expect(px(op, 300, 500).g > 150)                 // middle stop
        #expect(lum(px(op, 300, 305)) > 500 || lum(px(op, 300, 308)) > 500)   // white stroke near the top vertex edge
        let ell = Layer(name: "e", kind: .shape(ShapeSpec(.ellipse, fill: solid(0xFFFF00))), transform: Transform(x: 100, y: 100, w: 400, h: 200))
        let oe = rend(c, lscene([ell]))
        #expect(near(px(oe, 300, 200), 255, 255, 0) && near(px(oe, 105, 105), 0, 0, 0))
    }
    @Test func transitionsMidpoints() {
        guard let c = sceneComp() else { return }
        let a = lscene([rect(0, 0, 1920, 1080, 0xFF0000)]), b = lscene([rect(0, 0, 1920, 1080, 0x0000FF)])
        func at(_ kind: SceneTransitionKind, _ mix: Float, dir: Double = 180) -> CVPixelBuffer {
            var r = FrameRequest(); r.layerProgram = b; r.layerPrevious = a; r.mix = mix; r.transition = SceneTransition(kind, duration: 1, direction: dir)
            return renderSync(c, r)
        }
        let fade = at(.fade, 0.5)
        #expect(px(fade, 960, 540).r > 100 && px(fade, 960, 540).b > 100)
        // slide towards the left: new scene enters from the right; at 50 % the right half is blue and the left half red
        let sl = at(.slide, 0.5)
        #expect(near(px(sl, 1500, 540), 0, 0, 255, tol: 12) && near(px(sl, 400, 540), 255, 0, 0, tol: 12))
        let wp = at(.wipe, 0.5)
        #expect(px(wp, 1700, 540).b > 200 && px(wp, 200, 540).r > 200)
        #expect(near(px(at(.zoom, 0.0), 960, 540), 255, 0, 0, tol: 12))
        #expect(near(px(at(.zoom, 0.999), 960, 540), 0, 0, 255, tol: 12))
        // stinger: scene cuts at the cut point and the video plays on top
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.prop(id: "st")] = FakeSource(.prop(id: "st"), makeBGRA(64, 36, r: 0, g: 255, b: 0))
        var r = FrameRequest(); r.layerProgram = b; r.layerPrevious = a; r.mix = 0.5; r.transition = SceneTransition(.stinger, duration: 1, stingerPropId: "st", cutPoint: 0.3)
        #expect(near(px(renderSync(c, r), 960, 540), 0, 255, 0, tol: 8))
    }
    @Test func slateAndMissingSourceDrawPlaceholders() {
        guard let c = sceneComp() else { return }
        let s = lscene([Layer.source("slate", .slate, x: 0, y: 0, w: 1920, h: 1080)])
        let o = rend(c, s)
        let centre = px(o, 960, 100)
        #expect(centre.g > 0 && lum(centre) < 200)
        var ink = 0
        for y in stride(from: 500, to: 700, by: 2) { for x in stride(from: 600, to: 1300, by: 2) where lum(px(o, x, y)) > 500 { ink += 1 } }
        #expect(ink > 100)                                      // "STARTING SOON"
        let missing = lscene([Layer.source("m", .device(id: "ghost"), x: 0, y: 0, w: 1920, h: 1080)])
        #expect(near(px(rend(c, missing), 20, 20), 0x0D, 0x14, 0x18, tol: 6))
    }
    @Test func animationsAffectRenderedOutput() {
        guard let c = sceneComp() else { return }
        var l = rect(100, 100, 200, 200, 0xFFFFFF)
        l.animations = [Animation.fadeIn(1), Animation.slideIn(from: 400, direction: 180, dur: 1)]
        let s = lscene([l])
        let start = rend(c, s, clock: AnimClock(sinceShow: 0)), end = rend(c, s, clock: AnimClock(sinceShow: 5))
        #expect(near(px(start, 200, 200), 0, 0, 0) && near(px(end, 200, 200), 255, 255, 255))
        // wipe reveals from the left
        var w = rect(0, 0, 1000, 100, 0xFFFFFF)
        w.animations = [Animation(trigger: .onShow, kind: .wipe, duration: 1, easing: .linear, from: 0, to: 1, direction: 0)]
        let mid = rend(c, lscene([w]), clock: AnimClock(sinceShow: 0.5))
        #expect(near(px(mid, 200, 50), 255, 255, 255) && near(px(mid, 800, 50), 0, 0, 0))
        // loop rotate: after a quarter of the period a wide box is rotated by 90 deg
        var r = rect(300, 450, 400, 100, 0xFFFFFF)
        r.animations = [Animation.spin(period: 4, degrees: 360)]
        let rot = rend(c, lscene([r]), clock: AnimClock(sinceShow: 1, time: 1))
        #expect(near(px(rot, 500, 320), 255, 255, 255) && near(px(rot, 350, 500), 0, 0, 0))
    }
    @Test func stillRenderProducesImageOfRequestedSize() {
        guard let c = sceneComp() else { return }
        let s = lscene([rect(0, 0, 960, 1080, 0xFF0000)], bg: 0x0000FF)
        guard let img = c.renderStill(s, size: CGSize(width: 192, height: 108)) else { Issue.record("no image"); return }
        #expect(img.width == 192 && img.height == 108)
        let data = img.dataProvider!.data!, p = CFDataGetBytePtr(data)!, bpr = img.bytesPerRow
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let q = p + y * bpr + x * 4; return (Int(q[2]), Int(q[1]), Int(q[0])) }
        #expect(near((at(20, 50).0, at(20, 50).1, at(20, 50).2), 255, 0, 0) && near((at(170, 50).0, at(170, 50).1, at(170, 50).2), 0, 0, 255))
        let eng = StudioEngine()
        #expect(eng.renderStill(s, size: CGSize(width: 96, height: 54))?.width == 96)
    }
}

// MARK: particles & effects

@Suite(.serialized) struct SceneEffectTests {
    private func fire(seed: UInt32, count: Int = 600) -> LayerScene {
        lscene([Layer.effect("fire", EffectSpec(.fireEmitter, intensity: 1.0, count: count, seed: seed, size: 24), x: 660, y: 300, w: 600, h: 780)])
    }
    private func hash(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
        var h: UInt64 = 1469598103934665603
        for y in stride(from: 0, to: 1080, by: 2) { for x in stride(from: 0, to: 1920 * 4, by: 1) { h = (h ^ UInt64(base[y * bpr + x])) &* 1099511628211 } }
        return Int(truncatingIfNeeded: h)
    }
    @Test func particlesAreDeterministicPerSeedAndTime() {
        guard let c = sceneComp() else { return }
        let a1 = hash(rend(c, fire(seed: 5), time: 3.25)), a2 = hash(rend(c, fire(seed: 5), time: 3.25))
        #expect(a1 == a2)
        #expect(hash(rend(c, fire(seed: 6), time: 3.25)) != a1)      // other seed
        #expect(hash(rend(c, fire(seed: 5), time: 3.5)) != a1)       // animates
        #expect(ParticleMath.value(seed: 5, index: 11, key: 2) == ParticleMath.value(seed: 5, index: 11, key: 2))
        #expect(ParticleMath.value(seed: 5, index: 11, key: 2) != ParticleMath.value(seed: 6, index: 11, key: 2))
    }
    @Test func fireIsBrightAtTheBaseAndDarkAbove() {
        guard let c = sceneComp() else { return }
        let o = rend(c, fire(seed: 1, count: 900), time: 2)
        var low = 0, high = 0
        for y in stride(from: 900, to: 1075, by: 5) { for x in stride(from: 760, to: 1160, by: 5) { low += lum(px(o, x, y)) } }
        for y in stride(from: 10, to: 80, by: 5) { for x in stride(from: 760, to: 1160, by: 5) { high += lum(px(o, x, y)) } }
        #expect(low > 20_000 && high == 0)
        var warm = 0, cold = 0
        for y in stride(from: 900, to: 1075, by: 5) { for x in stride(from: 760, to: 1160, by: 5) { let q = px(o, x, y); warm += q.r; cold += q.b } }
        #expect(warm > cold)                                          // warm colours
    }
    @Test func proceduralEffectsDrawSomething() {
        guard let c = sceneComp() else { return }
        for kind in [EffectKind.scanlines, .vignette, .filmGrain, .lightSweep, .pulsingGlow, .hudCornerBrackets, .radarSweep, .animatedGradient, .glitch, .lightning, .embers, .smoke, .sparks] {
            var spec = EffectSpec(kind, color: RGBA(hex: 0xFFAA33), color2: RGBA(hex: 0x3366FF), intensity: 1.5, speed: 1, count: 300, seed: 2, size: 40, thickness: 6)
            if kind == .glitch { spec.intensity = 8 }
            let l = Layer.effect("fx", spec, blend: kind == .vignette || kind == .scanlines ? .normal : .add)
            var lit = 0
            for t in [0.2, 0.45, 0.7, 1.1] {          // lightning only strikes in some slots; sample a few instants
                let o = rend(c, lscene([l]), time: t)
                for y in stride(from: 0, to: 1080, by: 12) { for x in stride(from: 0, to: 1920, by: 12) where lum(px(o, x, y)) > 6 { lit += 1 } }
            }
            #expect(lit > 0, "effect \(kind) drew nothing")
        }
    }
    @Test func tickerCountdownAndKillfeedRender() {
        guard let c = sceneComp() else { return }
        let layers = [
            Layer.effect("tick", EffectSpec(.ticker, color: .white, text: "BREAKING NEWS {{matchTitle}}", fontSize: 40), x: 0, y: 900, w: 1920, h: 60),
            Layer.effect("cd", EffectSpec(.countdown, color: RGBA(hex: 0xFFAA00), text: "{{timer}}", fontSize: 120), x: 700, y: 100, w: 520, h: 200),
            Layer.effect("kf", EffectSpec(.killfeedLine, color: RGBA(hex: 0xFF3030), text: "ALPHA eliminated BRAVO", fontSize: 30), x: 100, y: 500, w: 700, h: 50)]
        let o = rend(c, lscene(layers), time: 1.5, vars: .sample)
        func lit(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int { var n = 0; for y in stride(from: y0, to: y1, by: 2) { for x in stride(from: x0, to: x1, by: 2) where lum(px(o, x, y)) > 250 { n += 1 } }; return n }
        #expect(lit(0, 900, 1920, 960) > 100)
        #expect(lit(700, 100, 1220, 300) > 100)
        #expect(lit(100, 500, 800, 550) > 50)
        #expect(near(px(o, 103, 525), 255, 48, 48, tol: 40))           // killfeed accent bar
    }
}

// MARK: GPU budget

@Suite(.serialized) struct SceneBenchmarkTests {
    /// ~12 layers: 3 live sources, 2 glows, 1 fire emitter, text, shapes, scan lines, vignette.
    static func typicalScene() -> LayerScene {
        var layers: [Layer] = []
        var main = Layer.source("main", .device(id: "p0"), x: 40, y: 80, w: 1200, h: 675); main.cornerRadius = 18; main.border = Border(width: 3, color: RGBA(hex: 0xFF7A1A)); main.glow = Glow(color: RGBA(hex: 0xFF7A1A), radius: 30, intensity: 0.8)
        var p1 = Layer.source("p1", .device(id: "p1"), x: 1290, y: 80, w: 590, h: 332); p1.cornerRadius = 18; p1.border = Border(width: 3, color: .white); p1.shadow = Shadow(color: RGBA(0, 0, 0, 0.7), blur: 20, dx: 0, dy: 10)
        var p2 = Layer.source("p2", .camera, x: 1290, y: 430, w: 590, h: 332); p2.mask = Mask(.hexagon); p2.glow = Glow(color: RGBA(hex: 0x35B6FF), radius: 24, intensity: 1)
        layers += [main, p1, p2]
        layers.append(Layer.rect("bar", x: 0, y: 900, w: 1920, h: 180, fill: Fill(gradient: .linear(RGBA(0, 0, 0, 0), RGBA(0, 0, 0, 0.85)))))
        layers.append(Layer.text("title", "{{matchTitle}}", x: 40, y: 10, w: 1000, h: 70, style: TextStyle("x", size: 54, weight: 900, tracking: 4, color: .white, shadow: Shadow(blur: 8, dx: 0, dy: 3))))
        layers.append(Layer.text("score", "{{team1}}  {{score1}} : {{score2}}  {{team2}}", x: 40, y: 790, w: 1200, h: 100, style: TextStyle("x", size: 80, weight: 900, color: .white)))
        layers.append(Layer.effect("fire", EffectSpec(.fireEmitter, intensity: 1.2, count: 700, seed: 3, size: 70), x: 0, y: 780, w: 1920, h: 300, blend: .add))
        layers.append(Layer.effect("embers", EffectSpec(.embers, count: 150, seed: 9, size: 40), x: 0, y: 300, w: 1920, h: 780, blend: .add))
        layers.append(Layer.effect("brackets", EffectSpec(.hudCornerBrackets, size: 60, thickness: 4), x: 20, y: 60, w: 1240, h: 715))
        layers.append(Layer.effect("scan", EffectSpec(.scanlines, color: .black, intensity: 0.5, size: 4)))
        layers.append(Layer.effect("vig", EffectSpec(.vignette, color: .black, intensity: 0.9)))
        layers.append(Layer.rect("tag", x: 1500, y: 800, w: 380, h: 90, fill: solid(0xE5261B), cornerRadius: 12))
        return LayerScene(id: "bench", name: "bench", background: .radial(Gradient.radial(RGBA(hex: 0x2A1208), RGBA(hex: 0x050403))), layers: layers)
    }
    @Test func typicalSceneStaysUnderGpuBudget() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        for id in ["p0", "p1"] { prov.sources[.device(id: id)] = FakeSource(.device(id: id), makeNV12(1920, 1080, y: 110, cb: 120, cr: 140)) }
        prov.sources[.camera] = FakeSource(.camera, makeNV12(1280, 720, y: 90, cb: 130, cr: 120))
        let scene = Self.typicalScene()
        #expect(scene.layers.count >= 12)
        // warm up the sprite cache
        c.layers.sprites.sync = true
        for _ in 0..<3 { var r = FrameRequest(); r.layerProgram = scene; r.variables = .sample; _ = renderSync(c, r) }
        // serial: one frame in flight at a time (like the 60 fps engine), so gpuStart..gpuEnd is the frame's own GPU cost
        let lock = NSLock(); var gpu: [Double] = []
        let sem = DispatchSemaphore(value: 0)
        let n = 240
        for i in 0..<n {
            var r = FrameRequest(); r.layerProgram = scene; r.variables = .sample; r.time = Double(i) / 60
            let out = c.makeOutputBuffer()!
            while !c.render(r, to: FrameTargets(output: out), completion: { ms in lock.lock(); gpu.append(ms); lock.unlock(); sem.signal() }) { usleep(500) }
            sem.wait()
        }
        // pipelined throughput (3 in flight)
        let t0 = CFAbsoluteTimeGetCurrent()
        var submitted = 0
        for i in 0..<n {
            var r = FrameRequest(); r.layerProgram = scene; r.variables = .sample; r.time = Double(i) / 60
            let out = c.makeOutputBuffer()!
            while !c.render(r, to: FrameTargets(output: out), completion: { _ in sem.signal() }) { usleep(200) }
            submitted += 1
        }
        for _ in 0..<submitted { sem.wait() }
        let wall = CFAbsoluteTimeGetCurrent() - t0
        lock.lock(); let g = gpu.sorted(); lock.unlock()
        let avg = g.reduce(0, +) / Double(g.count), p99 = g[Int(Double(g.count) * 0.99)]
        // other processes / parallel tests share the GPU: judge the quietest third of the run
        let quiet = g.prefix(g.count / 3).reduce(0, +) / Double(g.count / 3)
        print(String(format: "SCENE BENCH layers=%d draws=%d gpu avg=%.2fms (quietest third %.2fms) p99=%.2fms throughput=%.0f fps", scene.layers.count, c.layers.lastDrawCount, avg, quiet, p99, Double(n) / wall))
        #expect(quiet < 4.0)
        #expect(Double(n) / wall > 60)
    }
}

// MARK: sprite cache + engine integration

@Suite(.serialized) struct SceneEngineTests {
    @Test func spritesRasteriseOffThreadAndStaleTextStaysVisible() {
        guard let c = MetalCompositor() else { return }          // sync = false: the render thread never rasterises
        let t = Layer.text("t", "{{timer}}", x: 100, y: 100, w: 800, h: 200, style: TextStyle("x", size: 120, weight: 800))
        let scene = lscene([t])
        func ink(_ o: CVPixelBuffer) -> Int { var n = 0; for y in stride(from: 100, to: 300, by: 3) { for x in stride(from: 100, to: 900, by: 3) where lum(px(o, x, y)) > 300 { n += 1 } }; return n }
        let first = rend(c, scene, vars: SceneVariables(["timer": "08:42"]))
        #expect(ink(first) == 0)                                  // nothing cached yet: no blocking, no text
        c.layers.sprites.waitIdle()
        let second = rend(c, scene, vars: SceneVariables(["timer": "08:42"]))
        #expect(ink(second) > 100)
        let changed = rend(c, scene, vars: SceneVariables(["timer": "08:41"]))
        #expect(ink(changed) > 100)                               // new string rasterising: the previous one stays on screen
        c.layers.sprites.waitIdle()
        #expect(c.layers.sprites.rasterCount >= 2)
    }
    @Test func engineRunsLayerScenesWithTransitionsAndVariables() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let prov = FakeProvider()
        for id in ["p0", "p1"] { prov.sources[.device(id: id)] = FakeSource(.device(id: id), makeNV12(1280, 720, y: 100, cb: 120, cr: 140)) }
        let sink = CountingSink(); let eng = StudioEngine()
        #expect(eng.start(fps: 60, sink: sink, provider: prov))
        let scene = SceneBenchmarkTests.typicalScene()
        eng.setSceneVariables(["team1": "ALPHA", "team2": "BRAVO", "score1": "3", "score2": "2", "matchTitle": "FINAL"])
        eng.setProgram(scene, fade: false)
        var alt = scene; alt.id = "alt"; alt.transitionIn = SceneTransition(.slide, duration: 0.3)
        eng.setPreview(alt)
        Thread.sleep(forTimeInterval: 1.0)
        eng.take()                                             // slide transition from the scene's transitionIn
        Thread.sleep(forTimeInterval: 1.0)
        eng.setSceneVariable("score1", "4")
        Thread.sleep(forTimeInterval: 0.5)
        eng.stop(); let st = eng.stats
        print(String(format: "ENGINE SCENE fps=%.2f missed=%d held=%d gpu avg=%.2fms p99=%.2fms", st.fps, st.missedDeadlines, st.heldFrames, st.gpuAvgMs, st.gpuP99Ms))
        #expect(st.fps > 55 && st.gpuAvgMs < 6)
        #expect(sink.snapshot.count > 120)
        #expect(eng.sceneVariables["score1"] == "4")
    }
}

// MARK: visual dump (set STUDIO_SCENE_DUMP=/dir to write PNGs for eyeballing)

@Suite(.serialized) struct SceneVisualDump {
    @Test func dumpFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["STUDIO_SCENE_DUMP"], let c = sceneComp() else { return }
        let prov = FakeProvider(); c.provider = prov
        for id in ["p0", "p1"] { prov.sources[.device(id: id)] = FakeSource(.device(id: id), makeBGRA(1280, 720, r: id == "p0" ? 60 : 30, g: id == "p0" ? 90 : 120, b: id == "p0" ? 140 : 70)) }
        prov.sources[.camera] = FakeSource(.camera, makeBGRA(1280, 720, r: 120, g: 70, b: 60))
        func save(_ name: String, _ pb: CVPixelBuffer) {
            guard let img = pb.studioCGImage(), let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        save("typical", rend(c, SceneBenchmarkTests.typicalScene(), time: 2.3, vars: .sample))
        let fire = lscene([Layer.effect("fire", EffectSpec(.fireEmitter, count: 600, seed: 1, size: 24), x: 560, y: 300, w: 800, h: 780, blend: .add)], bg: 0x0A0604)
        save("fire", rend(c, fire, time: 2.0))
        let sparks = lscene([Layer.effect("sp", EffectSpec(.sparks, count: 200, seed: 4, size: 24), x: 560, y: 300, w: 800, h: 780),
                             Layer.effect("sm", EffectSpec(.smoke, color: RGBA(0.5, 0.5, 0.5), color2: RGBA(0.2, 0.2, 0.2), count: 40, seed: 2, size: 80), x: 560, y: 300, w: 800, h: 780),
                             Layer.effect("l", EffectSpec(.lightning, color: RGBA(0.6, 0.8, 1), thickness: 4), x: 100, y: 0, w: 400, h: 1080, blend: .add),
                             Layer.effect("r", EffectSpec(.radarSweep, color: RGBA(0.2, 1, 0.4), color2: RGBA(0.2, 1, 0.4)), x: 1400, y: 100, w: 400, h: 400, blend: .add),
                             Layer.effect("b", EffectSpec(.hudCornerBrackets, color: RGBA(hex: 0x35B6FF), size: 80, thickness: 6), x: 40, y: 40, w: 1840, h: 1000)], bg: 0x0A0A12)
        save("effects", rend(c, sparks, time: 2.4))
        var t1 = Layer.text("t", "{{team1}}  {{score1}} : {{score2}}  {{team2}}", x: 160, y: 400, w: 1600, h: 200, style: TextStyle("x", size: 120, weight: 900, tracking: 4, color: .white,
            gradient: .linear(RGBA(hex: 0xFFE27A), RGBA(hex: 0xFF5A1A)), stroke: Stroke(width: 3, color: RGBA(0, 0, 0, 1)), shadow: Shadow(blur: 10, dx: 0, dy: 6)))
        t1.glow = Glow(color: RGBA(hex: 0xFF7A1A), radius: 30, intensity: 0.6)
        var panel = Layer.rect("p", x: 120, y: 360, w: 1680, h: 280, fill: Fill(gradient: .linear(RGBA(0, 0, 0, 0.8), RGBA(hex: 0x301005, alpha: 0.6), angle: 0)), cornerRadius: 24)
        panel.border = Border(width: 4, color: RGBA(hex: 0xFF7A1A)); panel.mask = Mask(.parallelogram, skew: 0.15)
        save("text", rend(c, lscene([panel, t1], bg: 0x101820), vars: .sample))
    }
}
