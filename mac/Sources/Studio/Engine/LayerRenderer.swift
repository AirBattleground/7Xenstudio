// Layer-scene renderer on top of the zero-copy compositor. One general textured-quad pipeline (transform / rotation / crop /
// mask SDF / border / shadow / glow / colour adjust / chroma key / blend), cached CoreGraphics sprites for text / shapes / images
// (rasterised once, off the render thread), stateless GPU particles, procedural effects, offscreen groups and transitions.
import Foundation
import Metal
import MetalPerformanceShaders
import CoreGraphics

/// Uniforms for vsLayer/fsLayer. Field order and count must match `LayerU` in LayerShaders.swift.
struct LayerU {
    var box = SIMD4<Float>.zero, geom = SIMD4<Float>.zero, pad = SIMD4<Float>.zero, uv = SIMD4<Float>(0, 0, 1, 1), lb = SIMD4<Float>(0, 0, 1, 1)
    var content = SIMD4<Float>.zero, c0 = SIMD4<Float>.zero, c1 = SIMD4<Float>.zero, grad = SIMD4<Float>.zero
    var mask = SIMD4<Float>.zero, mask2 = SIMD4<Float>.zero, border = SIMD4<Float>.zero, bc0 = SIMD4<Float>.zero, bc1 = SIMD4<Float>.zero
    var anim = SIMD4<Float>(1, 1, 1, 0), adj0 = SIMD4<Float>.zero, adj1 = SIMD4<Float>.zero, key0 = SIMD4<Float>.zero, key1 = SIMD4<Float>.zero
    var fx0 = SIMD4<Float>.zero, fx1 = SIMD4<Float>.zero, shd = SIMD4<Float>.zero, shdc = SIMD4<Float>.zero, bars = SIMD4<Float>.zero
    var eff0 = SIMD4<Float>.zero, eff1 = SIMD4<Float>.zero
    var ext0 = SIMD4<Float>.zero, ext1 = SIMD4<Float>.zero, ext2 = SIMD4<Float>.zero, ext3 = SIMD4<Float>.zero
}
private struct TransU { var p = SIMD4<Float>.zero; var d = SIMD4<Float>.zero }

@inline(__always) func lin709(_ v: Double) -> Float {
    let x = max(0, v)
    return Float(x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1 / 0.45))
}
/// Straight (non-premultiplied) shader colour. Layers composite in encoded space, so this is the colour as authored.
func linearColor(_ c: RGBA, alphaMul: Double = 1) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a * alphaMul)) }

// MARK: - sprite cache (CoreGraphics art -> MTLTexture, rasterised off the render thread)

final class SpriteStore: @unchecked Sendable {
    struct Sprite { var tex: MTLTexture; var meta: Double }
    private struct Entry { var sprite: Sprite; var used: UInt64; var bytes: Int }
    let device: MTLDevice
    /// Tests and stills rasterise on the calling thread so the first frame is complete.
    /// Per calling thread, so a still renderer sharing this store can rasterise inline while the live render thread stays asynchronous.
    var sync: Bool {
        get { (Thread.current.threadDictionary[syncKey] as? Bool) ?? false }
        set { Thread.current.threadDictionary[syncKey] = newValue }
    }
    private var syncKey: String { "spritesSync\(ObjectIdentifier(self).hashValue)" }
    var byteBudget = 384 * 1024 * 1024
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var latest: [String: Sprite] = [:]       // slot (layer id) -> newest completed sprite, shown while the next one rasterises
    private var pending = Set<String>()
    private var bytes = 0
    private var frame: UInt64 = 0
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "scene.sprites", qos: .userInitiated, attributes: .concurrent)
    private(set) var rasterCount = 0

    init(device: MTLDevice) { self.device = device }
    func nextFrame() { lock.lock(); frame += 1; lock.unlock() }
    /// Blocks until in-flight rasterisation finishes (tests).
    func waitIdle(timeout: TimeInterval = 10) { _ = group.wait(timeout: .now() + timeout) }

    static func upload(_ cg: CGImage, device: MTLDevice) -> MTLTexture? {
        guard let data = cg.dataProvider?.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cg.width, height: cg.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, cg.width, cg.height), mipmapLevel: 0, withBytes: CFDataGetBytePtr(data), bytesPerRow: cg.bytesPerRow)
        return t
    }

    func sprite(key: String, slot: String, _ make: @escaping () -> (CGImage, Double)?) -> Sprite? {
        lock.lock()
        if var e = cache[key] { e.used = frame; cache[key] = e; let s = e.sprite; latest[slot] = s; lock.unlock(); return s }
        let fallback = latest[slot]
        let start = !pending.contains(key)
        if start { pending.insert(key) }
        lock.unlock()
        guard start else { return fallback }
        let work: () -> Void = { [self] in
            var result: Sprite?
            if let (cg, meta) = make(), let t = Self.upload(cg, device: device) { result = Sprite(tex: t, meta: meta) }
            lock.lock()
            pending.remove(key)
            if let r = result {
                let b = r.tex.width * r.tex.height * 4
                cache[key] = Entry(sprite: r, used: frame, bytes: b); bytes += b; rasterCount += 1
                if bytes > byteBudget { evict() }
            }
            lock.unlock()
        }
        if sync { work(); lock.lock(); let s = cache[key]?.sprite ?? fallback; if let s { latest[slot] = s }; lock.unlock(); return s }
        group.enter()
        queue.async { work(); self.group.leave() }
        return fallback
    }
    private func evict() {
        for (k, e) in cache.sorted(by: { $0.value.used < $1.value.used }) {
            if bytes <= byteBudget * 3 / 4 { break }
            if e.used + 2 >= frame { continue }
            bytes -= e.bytes; cache[k] = nil
        }
    }
    func removeAll() { lock.lock(); cache.removeAll(); latest.removeAll(); bytes = 0; lock.unlock() }
    /// A finished sprite for `key` (no rasterisation started); marks it used.
    func peek(_ key: String) -> Sprite? {
        lock.lock(); defer { lock.unlock() }
        guard var e = cache[key] else { return nil }
        e.used = frame; cache[key] = e; return e.sprite
    }
}

// MARK: - render pass helper

final class LayerPass {
    let cb: MTLCommandBuffer
    let target: MTLTexture
    let fr: FrameRes
    private var enc: MTLRenderCommandEncoder?
    private var cleared = false
    init(_ cb: MTLCommandBuffer, _ target: MTLTexture, _ fr: FrameRes, preserve: Bool = false) { self.cb = cb; self.target = target; self.fr = fr; cleared = preserve }
    func encoder() -> MTLRenderCommandEncoder? {
        if let e = enc { return e }
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = cleared ? .load : .clear
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        d.colorAttachments[0].storeAction = .store
        cleared = true
        enc = cb.makeRenderCommandEncoder(descriptor: d)
        return enc
    }
    func end() { enc?.endEncoding(); enc = nil }
    /// Copies the target so a blend mode that reads the backdrop can sample it.
    func backdrop(_ device: MTLDevice) -> MTLTexture? {
        end()
        guard cleared else { return nil }
        let copy = fr.tex(device, target.width, target.height)
        if let b = cb.makeBlitCommandEncoder() {
            b.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                   to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            b.endEncoding()
        }
        return copy
    }
}

/// Everything a scene render needs besides the scene itself.
struct SceneFrame {
    var cb: MTLCommandBuffer
    var fr: FrameRes
    var srcs: [SourceRef: SrcTex]
    var time: Double
    var vars: SceneVariables
}

// MARK: - renderer

final class LayerRenderer {
    let device: MTLDevice
    let sprites: SpriteStore
    var overlayImages = OverlayImageCache()
    var slateTitle = "7XEN STUDIO"
    var slateText = "Starting soon"
    var upscaleMode = Int(ProcessInfo.processInfo.environment["STUDIO_UPSCALE_MODE"] ?? "") ?? 2
    var transformFor: (SourceRef) -> SourceTransform = { _ in .identity }
    /// Intro prop shown instead of `.slate` source layers (set by the engine).
    var introPropId: String?

    private let layerPSO: [BlendMode: MTLRenderPipelineState]
    private let particleAdd, particleAlpha, transitionPSO: MTLRenderPipelineState
    private let lanczos: MPSImageLanczosScale
    private let dummy: MTLTexture
    private let fmt = MTLPixelFormat.rgba16Float
    private(set) var lastDrawCount = 0

    init?(device: MTLDevice, library lib: MTLLibrary, sprites shared: SpriteStore? = nil) {
        self.device = device
        sprites = shared ?? SpriteStore(device: device)
        func pso(_ v: String, _ f: String, _ setup: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .rgba16Float
            setup(a)
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        var m: [BlendMode: MTLRenderPipelineState] = [:]
        func on(_ a: MTLRenderPipelineColorAttachmentDescriptor, _ s: MTLBlendFactor, _ d: MTLBlendFactor, _ sa: MTLBlendFactor = .one, _ da: MTLBlendFactor = .oneMinusSourceAlpha) {
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = s; a.destinationRGBBlendFactor = d; a.sourceAlphaBlendFactor = sa; a.destinationAlphaBlendFactor = da
        }
        guard let n = pso("vsLayer", "fsLayer", { on($0, .one, .oneMinusSourceAlpha) }),
              let ad = pso("vsLayer", "fsLayer", { on($0, .one, .one, .one, .one) }),
              let sc = pso("vsLayer", "fsLayer", { on($0, .one, .oneMinusSourceColor) }),
              let mu = pso("vsLayer", "fsLayer", { on($0, .destinationColor, .oneMinusSourceAlpha) }),
              let ov = pso("vsLayer", "fsLayer", { $0.isBlendingEnabled = false }),
              let pa = pso("vsParticle", "fsParticle", { on($0, .one, .one, .one, .one) }),
              let pl = pso("vsParticle", "fsParticle", { on($0, .one, .oneMinusSourceAlpha) }),
              let tr = pso("vsFull", "fsTransition", { $0.isBlendingEnabled = false }) else { return nil }
        m[.normal] = n; m[.add] = ad; m[.screen] = sc; m[.multiply] = mu; m[.overlay] = ov
        layerPSO = m; particleAdd = pa; particleAlpha = pl; transitionPSO = tr
        lanczos = MPSImageLanczosScale(device: device)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        guard let dt = device.makeTexture(descriptor: dd) else { return nil }
        dummy = dt
    }

    // MARK: scene

    /// Renders `scene` into `target` (cleared first). `clock` drives animations.
    func render(_ scene: LayerScene, clock: AnimClock, frame: SceneFrame, target: MTLTexture) {
        sprites.nextFrame()
        lastDrawCount = 0
        let pass = LayerPass(frame.cb, target, frame.fr)
        _ = pass.encoder()
        let W = target.width, H = target.height
        var bg = backgroundLayers(scene.background, W: Double(W), H: Double(H))
        bg.append(contentsOf: [])
        drawLayers(bg, clock: AnimClock(sinceShow: 1000, sinceTake: 1000), scene: scene, pass: pass, frame: frame)
        drawLayers(scene.layers, clock: clock, scene: scene, pass: pass, frame: frame)
        pass.end()
    }

    private func backgroundLayers(_ b: Background, W: Double, H: Double) -> [Layer] {
        let tf = Transform(x: 0, y: 0, w: W, h: H)
        var out: [Layer] = []
        switch b.kind {
        case .solid: out.append(Layer(id: "bg", name: "Background", kind: .shape(ShapeSpec(.rect, fill: Fill(b.color))), transform: tf))
        case .linearGradient, .radialGradient:
            var g = b.gradient ?? Gradient.linear(b.color, b.color)
            g.radial = b.kind == .radialGradient
            out.append(Layer(id: "bg", name: "Background", kind: .shape(ShapeSpec(.rect, fill: Fill(gradient: g))), transform: tf))
        case .image:
            if let id = b.propId { out.append(Layer(id: "bg", name: "Background", kind: .image(ImageSpec(propId: id, fit: b.fit == .fit ? .fill : b.fit)), transform: tf)) }
            else { out.append(Layer(id: "bg", name: "Background", kind: .shape(ShapeSpec(.rect, fill: Fill(b.color))), transform: tf)) }
        case .video:
            if let id = b.propId { out.append(Layer(id: "bg", name: "Background", kind: .source(.prop(id: id), fit: b.fit), transform: tf)) }
        case .source:
            if let r = b.source { out.append(Layer(id: "bg", name: "Background", kind: .source(r, fit: b.fit), transform: tf)) }
        }
        if out.isEmpty { out.append(Layer(id: "bg", name: "Background", kind: .shape(ShapeSpec(.rect, fill: Fill(b.color))), transform: tf)) }
        if b.blur > 0, b.kind == .image || b.kind == .video || b.kind == .source { out[0].effects.append(Effect(.blur, amount: b.blur)) }
        if b.dim > 0, b.kind == .image || b.kind == .video || b.kind == .source {
            out.append(Layer(id: "bg-dim", name: "Dim", kind: .shape(ShapeSpec(.rect, fill: Fill(RGBA(0, 0, 0, min(1, b.dim))))), transform: tf))
        }
        return out
    }

    // MARK: layers

    private func drawLayers(_ layers: [Layer], clock: AnimClock, scene: LayerScene, pass: LayerPass, frame: SceneFrame) {
        for l in layers where l.visible { drawLayer(l, clock: clock, scene: scene, pass: pass, frame: frame) }
    }

    private struct Part {
        var u = LayerU()
        var tex: MTLTexture?
        var maskTex: MTLTexture?
        var particles = 0
        var additiveParticles = true
        var silhouette = true          // takes part in shadow / glow
        var ownMask = false            // u.mask carries the shape's own outline
        var alpha = 1.0                // per-part opacity multiplier (cross-fades inside one layer)
    }

    private func hash01(_ x: Double) -> Double { let s = sin(x * 12.9898) * 43758.5453; return s - floor(s) }

    private func drawLayer(_ layer: Layer, clock: AnimClock, scene: LayerScene, pass: LayerPass, frame: SceneFrame) {
        let anim = layer.animState(clock)
        var opacity = layer.opacity * anim.opacity
        var shakeX = 0.0, shakeY = 0.0
        var fx0 = SIMD4<Float>.zero, fx1 = SIMD4<Float>.zero
        for e in layer.effects where e.enabled {
            switch e.kind {
            case .blur: fx0.y = Float(e.amount * 24)
            case .chromaticAberration: fx0.x = Float(e.amount * 12)
            case .pixelate: fx0.z = Float(max(2, e.amount * 48))
            case .scanlines: fx0.w = Float(e.amount)
            case .glitch: fx1.x = Float(e.amount)
            case .flicker: opacity *= 1 - e.amount * hash01(floor(frame.time * 18 * e.speed)) * 0.9
            case .shake:
                let t = frame.time * 25 * e.speed
                shakeX = (hash01(floor(t)) - 0.5) * e.amount * 24; shakeY = (hash01(floor(t) + 91) - 0.5) * e.amount * 24
            }
        }
        if anim.glitch > 0 { fx1.x = max(fx1.x, Float(anim.glitch)) }
        guard opacity > 0.0005 else { return }

        let t = layer.transform
        let s = anim.scale
        guard s > 0.0001, t.w > 0, t.h > 0 else { return }
        var w = t.w * s, h = t.h * s
        var ax = t.x + t.anchorX * t.w + anim.dx + shakeX, ay = t.y + t.anchorY * t.h + anim.dy + shakeY
        var bx = ax - t.anchorX * w, by = ay - t.anchorY * h
        let rot = t.rotation + anim.rotation
        if rot == 0, s == 1 {
            let nx = bx.rounded(), ny = by.rounded()
            ax += nx - bx; ay += ny - by; bx = nx; by = ny
            w = max(1, w.rounded()); h = max(1, h.rounded())
        }
        let bw = max(1, Int(w.rounded())), bh = max(1, Int(h.rounded()))
        let canvas = (Double(pass.target.width), Double(pass.target.height))
        // cull: fully outside the target (rotation-safe bound)
        let radius = hypot(w, h) / 2 + max(layer.shadow.blur + abs(layer.shadow.dx) + abs(layer.shadow.dy), layer.glow.radius) * 2 + 4
        let cx = bx + w / 2, cy = by + h / 2
        if cx + radius < 0 || cy + radius < 0 || cx - radius > canvas.0 || cy - radius > canvas.1 { return }

        var parts = prepare(layer, bw: bw, bh: bh, pass: pass, frame: frame, scene: scene, anim: anim, clock: clock)
        guard !parts.isEmpty else { return }

        // common uniform fields
        let rad = rot * .pi / 180
        var mk = SIMD4<Float>.zero, mk2 = SIMD4<Float>.zero
        var maskTex: MTLTexture? = nil
        switch layer.mask.kind {
        case .none: mk.x = 0; mk.y = Float(layer.cornerRadius)
        case .roundedRect: mk.x = 0; mk.y = Float(layer.cornerRadius > 0 ? layer.cornerRadius : min(w, h) * 0.12)
        case .circle: mk.x = 2
        case .hexagon: mk.x = 3
        case .parallelogram: mk.x = 4; mk2.x = Float(layer.mask.skew * h)
        case .image:
            if let pid = layer.mask.propId, let l = overlayImages.image(propId: pid) {
                let key = "mask|\(pid)|\(l.version)|\(bw)x\(bh)"
                let img = l.image
                if let sp = sprites.sprite(key: key, slot: layer.id + "#mask", { (Self.stretch(img, w: bw, h: bh).map { ($0, 0) }) }) { mk.x = 5; maskTex = sp.tex }
            }
        }
        mk.z = Float(layer.mask.feather); mk.w = layer.mask.invert ? 1 : 0
        var common = LayerU()
        common.geom = SIMD4(Float(cos(rad)), Float(sin(rad)), Float(ax), Float(ay))
        common.pad = SIMD4(0, Float(canvas.0), Float(canvas.1), Float(frame.time))
        common.mask = mk; common.mask2 = mk2
        if layer.border.width > 0 {
            common.border = SIMD4(Float(layer.border.width), layer.border.gradient != nil ? 1 : 0, 0, 0)
            common.bc0 = linearColor(layer.border.color)
            if let g = layer.border.gradient, let f = g.stops.first, let l = g.stops.last {
                common.bc0 = linearColor(f.color); common.bc1 = linearColor(l.color)
                let a = g.angle * .pi / 180; common.border.z = Float(cos(a)); common.border.w = Float(sin(a))
            }
        }
        let wa = anim.wipeAngle * .pi / 180
        common.anim = SIMD4(Float(opacity), Float(anim.wipe), Float(cos(wa)), Float(sin(wa)))
        let ca = layer.colorAdjust
        common.adj0 = SIMD4(Float(ca.brightness), Float(ca.contrast), Float(ca.saturation), Float(ca.hue * .pi / 180))
        if let tint = ca.tint, tint.a > 0 { common.adj1 = SIMD4(Float(tint.r), Float(tint.g), Float(tint.b), Float(tint.a)) }
        if let k = layer.chromaKey {
            common.key0 = SIMD4(Float(k.color.r), Float(k.color.g), Float(k.color.b), 1)
            common.key1 = SIMD4(Float(k.similarity), Float(k.smoothness), Float(k.spill), 0)
        }
        common.fx0 = fx0; common.fx1 = fx1
        if let sh = layer.shine {
            let a = sh.angle * .pi / 180
            common.ext1 = SIMD4(Float(sh.intensity), Float(sh.width), Float(cos(a)), Float(sin(a)))
            common.ext2 = linearColor(sh.color)
            if let ph = sh.phase(sinceTake: clock.sinceTake) { common.ext3.x = Float(ph); common.ext3.y = 1 }
            common.ext3.z = Float(max(0, sh.shimmer))
        }
        let boxV = SIMD4<Float>(Float(bx), Float(by), Float(w), Float(h))

        for i in parts.indices {
            let part = parts[i]
            var u = common
            u.uv = part.u.uv; u.lb = part.u.lb; u.content = part.u.content; u.c0 = part.u.c0; u.c1 = part.u.c1; u.grad = part.u.grad
            u.eff0 = part.u.eff0; u.eff1 = part.u.eff1; u.bars = part.u.bars; u.ext0 = part.u.ext0
            u.mask2.y = part.u.mask2.y; u.mask2.z = part.u.mask2.z
            if part.ownMask && layer.mask.kind == .none {      // a shape's intrinsic outline (ellipse / rounded rect)
                u.mask.x = part.u.mask.x; u.mask.y = max(part.u.mask.y, Float(layer.cornerRadius))
            }
            u.box = boxV
            u.anim.x *= Float(part.alpha)
            parts[i].u = u
            parts[i].maskTex = maskTex
        }
        // shadow / glow behind
        if layer.shadow.isOn, let first = parts.first, first.silhouette {
            var u = first.u
            let sh = layer.shadow
            u.box.x += Float(sh.dx); u.box.y += Float(sh.dy)
            u.geom.z += Float(sh.dx); u.geom.w += Float(sh.dy)
            u.shd = SIMD4(1, Float(sh.blur), 1, 0); u.shdc = linearColor(sh.color)
            u.pad.x = Float(sh.blur * 1.5 + 2)
            u.border.x = 0
            drawQuad(u, tex: first.tex, mask: first.maskTex, blend: .normal, pass: pass, frame: frame)
        }
        if layer.glow.isOn, let first = parts.first, first.silhouette {
            var u = first.u
            let g = layer.glow
            u.shd = SIMD4(2, Float(g.radius), Float(g.intensity), 0); u.shdc = linearColor(g.color)
            u.pad.x = Float(g.radius * 1.2 + 2)
            u.border.x = 0
            drawQuad(u, tex: first.tex, mask: first.maskTex, blend: .add, pass: pass, frame: frame)
        }
        for p in parts {
            if p.particles > 0 { drawParticles(p, additive: layer.blend == .normal ? p.additiveParticles : layer.blend != .normal, pass: pass) }
            else { drawQuad(p.u, tex: p.tex, mask: p.maskTex, blend: layer.blend, pass: pass, frame: frame) }
        }
    }

    private func drawQuad(_ uIn: LayerU, tex: MTLTexture?, mask: MTLTexture?, blend: BlendMode, pass: LayerPass, frame: SceneFrame) {
        var u = uIn
        var back: MTLTexture? = nil
        if blend == .overlay, u.shd.x == 0 {
            back = pass.backdrop(device)
            u.shd.w = 1
        }
        guard let e = pass.encoder(), let pso = layerPSO[(u.shd.x == 0) ? blend : (u.shd.x == 2 ? .add : .normal)] else { return }
        let usePSO = (blend == .overlay && back == nil) ? layerPSO[.normal]! : pso
        e.setRenderPipelineState(usePSO)
        e.setVertexBytes(&u, length: MemoryLayout<LayerU>.size, index: 0)
        e.setFragmentBytes(&u, length: MemoryLayout<LayerU>.size, index: 0)
        e.setFragmentTexture(tex ?? dummy, index: 0)
        e.setFragmentTexture(mask ?? dummy, index: 1)
        e.setFragmentTexture(back ?? dummy, index: 2)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        lastDrawCount += 1
    }

    private func drawParticles(_ p: Part, additive: Bool, pass: LayerPass) {
        guard let e = pass.encoder() else { return }
        var u = p.u
        e.setRenderPipelineState(additive ? particleAdd : particleAlpha)
        e.setVertexBytes(&u, length: MemoryLayout<LayerU>.size, index: 0)
        e.setScissorRect(MTLScissorRect(x: 0, y: 0, width: pass.target.width, height: pass.target.height))
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: p.particles)
        lastDrawCount += 1
    }

    // MARK: content preparation

    private func solidPart(_ c: RGBA, opacityMul: Double = 1) -> Part {
        var p = Part(); p.u.content.x = 2; p.u.c0 = linearColor(c, alphaMul: opacityMul); return p
    }

    private func prepare(_ layer: Layer, bw: Int, bh: Int, pass: LayerPass, frame: SceneFrame, scene: LayerScene, anim: AnimState, clock: AnimClock) -> [Part] {
        var uvRect = SIMD4<Float>(Float(layer.crop.l), Float(layer.crop.t), Float(1 - layer.crop.r), Float(1 - layer.crop.b))
        if layer.transform.flipX { uvRect = SIMD4(uvRect.z, uvRect.y, uvRect.x, uvRect.w) }
        if layer.transform.flipY { uvRect = SIMD4(uvRect.x, uvRect.w, uvRect.z, uvRect.y) }
        switch layer.kind {
        case .source(let ref0, let fit):
            var ref = ref0
            if ref == .slate, let intro = introPropId { ref = .prop(id: intro) }
            if ref == .slate { return slateParts(bw: bw, bh: bh, layer: layer) }
            guard let st = frame.srcs[ref] else {
                var out = [solidPart(RGBA(hex: 0x0D1418))]
                let label: String
                if case .device = ref { label = "Waiting for the phone's video…" } else { label = "Loading…" }
                if let sp = sprites.sprite(key: "label|\(label)|\(bw)x\(bh)", slot: layer.id + "#label", { Art.label(label, w: bw, h: bh).map { ($0, 0) } }) {
                    var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.silhouette = false; out.append(p)
                }
                return out
            }
            return [sourcePart(ref, st, fit: fit, layer: layer, bw: bw, bh: bh, frame: frame, pass: pass)]

        case .image(let spec):
            return imageParts(spec, layer: layer, bw: bw, bh: bh, uvRect: uvRect)

        case .shape(let sp):
            return shapeParts(sp, layer: layer, bw: bw, bh: bh, uvRect: uvRect)

        case .text(let st):
            let raw = frame.vars.resolve(st.string, defaults: scene.variableDefaults)
            var s = st.allCaps ? raw.uppercased() : raw
            if anim.typewriter < 0.9999 {
                let n = Int((Double(s.count) * anim.typewriter).rounded(.up))
                s = String(s.prefix(max(0, n)))
            }
            guard !s.isEmpty else { return [] }
            var style = st; style.string = ""
            let key = "txt|\(style.hashValue)|\(s)|\(bw)x\(bh)"
            guard let sp = sprites.sprite(key: key, slot: layer.id, { SpriteRaster.text(st, string: s, w: min(bw, SpriteRaster.maxSide), h: min(bh, SpriteRaster.maxSide)).map { ($0, 0) } }) else { return [] }
            var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.u.uv = uvRect; return [p]

        case .group(let kids):
            let gw = min(4096, bw), gh = min(4096, bh)
            pass.end()
            let gtex = frame.fr.tex(device, gw, gh)
            let gp = LayerPass(frame.cb, gtex, frame.fr)
            _ = gp.encoder()
            drawLayers(kids, clock: clock, scene: scene, pass: gp, frame: frame)
            gp.end()
            var p = Part(); p.u.content.x = 5; p.tex = gtex; p.u.uv = uvRect; return [p]

        case .effect(let spec):
            if let adv = spec.advanced { return advancedParts(spec, adv, clock: clock) }
            return effectParts(spec, layer: layer, bw: bw, bh: bh, frame: frame, scene: scene, uvRect: uvRect)

        case .teamBoard(let spec):
            return teamBoardParts(spec, layer: layer, bw: bw, bh: bh, frame: frame, scene: scene, uvRect: uvRect)
        }
    }

    // MARK: team status board

    /// Per-layer cross-fade state of the rows sprite and scroll phase anchor (render thread only).
    private var boardFades: [String: TeamBoardFade] = [:]
    private var boardScrolls: [String: (state: TeamBoardScroll.State, seen: Double)] = [:]

    /// The board is three cached sprites, rasterised off the render thread: back (background + header, layer size), rows (the
    /// whole list, re-rasterised only when the data changes; a change cross-fades old -> new) and front (the gold frame).
    /// The rows sprite is drawn into the table viewport with a uv window (content kind 9: clipped, soft fade at the edges);
    /// when the list overflows, the window slides (TeamBoardScroll, a pure function of time + a phase anchor) -- no per-frame
    /// CoreGraphics. The strip under the header (social handle / match title) is two more cached sprites cross-faded in place.
    private func teamBoardParts(_ spec: TeamBoardSpec, layer: Layer, bw: Int, bh: Int, frame: SceneFrame, scene: LayerScene, uvRect: SIMD4<Float>) -> [Part] {
        let data = TeamBoardHub.shared.data(for: spec)
        let w = min(bw, SpriteRaster.maxSide), h = min(bh, SpriteRaster.maxSide)
        let players = spec.playersPerTeam
        let urls = Array(Set(data.teams.compactMap(\.logoURL)))
        let logoVer = urls.isEmpty ? 0 : TeamBoardArt.Logos.shared.currentVersion
        let L = TeamBoardLayout(size: CGSize(width: w, height: h), rows: data.teams.count, scroll: spec.autoScroll)
        let size = "\(w)x\(h)|\(spec.autoScroll)"
        var out: [Part] = []
        let now = frame.time
        func full(_ sp: SpriteStore.Sprite?) -> Part? {
            guard let sp else { return nil }
            var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.u.uv = uvRect; return p
        }
        // back: background, brand header, table head, dark table area
        let backKey = "tbb|\(size)|\(data.stale)"
        if let p = full(sprites.sprite(key: backKey, slot: layer.id + "#tbb", { TeamBoardArt.backImage(L, stale: data.stale, w: w, h: h).map { ($0, 0) } })) { out.append(p) }

        // rows: one tall sprite per data state (meta = its content height in board px)
        var rowsData = data; rowsData.title = ""; rowsData.stale = false
        let rowsKey = "tbr|\(rowsData.hashValue)|\(players)|\(logoVer)|\(size)"
        let rowsL = L
        _ = sprites.sprite(key: rowsKey, slot: layer.id + "#tbr") {
            let logos = urls.isEmpty ? [:] : TeamBoardArt.Logos.shared.images(for: urls)
            return TeamBoardArt.rowsImage(rowsData, players: players, rowsL, w: w, logos: logos).map { ($0, Double(rowsL.contentHeightPx)) }
        }
        let vp = L.viewportRect
        let vh = Double(vp.height)
        let speed = TeamBoardScroll.speed(boardHeight: CGFloat(h), factor: spec.scrollSpeed)
        let fadePx = TeamBoardScroll.fade(boardHeight: CGFloat(h))
        // the scroll position follows the shown list (its travel); stills: a pure function of time
        func travel(_ sp: SpriteStore.Sprite) -> Double { max(0, sp.meta - vh) }
        func offset(for D: Double) -> Double {
            if sprites.sync { return TeamBoardScroll.offset(time: now, travel: D, speed: speed) }
            // a board that (re)appears starts at the top with the 3 s hold; on air it keeps its phase across data changes
            var prev = boardScrolls[layer.id].map { abs(now - $0.seen) > 0.5 ? TeamBoardScroll.State() : $0.state } ?? TeamBoardScroll.State()
            prev = prev.retarget(travel: D, speed: speed, time: now)
            boardScrolls[layer.id] = (prev, now)
            return prev.offset(now)
        }
        let sy = Float(Double(bh) / Double(h))
        func rowsPart(_ sp: SpriteStore.Sprite, offset o: Double, alpha: Double) -> Part {
            let hc = max(1, sp.meta), D = travel(sp)
            let oo = min(max(0, o), D)
            var p = Part(); p.u.content.x = 9; p.tex = sp.tex; p.silhouette = false; p.alpha = alpha
            p.u.lb = SIMD4(0, Float(vp.minY / CGFloat(h)), 1, Float(vp.maxY / CGFloat(h)))
            p.u.uv = SIMD4(uvRect.x, Float(oo / hc), uvRect.z, Float((oo + vh) / hc))
            // soft edges only where rows are hidden beyond them (none at rest at the top / bottom)
            if D > 0 {
                p.u.ext0 = SIMD4(Float(fadePx) * sy, Float(fadePx) * sy, Float(min(1, oo / fadePx)), Float(min(1, (D - oo) / fadePx)))
            }
            return p
        }
        if sprites.sync {
            if let sp = sprites.peek(rowsKey) { out.append(rowsPart(sp, offset: offset(for: travel(sp)), alpha: 1)) }
        } else {
            let st = (boardFades[layer.id] ?? TeamBoardFade()).step(want: rowsKey, ready: sprites.peek(rowsKey) != nil, time: now)
            boardFades[layer.id] = st
            let shown = st.shown.flatMap { sprites.peek($0) }
            let o = shown.map { offset(for: travel($0)) } ?? 0
            if let from = st.from, let sp = sprites.peek(from) { out.append(rowsPart(sp, offset: o, alpha: 1)) }
            if let sp = shown { out.append(rowsPart(sp, offset: o, alpha: st.mix(time: now))) }
        }
        // front: the gold frame over the rows
        if var p = full(sprites.sprite(key: "tbf|\(size)", slot: layer.id + "#tbf", { TeamBoardArt.frontImage(L, w: w, h: h).map { ($0, 0) } })) {
            p.silhouette = false; out.append(p)
        }
        // strip under the header: social handle <-> match title, cross-faded (each slide is one cached sprite)
        let slides = TeamBoardCarousel.slides(spec, data: data, vars: frame.vars, defaults: scene.variableDefaults)
        guard !slides.isEmpty else { return out }
        let tr = L.titleRect
        let tw = max(8, Int(tr.width.rounded())), th = max(8, Int(tr.height.rounded()))
        let lb = SIMD4<Float>(Float(tr.minX / CGFloat(w)), Float(tr.minY / CGFloat(h)), Float(tr.maxX / CGFloat(w)), Float(tr.maxY / CGFloat(h)))
        let cs = TeamBoardCarousel.state(time: now, count: slides.count, interval: spec.carouselInterval)
        func slidePart(_ s: TeamBoardSlide, alpha: Double) -> Part? {
            guard let sp = sprites.sprite(key: "tbs|\(s.key)|\(tw)x\(th)", slot: layer.id + "#tbs" + s.key, { TeamBoardArt.slide(s, w: tw, h: th).map { ($0, 0) } }) else { return nil }
            var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.silhouette = false; p.alpha = alpha
            p.u.lb = lb
            p.u.uv = SIMD4(0, 0, 1, 1)
            return p
        }
        if let prev = cs.previous, cs.progress < 1 {
            let e = cs.progress
            if let p = slidePart(slides[prev], alpha: 1 - e) { out.append(p) }
            if let p = slidePart(slides[cs.index], alpha: e) { out.append(p) }
        } else if let p = slidePart(slides[cs.index], alpha: 1) { out.append(p) }
        // warm the next slide so the switch never pops in
        if slides.count > 1 { _ = slidePart(slides[(cs.index + 1) % slides.count], alpha: 0) }
        return out
    }

    // MARK: sources

    private func slateParts(bw: Int, bh: Int, layer: Layer) -> [Part] {
        var g = solidPart(RGBA.black)
        g.u.content.x = 4
        g.u.c0 = SIMD4(15.0 / 255, 59.0 / 255, 58.0 / 255, 1)
        g.u.c1 = SIMD4(4.0 / 255, 7.0 / 255, 10.0 / 255, 1)
        g.u.grad = SIMD4(0, 0, 0.5, 0.5)
        let outer = Double(max(bw, bh)) * 0.7
        g.u.mask2 = SIMD4(0, Float(outer / (hypot(Double(bw), Double(bh)) / 2)), 30, 0)
        var out = [g]
        let title = slateTitle, text = slateText
        if let sp = sprites.sprite(key: "slate|\(title)|\(text)|\(bw)x\(bh)", slot: layer.id + "#slate", { Art.slateText(title: title, text: text, w: bw, h: bh).map { ($0, 0) } }) {
            var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.silhouette = false; out.append(p)
        }
        return out
    }

    /// view-space (flip, quarter turns) -> source-texture normalised coordinate, same order as fetch() in the shader.
    private func viewToSource(_ p: CGPoint, flip: Bool, turns: Int) -> CGPoint {
        var d = p
        if flip { d.x = 1 - d.x }
        switch turns {
        case 1: d = CGPoint(x: d.y, y: 1 - d.x)
        case 2: d = CGPoint(x: 1 - d.x, y: 1 - d.y)
        case 3: d = CGPoint(x: 1 - d.y, y: d.x)
        default: break
        }
        return d
    }

    private func sourcePart(_ ref: SourceRef, _ st: SrcTex, fit: SourceFit, layer: Layer, bw: Int, bh: Int, frame: SceneFrame, pass: LayerPass) -> Part {
        let xf = transformFor(ref)
        let turns = xf.quarterTurns, odd = turns % 2 == 1
        let ew = CGFloat(odd ? st.h : st.w), eh = CGFloat(odd ? st.w : st.h)
        let cr = layer.crop
        let cw = max(1, ew * CGFloat(1 - cr.l - cr.r)), ch = max(1, eh * CGFloat(1 - cr.t - cr.b))
        let ox = ew * CGFloat(cr.l), oy = eh * CGFloat(cr.t)
        let boxW = CGFloat(bw), boxH = CGFloat(bh)
        var contain = fit == .fit
        if case .image = ref { contain = true }
        var R: CGRect, D: CGSize
        var lb = SIMD4<Float>(0, 0, 1, 1)
        var bars = SIMD4<Float>.zero
        if contain {
            let sc = min(boxW / cw, boxH / ch)
            let dw = (cw * sc).rounded(), dh = (ch * sc).rounded()
            R = CGRect(x: ox, y: oy, width: cw, height: ch); D = CGSize(width: dw, height: dh)
            let x0 = ((boxW - dw) / 2).rounded(), y0 = ((boxH - dh) / 2).rounded()
            lb = SIMD4(Float(x0 / boxW), Float(y0 / boxH), Float((x0 + dw) / boxW), Float((y0 + dh) / boxH))
            bars = SIMD4(6.0 / 255, 9.0 / 255, 12.0 / 255, 1)
        } else if fit == .stretch {
            R = CGRect(x: ox, y: oy, width: cw, height: ch); D = CGSize(width: boxW, height: boxH)
        } else {
            let s = max(boxW / cw, boxH / ch)
            let vw = boxW / s, vh = boxH / s
            R = CGRect(x: ox + (cw - vw) / 2, y: oy + (ch - vh) / 2, width: vw, height: vh); D = CGSize(width: boxW, height: boxH)
        }
        var p = Part()
        p.u.content.x = 0
        var tex = st.tex
        let sx = D.width / R.width, sy = D.height / R.height
        var uv = SIMD4<Float>(0, 0, 1, 1)
        var upscale: CGFloat = 1
        if sx < 0.999 && sy < 0.999 {
            // Lanczos downscale of the visible region into a pooled texture of the destination size (source orientation)
            let a = viewToSource(CGPoint(x: R.minX / ew, y: R.minY / eh), flip: xf.flip, turns: turns)
            let b = viewToSource(CGPoint(x: R.maxX / ew, y: R.maxY / eh), flip: xf.flip, turns: turns)
            let rx = min(a.x, b.x) * CGFloat(st.w), ry = min(a.y, b.y) * CGFloat(st.h)
            let rw = abs(a.x - b.x) * CGFloat(st.w), rh = abs(a.y - b.y) * CGFloat(st.h)
            let dw = max(1, Int(odd ? D.height : D.width)), dh = max(1, Int(odd ? D.width : D.height))
            let dst = frame.fr.tex(device, dw, dh)
            let scx = Double(CGFloat(dw) / rw), scy = Double(CGFloat(dh) / rh)
            var t = MPSScaleTransform(scaleX: scx, scaleY: scy, translateX: -Double(rx) * scx, translateY: -Double(ry) * scy)
            pass.end()
            withUnsafePointer(to: &t) { ptr in
                lanczos.scaleTransform = ptr
                lanczos.encode(commandBuffer: frame.cb, sourceTexture: st.tex, destinationTexture: dst)
                lanczos.scaleTransform = nil
            }
            tex = dst
        } else {
            uv = SIMD4(Float(R.minX / ew), Float(R.minY / eh), Float(R.maxX / ew), Float(R.maxY / eh))
            let s = max(sx, sy)
            if abs(s - 1) > 0.001 && s > 1 { upscale = s }
        }
        if upscale > 1, upscaleMode != 0 {
            p.u.content.x = 6
            p.u.content.y = upscaleMode == 1 ? 0 : upscaleMode == 3 ? 0.8 : upscaleMode == 4 ? 1.2 : Float(upscale >= 2 ? 0.5 : upscale >= 1.25 ? 0.35 : 0.2)
        }
        var flipX = layer.transform.flipX, flipY = layer.transform.flipY
        if ref == .camera { flipX.toggle() }               // mirror the webcam
        if flipX { uv = SIMD4(uv.z, uv.y, uv.x, uv.w) }
        if flipY { uv = SIMD4(uv.x, uv.w, uv.z, uv.y) }
        p.u.uv = uv; p.u.lb = lb; p.u.bars = bars
        p.u.content.z = xf.flip ? 1 : 0; p.u.content.w = Float(turns)
        p.tex = tex
        return p
    }

    // MARK: images

    nonisolated static func stretch(_ img: CGImage, w: Int, h: Int) -> CGImage? {
        Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
            c.interpolationQuality = .high
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    nonisolated static func place(_ img: CGImage, w: Int, h: Int, fit: SourceFit) -> CGImage? {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let W = CGFloat(w), H = CGFloat(h)
        var r = CGRect(x: 0, y: 0, width: W, height: H)
        switch fit {
        case .stretch: break
        case .fit: let s = min(W / iw, H / ih); r = CGRect(x: (W - iw * s) / 2, y: (H - ih * s) / 2, width: iw * s, height: ih * s)
        case .fill: let s = max(W / iw, H / ih); r = CGRect(x: (W - iw * s) / 2, y: (H - ih * s) / 2, width: iw * s, height: ih * s)
        }
        return Art.image(width: W, height: H, scale: 1) { c in
            c.interpolationQuality = .high
            c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
            c.draw(img, in: CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height))
        }
    }

    private func imageParts(_ spec: ImageSpec, layer: Layer, bw: Int, bh: Int, uvRect: SIMD4<Float>) -> [Part] {
        let fit = spec.fit ?? .fit
        let w = min(bw, SpriteRaster.maxSide), h = min(bh, SpriteRaster.maxSide)
        var sprite: SpriteStore.Sprite?
        if let pid = spec.propId, let l = overlayImages.image(propId: pid) {
            let img = l.image
            sprite = sprites.sprite(key: "img|\(pid)|\(l.version)|\(w)x\(h)|\(fit.rawValue)", slot: layer.id) { Self.place(img, w: w, h: h, fit: fit).map { ($0, 0) } }
        } else if let bid = spec.builtin {
            let theme = spec.theme
            sprite = sprites.sprite(key: "bi|\(bid)|\(theme ?? "")|\(w)x\(h)|\(fit.rawValue)", slot: layer.id) {
                guard let a = BuiltinAssets.asset(bid) else { return nil }
                let sc = max(1, min(a.maxScale, ceil(CGFloat(w) / max(1, a.size.width))))
                let img = a.image(scale: sc, theme: theme.map { PropTheme.named($0) } ?? .ember)
                return Self.place(img, w: w, h: h, fit: fit).map { ($0, 0) }
            }
        }
        guard let sp = sprite else { return [] }
        var p = Part(); p.u.content.x = 1; p.tex = sp.tex; p.u.uv = uvRect; return [p]
    }

    // MARK: shapes

    private func shapeParts(_ sp: ShapeSpec, layer: Layer, bw: Int, bh: Int, uvRect: SIMD4<Float>) -> [Part] {
        let simpleKind = sp.kind == .rect || sp.kind == .roundedRect || sp.kind == .ellipse
        let gradOK: Bool = {
            guard let g = sp.fill.gradient else { return true }
            return g.stops.count == 2 && g.stops[0].pos <= 0.001 && g.stops[1].pos >= 0.999
        }()
        if simpleKind, sp.stroke.width <= 0, gradOK {
            var p = Part()
            if sp.kind == .ellipse { p.ownMask = true; p.u.mask.x = 2 }
            if sp.kind == .roundedRect { p.ownMask = true; p.u.mask.x = 0; p.u.mask.y = Float(sp.cornerRadius) }
            if let g = sp.fill.gradient {
                p.u.c0 = linearColor(g.stops[0].color); p.u.c1 = linearColor(g.stops[1].color)
                if g.radial {
                    p.u.content.x = 4
                    p.u.grad = SIMD4(0, 0, Float(g.cx), Float(g.cy))
                    p.u.mask2.y = Float(g.radius)
                } else {
                    p.u.content.x = 3
                    let a = g.angle * .pi / 180
                    p.u.grad = SIMD4(Float(cos(a)), Float(sin(a)), 0, 0)
                }
            } else { p.u.content.x = 2; p.u.c0 = linearColor(sp.fill.color) }
            return [p]
        }
        var style = sp; style.fill = sp.fill
        let key = "shp|\(sp.hashValue)|\(bw)x\(bh)"
        guard let s = sprites.sprite(key: key, slot: layer.id, { SpriteRaster.shape(sp, w: min(bw, SpriteRaster.maxSide), h: min(bh, SpriteRaster.maxSide)).map { ($0, 0) } }) else { return [] }
        var p = Part(); p.u.content.x = 1; p.tex = s.tex; p.u.uv = uvRect; return [p]
    }

    // MARK: effects

    private func effectParts(_ spec: EffectSpec, layer: Layer, bw: Int, bh: Int, frame: SceneFrame, scene: LayerScene, uvRect: SIMD4<Float>) -> [Part] {
        var p = Part()
        p.u.c0 = linearColor(spec.color); p.u.c1 = linearColor(spec.color2)
        p.u.eff0 = SIMD4(0, Float(spec.intensity), Float(spec.speed), Float(spec.size))
        p.u.eff1 = SIMD4(Float(spec.seed), Float(spec.thickness), Float(spec.angle * .pi / 180), Float(spec.count))
        switch spec.kind {
        case .fireEmitter, .embers, .smoke, .sparks:
            p.u.eff0.x = Float([EffectKind.fireEmitter, .embers, .smoke, .sparks].firstIndex(of: spec.kind) ?? 0)
            p.particles = max(1, min(6000, spec.count))
            p.additiveParticles = spec.kind != .smoke
            p.silhouette = false
            return [p]
        case .scanlines: p.u.eff0.x = 10
        case .vignette: p.u.eff0.x = 11
        case .filmGrain: p.u.eff0.x = 12
        case .lightSweep: p.u.eff0.x = 13
        case .pulsingGlow: p.u.eff0.x = 14
        case .hudCornerBrackets: p.u.eff0.x = 15
        case .radarSweep: p.u.eff0.x = 16
        case .animatedGradient: p.u.eff0.x = 17
        case .glitch: p.u.eff0.x = 18
        case .lightning: p.u.eff0.x = 19
        case .ticker:
            let text = frame.vars.resolve(spec.text, defaults: scene.variableDefaults)
            guard !text.isEmpty else { return [] }
            let fs = CGFloat(spec.fontSize), color = spec.color, minW = bw, h = bh
            guard let sp = sprites.sprite(key: "tick|\(text)|\(fs)|\(color.hashValue)|\(minW)x\(h)", slot: layer.id, { SpriteRaster.tickerStrip(text: text, fontSize: fs, color: color, h: h, minWidth: minW).map { ($0.0, Double($0.1)) } }) else { return [] }
            let period = max(1, sp.meta)
            let off = (frame.time * 120 * spec.speed).truncatingRemainder(dividingBy: period)
            let sw = Double(sp.tex.width)
            p.u.content.x = 7; p.tex = sp.tex
            p.u.uv = SIMD4(Float(off / sw), 0, Float((off + Double(bw)) / sw), 1)
            p.silhouette = false
            return [p]
        case .countdown, .killfeedLine:
            let text = frame.vars.resolve(spec.text.isEmpty ? (spec.kind == .countdown ? "{{timer}}" : "") : spec.text, defaults: scene.variableDefaults)
            guard !text.isEmpty else { return [] }
            let key: String
            let make: () -> (CGImage, Double)?
            if spec.kind == .countdown {
                var st = TextStyle(text, font: "Menlo", size: spec.fontSize, weight: 800, color: spec.color)
                st.shadow = Shadow(color: RGBA(0, 0, 0, 0.6), blur: 6, dx: 0, dy: 3)
                key = "cd|\(st.hashValue)|\(text)|\(bw)x\(bh)"
                let s2 = st
                make = { SpriteRaster.text(s2, string: text, w: min(bw, SpriteRaster.maxSide), h: min(bh, SpriteRaster.maxSide)).map { ($0, 0) } }
            } else {
                key = "kf|\(text)|\(spec.fontSize)|\(spec.color.hashValue)|\(spec.color2.hashValue)|\(bw)x\(bh)"
                let fs = CGFloat(spec.fontSize), a = spec.color, tc = spec.color2
                make = { SpriteRaster.killfeedLine(text: text, accent: a, textColor: RGBA.white.with(alpha: tc.a > 0 ? 1 : 1), fontSize: fs, w: bw, h: bh).map { ($0, 0) } }
            }
            guard let sp = sprites.sprite(key: key, slot: layer.id, make) else { return [] }
            p.u.content.x = 1; p.tex = sp.tex; p.u.uv = uvRect
            return [p]
        case .animatedGradient: p.u.eff0.x = 17
        }
        p.u.content.x = 8
        return [p]
    }

    // MARK: advanced (OPUS) effects

    /// GPU-only advanced effects: no sprites, one quad (fragment effects) or one instanced draw (particles).
    private func advancedParts(_ spec: EffectSpec, _ fx: AdvancedFX, clock: AnimClock) -> [Part] {
        guard let local = AdvancedTiming.localTime(fx, spec: spec, sinceTake: clock.sinceTake) else { return [] }
        var p = Part()
        p.u.c0 = linearColor(spec.color); p.u.c1 = linearColor(spec.color2)
        p.u.eff0 = SIMD4(0, Float(spec.intensity), Float(spec.speed), Float(spec.size))
        p.u.eff1 = SIMD4(Float(spec.seed), Float(spec.thickness), Float(spec.angle * .pi / 180), Float(spec.count))
        p.u.ext0 = SIMD4(Float(local), 1, 0, 0)
        p.silhouette = false
        if let pk = fx.particleKind {
            p.u.eff0.x = Float(pk)
            p.particles = max(1, min(8000, spec.count))
            p.additiveParticles = fx.additive
            return [p]
        }
        p.u.eff0.x = Float(fx.fragmentKind ?? 0)
        p.u.content.x = 8
        return [p]
    }

    // MARK: standalone helpers

    func encodeBlit(from a: MTLTexture, to b: MTLTexture, cb: MTLCommandBuffer) {
        guard let e = cb.makeBlitCommandEncoder() else { return }
        e.copy(from: a, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: a.width, height: a.height, depth: 1),
               to: b, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        e.endEncoding()
    }
    /// Draws trigger layers (kill pop-ups, flashes) on top of an existing texture with their own animation clock.
    func drawOverlay(_ layers: [Layer], clock: AnimClock, onto tex: MTLTexture, frame: SceneFrame) {
        guard !layers.isEmpty else { return }
        let pass = LayerPass(frame.cb, tex, frame.fr, preserve: true)
        let scene = LayerScene(id: "trigger", name: "")
        drawLayers(layers, clock: clock, scene: scene, pass: pass, frame: frame)
        pass.end()
    }
    /// Draws one layer on top of an existing texture (stinger video, UI overlays).
    func drawStandalone(_ layer: Layer, onto tex: MTLTexture, frame: SceneFrame) {
        let pass = LayerPass(frame.cb, tex, frame.fr, preserve: true)
        let scene = LayerScene(id: "standalone", name: "")
        drawLayer(layer, clock: AnimClock(sinceShow: 1e6, sinceTake: 1e6, time: frame.time), scene: scene, pass: pass, frame: frame)
        pass.end()
    }

    // MARK: transitions

    /// Composites `a` (outgoing) and `b` (incoming) into `dst`. progress 0...1.
    func transition(_ kind: SceneTransitionKind, progress: Float, directionDeg: Double, a: MTLTexture, b: MTLTexture, into dst: MTLTexture, cb: MTLCommandBuffer) {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = dst; d.colorAttachments[0].loadAction = .dontCare; d.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: d) else { return }
        var u = TransU()
        let code: Float
        switch kind { case .slide: code = 2; case .zoom: code = 3; case .wipe: code = 4; case .lightWipe: code = 5; default: code = 1 }
        let r = directionDeg * .pi / 180
        u.p = SIMD4(code, progress, Float(cos(r)), Float(sin(r)))
        e.setRenderPipelineState(transitionPSO)
        e.setFragmentTexture(a, index: 0); e.setFragmentTexture(b, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<TransU>.size, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}

/// CPU mirror of the GPU particle hash (see `rnd` in LayerShaders.swift): every particle attribute is a pure function of
/// (seed, particle index, attribute key), so a seeded emitter renders identically every run.
enum ParticleMath {
    static func pcg(_ v: UInt32) -> UInt32 {
        let s = v &* 747796405 &+ 2891336453
        let w = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277803737
        return (w >> 22) ^ w
    }
    static func value(seed: UInt32, index: UInt32, key: UInt32) -> Float {
        Float(pcg(seed &* 9781 &+ index &* 6271 &+ key &* 1013 &+ 17)) / 4294967296
    }
}
