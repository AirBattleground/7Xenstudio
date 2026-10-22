// Zero-copy Metal compositor. Sources (IOSurface CVPixelBuffers) are mapped with CVMetalTextureCache, converted in-shader
// to linear BT.709 rgba16f, downscaled with MPSImageLanczosScale, blended in linear light, and encoded to a pooled
// IOSurface BGRA buffer tagged BT.709. Three frame-resource sets give triple-buffered command buffers.
import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo
import CoreGraphics

struct QuadU {
    var rect = SIMD4<Float>(0, 0, 0, 0)
    var uv = SIMD4<Float>(0, 0, 1, 1)
    var c0 = SIMD4<Float>(0, 0, 0, 1)
    var c1 = SIMD4<Float>(0, 0, 0, 1)
    var p = SIMD4<Float>(0, 0, 0, 1)     // kind, radius, border, opacity
    var q = SIMD4<Float>(0, 0, 0, 0)     // canvas w,h, r0, r1
}
private struct ConvU {
    var a = SIMD4<Float>(0, 1, 0.5, 1); var b = SIMD4<Float>(0.2126, 0.0722, 0, 0)       // b.z: transfer 0 BT.709, 1 sRGB, 2 gamma 2.2
    var m0 = SIMD4<Float>(1, 0, 0, 0), m1 = SIMD4<Float>(0, 1, 0, 0), m2 = SIMD4<Float>(0, 0, 1, 0)   // linear primaries -> BT.709
}
private struct VividU { var v = SIMD4<Float>(1, 0, 0, 0) }   // saturation, contrast, sharpen, on
/// Display P3 (D65) -> BT.709/sRGB primaries, linear light.
private let p3ToRec709: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
    SIMD4<Float>(1.2249401, -0.2249404, 0, 0), SIMD4<Float>(-0.0420569, 1.0420571, 0, 0), SIMD4<Float>(-0.0196376, -0.0786361, 1.0982735, 0))
/// BT.2020 -> BT.709, linear light.
private let rec2020ToRec709: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
    SIMD4<Float>(1.6604910, -0.5876411, -0.0728499, 0), SIMD4<Float>(-0.1245505, 1.1328999, -0.0083494, 0), SIMD4<Float>(-0.0181508, -0.1005789, 1.1187297, 0))

struct FrameRequest {
    var program: Scene?
    var previous: Scene?          // outgoing scene while mix < 1
    var mix: Float = 1            // 0 = previous, 1 = program
    var overlays: Overlays?
    var liveSince: Date?
    var time: Double = 0          // seconds, drives the ticker
    var previewScene: Scene?
}
struct FrameTargets {
    var output: CVPixelBuffer
    var programPreview: CVPixelBuffer?
    var scenePreview: CVPixelBuffer?
}

private final class TexKey: Hashable {
    let w: Int, h: Int, f: UInt
    init(_ w: Int, _ h: Int, _ f: MTLPixelFormat) { self.w = w; self.h = h; self.f = f.rawValue }
    static func == (a: TexKey, b: TexKey) -> Bool { a.w == b.w && a.h == b.h && a.f == b.f }
    func hash(into h: inout Hasher) { h.combine(w); h.combine(self.h); h.combine(f) }
}

/// Per in-flight-frame resources: pooled textures and objects that must outlive the GPU work.
private final class FrameRes {
    var pool: [TexKey: [MTLTexture]] = [:]
    var used: [TexKey: Int] = [:]
    var holds: [Any] = []
    func reset() { used.removeAll(keepingCapacity: true); holds.removeAll(keepingCapacity: true) }
    func tex(_ dev: MTLDevice, _ w: Int, _ h: Int, _ f: MTLPixelFormat = .rgba16Float) -> MTLTexture {
        let k = TexKey(w, h, f)
        let i = used[k, default: 0]; used[k] = i + 1
        if let t = pool[k], i < t.count { return t[i] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
        let t = dev.makeTexture(descriptor: d)!
        pool[k, default: []].append(t)
        return t
    }
}

private struct SrcTex { var tex: MTLTexture; var w: Int; var h: Int }
private enum Item {
    case slot(QuadU, MTLTexture?)
    case sprite(QuadU, MTLTexture, MTLScissorRect?)
}

final class MetalCompositor {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let width: Int, height: Int
    let S: CGFloat
    weak var provider: SourceProvider?
    var slateTitle = "7XEN STUDIO"
    var slateText = "Starting soon"

    private let texCache: CVMetalTextureCache
    /// CVMetalTextureCache is not safe against a texture being finalized (GPU completion thread) while another is created (render thread): crash seen in bufferBackingNotInUse.
    private let texCacheLock = NSLock()
    private let convNV12, convBGRA: MTLComputePipelineState
    private let slotPSO, spritePSO, mixPSO, outPSO: MTLRenderPipelineState
    private let lanczos: MPSImageLanczosScale
    private let dummy: MTLTexture
    private var frames: [FrameRes] = (0..<3).map { _ in FrameRes() }
    private var frameIdx = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var lastBuffers: [SourceRef: CVPixelBuffer] = [:]
    private var sprites: [String: MTLTexture] = [:]
    /// measurement aid: 0 = plain bilinear upscale (old behaviour), 1 = Catmull-Rom only, 2 = Catmull-Rom + limited sharpening (default)
    var debugUpscaleMode = Int(ProcessInfo.processInfo.environment["STUDIO_UPSCALE_MODE"] ?? "") ?? 2
    private let cfgLock = NSLock()
    private var _transforms: [SourceRef: SourceTransform] = [:]
    private var _vivid = VividLevel.off
    /// Per-source rotation / flip (set from the UI thread).
    func setTransforms(_ t: [SourceRef: SourceTransform]) { cfgLock.lock(); _transforms = t; cfgLock.unlock() }
    var vivid: VividLevel { get { cfgLock.lock(); defer { cfgLock.unlock() }; return _vivid } set { cfgLock.lock(); _vivid = newValue; cfgLock.unlock() } }
    private func transform(_ r: SourceRef) -> SourceTransform { cfgLock.lock(); defer { cfgLock.unlock() }; return _transforms[r] ?? .identity }
    private func vividParams(sharpen: Bool) -> VividU {
        switch vivid {
        case .off: return VividU()
        case .subtle: return VividU(v: SIMD4(1.08, 0.20, sharpen ? 0.20 : 0, 1))
        case .strong: return VividU(v: SIMD4(1.16, 0.35, sharpen ? 0.35 : 0, 1))
        }
    }
    let overlayImages = OverlayImageCache()
    private let outPool: CVPixelBufferPool
    let previewWidth: Int, previewHeight: Int
    private let previewPool: CVPixelBufferPool

    init?(width: Int = studioWidth, height: Int = studioHeight, previewWidth: Int = 480, previewHeight: Int = 270) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.width = width; self.height = height
        S = CGFloat(width) / LayoutMath.designW
        self.previewWidth = previewWidth; self.previewHeight = previewHeight
        var tc: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, dev, nil, &tc) == kCVReturnSuccess, let tcache = tc else { return nil }
        texCache = tcache
        do {
            let lib = try dev.makeLibrary(source: metalShaderSource, options: nil)
            convNV12 = try dev.makeComputePipelineState(function: lib.makeFunction(name: "convNV12")!)
            convBGRA = try dev.makeComputePipelineState(function: lib.makeFunction(name: "convBGRA")!)
            func pso(_ v: String, _ f: String, _ fmt: MTLPixelFormat, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
                let a = d.colorAttachments[0]!
                a.pixelFormat = fmt
                if blend {
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try dev.makeRenderPipelineState(descriptor: d)
            }
            slotPSO = try pso("vsQuad", "fsSlot", .rgba16Float, blend: true)
            spritePSO = try pso("vsQuad", "fsSprite", .rgba16Float, blend: true)
            mixPSO = try pso("vsFull", "fsMix", .rgba16Float, blend: false)
            outPSO = try pso("vsFull", "fsOut", .bgra8Unorm, blend: false)
        } catch { NSLog("MetalCompositor: shader build failed: \(error)"); return nil }
        lanczos = MPSImageLanczosScale(device: dev)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        dummy = dev.makeTexture(descriptor: dd)!
        func makePool(_ w: Int, _ h: Int, min: Int) -> CVPixelBufferPool? {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: min] as CFDictionary, attrs as CFDictionary, &p)
            return p
        }
        guard let op = makePool(width, height, min: 4), let pp = makePool(previewWidth, previewHeight, min: 3) else { return nil }
        outPool = op; previewPool = pp
    }

    // MARK: buffers

    private func tagged(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pb
    }
    private func buffer(_ pool: CVPixelBufferPool, threshold: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pb) == kCVReturnSuccess, let b = pb else { return nil }
        return tagged(b)
    }
    func makeOutputBuffer() -> CVPixelBuffer? { buffer(outPool, threshold: 10) }
    func makePreviewBuffer() -> CVPixelBuffer? { buffer(previewPool, threshold: 8) }

    private func mapTexture(_ pb: CVPixelBuffer, plane: Int, _ fmt: MTLPixelFormat, usage: MTLTextureUsage, fr: FrameRes) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var cvt: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        texCacheLock.lock()
        let created = CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pb, attrs, fmt, w, h, plane, &cvt)
        texCacheLock.unlock()
        guard created == kCVReturnSuccess, let c = cvt, let t = CVMetalTextureGetTexture(c) else { return nil }
        fr.holds.append(c)
        return t
    }

    // MARK: sprites (CoreText/CoreGraphics art cached as textures)

    private func sprite(_ key: String, _ make: () -> CGImage?) -> MTLTexture? {
        if let t = sprites[key] { return t }
        guard let cg = make(), let data = cg.dataProvider?.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cg.width, height: cg.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, cg.width, cg.height), mipmapLevel: 0, withBytes: CFDataGetBytePtr(data), bytesPerRow: cg.bytesPerRow)
        if sprites.count > 80 { sprites.removeAll() }
        sprites[key] = t
        return t
    }

    // MARK: render

    /// Encodes and commits one frame. Returns false when all three frames are still in flight (caller should hold the last frame).
    /// `completion` runs on a Metal thread with the GPU time in milliseconds.
    @discardableResult
    func render(_ req: FrameRequest, to targets: FrameTargets, completion: @escaping (Double) -> Void) -> Bool {
        guard inflight.wait(timeout: .now()) == .success else { return false }
        let fr = frames[frameIdx]; frameIdx = (frameIdx + 1) % frames.count
        fr.reset()
        guard let cb = queue.makeCommandBuffer() else { inflight.signal(); return false }

        // 1. gather + convert sources
        var scenes: [Scene?] = [req.program]
        let transitioning = req.mix < 1 && req.previous != nil
        if transitioning { scenes.append(req.previous) }
        if req.previewScene != nil { scenes.append(req.previewScene) }
        var refs = Set<SourceRef>()
        for s in scenes { for r in s?.slots ?? [] { if let r = r, r != .slate { refs.insert(r) } } }
        var srcs: [SourceRef: SrcTex] = [:]
        if let ce = cb.makeComputeCommandEncoder() {
            for r in refs {
                var pb: CVPixelBuffer? = provider?.source(for: r)?.latestFrame()
                if pb == nil { pb = lastBuffers[r] } else { lastBuffers[r] = pb }   // hold last frame on stall
                if let pb = pb, let st = convert(pb, fr: fr, ce: ce) { srcs[r] = st }
            }
            ce.endEncoding()
        }
        for k in lastBuffers.keys where !refs.contains(k) { lastBuffers[k] = nil }
        fr.holds.append(contentsOf: lastBuffers.values.map { $0 as Any })

        // 2. draw lists (encodes MPS downscales)
        let progList = drawList(req.program, srcs, fr, cb)
        let prevList = transitioning ? drawList(req.previous, srcs, fr, cb) : []
        let prevwList = req.previewScene != nil ? drawList(req.previewScene, srcs, fr, cb) : []
        let overlayList = overlayItems(req)

        // 3. passes
        let W = width, H = height
        let canvas = fr.tex(device, W, H)
        var final = canvas
        if transitioning {
            let a = fr.tex(device, W, H), b = fr.tex(device, W, H)
            pass(cb, a, clear: true) { self.encode(prevList, $0) }
            pass(cb, b, clear: true) { self.encode(progList, $0) }
            pass(cb, canvas, clear: false, pso: mixPSO) { e in
                e.setFragmentTexture(a, index: 0); e.setFragmentTexture(b, index: 1)
                var t = req.mix; e.setFragmentBytes(&t, length: 4, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else { pass(cb, canvas, clear: true) { self.encode(progList, $0) } }
        if !overlayList.isEmpty { pass(cb, final, clear: false, load: true) { self.encode(overlayList, $0) } }
        final = canvas
        if let outTex = mapTexture(targets.output, plane: 0, .bgra8Unorm, usage: [.renderTarget, .shaderRead], fr: fr) {
            presentPass(cb, final, into: outTex)
        }
        if let pp = targets.programPreview { previewPass(cb, final, pp, fr) }
        if let sp = targets.scenePreview, req.previewScene != nil {
            let pc = fr.tex(device, W, H)
            pass(cb, pc, clear: true) { self.encode(prevwList, $0) }
            previewPass(cb, pc, sp, fr)
        }
        let holds = fr
        cb.addCompletedHandler { [inflight, texCacheLock] c in
            let ms = (c.gpuEndTime - c.gpuStartTime) * 1000
            texCacheLock.lock(); holds.holds.removeAll(); texCacheLock.unlock()
            inflight.signal()
            completion(ms)
        }
        cb.commit()
        return true
    }

    private func pass(_ cb: MTLCommandBuffer, _ target: MTLTexture, clear: Bool, load: Bool = false, pso: MTLRenderPipelineState? = nil, _ body: (MTLRenderCommandEncoder) -> Void) {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = (clear && !load) ? .clear : (load ? .load : .dontCare)
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        d.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: d) else { return }
        if let p = pso { e.setRenderPipelineState(p) }
        body(e)
        e.endEncoding()
    }
    private func encode(_ items: [Item], _ e: MTLRenderCommandEncoder) {
        for it in items {
            switch it {
            case .slot(var u, let t):
                e.setRenderPipelineState(slotPSO)
                e.setVertexBytes(&u, length: MemoryLayout<QuadU>.size, index: 0)
                e.setFragmentBytes(&u, length: MemoryLayout<QuadU>.size, index: 0)
                e.setFragmentTexture(t ?? dummy, index: 0)
                e.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            case .sprite(var u, let t, let sc):
                e.setRenderPipelineState(spritePSO)
                e.setVertexBytes(&u, length: MemoryLayout<QuadU>.size, index: 0)
                e.setFragmentBytes(&u, length: MemoryLayout<QuadU>.size, index: 0)
                e.setFragmentTexture(t, index: 0)
                e.setScissorRect(sc ?? MTLScissorRect(x: 0, y: 0, width: width, height: height))
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }
    private func presentPass(_ cb: MTLCommandBuffer, _ src: MTLTexture, into dst: MTLTexture, sharpen: Bool = true) {
        var vu = vividParams(sharpen: sharpen)
        pass(cb, dst, clear: false, pso: outPSO) { e in
            e.setFragmentTexture(src, index: 0)
            e.setFragmentBytes(&vu, length: MemoryLayout<VividU>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
    private func previewPass(_ cb: MTLCommandBuffer, _ canvas: MTLTexture, _ pb: CVPixelBuffer, _ fr: FrameRes) {
        let small = fr.tex(device, previewWidth, previewHeight)
        lanczos.scaleTransform = nil
        lanczos.encode(commandBuffer: cb, sourceTexture: canvas, destinationTexture: small)
        if let t = mapTexture(pb, plane: 0, .bgra8Unorm, usage: [.renderTarget, .shaderRead], fr: fr) { presentPass(cb, small, into: t, sharpen: false) }
    }

    // MARK: conversion

    private func convert(_ pb: CVPixelBuffer, fr: FrameRes, ce: MTLComputeCommandEncoder) -> SrcTex? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return nil }
        let out = fr.tex(device, w, h)
        var cu = ConvU()
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: w, height: h, depth: 1)
        switch fmt {
        case kCVPixelFormatType_32BGRA:
            guard let t = mapTexture(pb, plane: 0, .bgra8Unorm, usage: .shaderRead, fr: fr) else { return nil }
            ce.setComputePipelineState(convBGRA)
            ce.setTexture(t, index: 0); ce.setTexture(out, index: 2)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            let ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let video = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            guard let y = mapTexture(pb, plane: 0, ten ? .r16Unorm : .r8Unorm, usage: .shaderRead, fr: fr),
                  let c = mapTexture(pb, plane: 1, ten ? .rg16Unorm : .rg8Unorm, usage: .shaderRead, fr: fr) else { return nil }
            let m: Float = ten ? 1023 : 255, sh: Float = ten ? 1 : 1   // 10-bit is stored MSB-aligned, so fractions of full scale match
            if video {
                cu.a = SIMD4<Float>(Float(ten ? 64 : 16) / m * sh, m / (ten ? 876 : 219), (ten ? 512 : 128) / m, m / (ten ? 896 : 224))
            } else { cu.a = SIMD4<Float>(0, 1, (ten ? 512 : 128) / m, 1) }
            // matrix: tagged value wins; untagged streams follow the convention (HD = BT.709, SD / below 720p = BT.601)
            var kr: Float = 0.2126, kb: Float = 0.0722
            if let mx = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                if mx == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { kr = 0.299; kb = 0.114 }
                else if mx == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { kr = 0.2627; kb = 0.0593 }
            } else if h < 720 { kr = 0.299; kb = 0.114 }
            cu.b = SIMD4<Float>(kr, kb, 0, 0)
            if let tf = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String {
                if tf == (kCVImageBufferTransferFunction_sRGB as String) { cu.b.z = 1 }
                else if tf == (kCVImageBufferTransferFunction_UseGamma as String) { cu.b.z = 2 }
            }
            if let pr = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String {
                if pr == (kCVImageBufferColorPrimaries_P3_D65 as String) { (cu.m0, cu.m1, cu.m2) = p3ToRec709 }
                else if pr == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) { (cu.m0, cu.m1, cu.m2) = rec2020ToRec709 }
            }
            ce.setComputePipelineState(convNV12)
            ce.setTexture(y, index: 0); ce.setTexture(c, index: 1); ce.setTexture(out, index: 2)
            ce.setBytes(&cu, length: MemoryLayout<ConvU>.size, index: 0)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        default: return nil
        }
        return SrcTex(tex: out, w: w, h: h)
    }

    // MARK: scene drawing

    private func hex(_ v: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255, 1)
    }
    private func quad(_ r: CGRect, kind: Float, c0: SIMD4<Float> = .zero, c1: SIMD4<Float> = .zero, radius: Float = 0, border: Float = 0, opacity: Float = 1) -> QuadU {
        var u = QuadU()
        u.rect = SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        u.c0 = c0; u.c1 = c1
        u.p = SIMD4(kind, radius, border, opacity)
        u.q = SIMD4(Float(width), Float(height), 0, 0)
        return u
    }

    private func drawList(_ scene: Scene?, _ srcs: [SourceRef: SrcTex], _ fr: FrameRes, _ cb: MTLCommandBuffer) -> [Item] {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var items: [Item] = []
        guard let scene = scene else {
            items.append(.slot(quad(full, kind: 1, c0: hex(0x06090C)), nil))
            items += slateItems(full, text: "Pick a scene to go on air", fr: fr)
            return items
        }
        let rects = LayoutMath.rects(for: scene.layout, width: CGFloat(width), height: CGFloat(height))
        if rects.contains(where: { $0.framed }) {
            var u = quad(full, kind: 2, c0: hex(0x0B1A1D), c1: hex(0x05080A)); u.q = SIMD4(Float(width), Float(height), 0, 0)
            items.append(.slot(u, nil))
        } else { items.append(.slot(quad(full, kind: 1, c0: hex(0x06090C)), nil)) }
        for (i, sr) in rects.enumerated() {
            let r = CGRect(x: sr.rect.minX.rounded(), y: sr.rect.minY.rounded(), width: sr.rect.width.rounded(), height: sr.rect.height.rounded())
            let ref: SourceRef? = i < scene.slots.count ? scene.slots[i] : nil
            items += slotItems(ref, r, framed: sr.framed, fit: scene.fit(i), srcs, fr, cb)
        }
        return items
    }

    private func slotItems(_ ref: SourceRef?, _ r: CGRect, framed: Bool, fit: Bool, _ srcs: [SourceRef: SrcTex], _ fr: FrameRes, _ cb: MTLCommandBuffer) -> [Item] {
        let rad = framed ? Float(12 * S) : 0, bw = framed ? Float(1.5 * S) : 0
        let w = Int(r.width), h = Int(r.height)
        func labelled(_ bg: UInt32, _ text: String) -> [Item] {
            var out: [Item] = [.slot(quad(r, kind: 1, c0: hex(bg), radius: rad, border: bw), nil)]
            if let t = sprite("label|\(text)|\(w)x\(h)", { Art.label(text, w: w, h: h) }) { out.append(.sprite(quad(r, kind: 0), t, nil)) }
            return out
        }
        guard let ref = ref else { return labelled(0x11181C, "Empty slot") }
        if ref == .slate { return slateItems(r, text: slateText, fr: fr, radius: rad, border: bw) }
        guard let st = srcs[ref] else {
            if case .device = ref { return labelled(0x0D1418, "Waiting for the phone's video…") }
            return labelled(0x0D1418, "Loading…")
        }
        var u = quad(r, kind: 0, radius: rad, border: bw)
        let xf = transform(ref)
        let odd = xf.quarterTurns % 2 == 1
        let ew = CGFloat(odd ? st.h : st.w), eh = CGFloat(odd ? st.w : st.h)       // display-space source size (after rotation)
        var items: [Item] = []
        var contain = fit
        if case .image = ref { contain = true }
        var tex = st.tex
        var target = r
        var upscale: CGFloat = 1
        func srcDims(_ dw: Int, _ dh: Int) -> (Int, Int) { odd ? (dh, dw) : (dw, dh) }
        if contain {
            let sc = min(r.width / ew, r.height / eh)
            let dw = (ew * sc).rounded(), dh = (eh * sc).rounded()
            items.append(.slot(quad(r, kind: 1, c0: hex(0x06090C), radius: rad, border: bw), nil))
            target = CGRect(x: r.minX + ((r.width - dw) / 2).rounded(), y: r.minY + ((r.height - dh) / 2).rounded(), width: dw, height: dh)
            u = quad(target, kind: 0)
            if sc < 0.999 {
                let (sw, sh) = srcDims(Int(dw), Int(dh))
                tex = scaled(st.tex, to: (sw, sh), scaleX: Double(CGFloat(sw) / CGFloat(st.w)), scaleY: Double(CGFloat(sh) / CGFloat(st.h)), tx: 0, ty: 0, fr, cb)
            } else if abs(sc - 1) > 0.001 { upscale = sc }
        } else {
            let s = max(r.width / ew, r.height / eh)
            if s < 0.999 {
                let (sw, sh) = srcDims(w, h)
                let sx = CGFloat(st.w) * s, sy = CGFloat(st.h) * s
                tex = scaled(st.tex, to: (sw, sh), scaleX: Double(s), scaleY: Double(s), tx: Double((CGFloat(sw) - sx) / 2), ty: Double((CGFloat(sh) - sy) / 2), fr, cb)
            } else {
                let c = LayoutMath.coverCrop(srcW: ew, srcH: eh, dstW: r.width, dstH: r.height)
                u.uv = SIMD4(Float(c.minX / ew), Float(c.minY / eh), Float(c.maxX / ew), Float(c.maxY / eh))
                if abs(s - 1) > 0.001 { upscale = s }
            }
        }
        // sources smaller than their slot: Catmull-Rom + mild limited-halo sharpening; exact 1:1 stays a plain texel read
        if upscale > 1, debugUpscaleMode != 0 { u.p.x = 4; u.c0.x = debugUpscaleMode == 1 ? 0 : debugUpscaleMode == 3 ? 0.8 : debugUpscaleMode == 4 ? 1.2 : (upscale >= 2 ? 0.5 : upscale >= 1.25 ? 0.35 : 0.2) }
        u.c1.z = xf.flip ? 1 : 0; u.c1.w = Float(xf.quarterTurns)
        if ref == .camera { u.uv = SIMD4(u.uv.z, u.uv.y, u.uv.x, u.uv.w) }   // mirror the webcam
        items.append(.slot(u, tex))
        return items
    }

    /// Lanczos downscale `src` into a pooled (w x h) texture with the given source->dest transform.
    private func scaled(_ src: MTLTexture, to size: (Int, Int), scaleX: Double, scaleY: Double, tx: Double, ty: Double, _ fr: FrameRes, _ cb: MTLCommandBuffer) -> MTLTexture {
        let dst = fr.tex(device, max(1, size.0), max(1, size.1))
        var t = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY, translateX: tx, translateY: ty)
        withUnsafePointer(to: &t) { p in
            lanczos.scaleTransform = p
            lanczos.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
            lanczos.scaleTransform = nil
        }
        return dst
    }

    private func slateItems(_ r: CGRect, text: String, fr: FrameRes, radius: Float = 0, border: Float = 0) -> [Item] {
        var u = quad(r, kind: 3, c0: hex(0x0F3B3A), c1: hex(0x04070A), radius: radius, border: border)
        u.q.z = Float(20 * S); u.q.w = Float(max(r.width, r.height) * 0.7)
        var out: [Item] = [.slot(u, nil)]
        let w = Int(r.width), h = Int(r.height)
        if let t = sprite("slate|\(slateTitle)|\(text)|\(w)x\(h)", { Art.slateText(title: slateTitle, text: text, w: w, h: h) }) {
            out.append(.sprite(quad(r, kind: 0), t, nil))
        }
        return out
    }

    // MARK: overlays (design units are 1280x720; S scales them)

    private func overlayItems(_ req: FrameRequest) -> [Item] {
        guard let o = req.overlays else { return [] }
        var items: [Item] = []
        let S = self.S
        func spriteQuad(_ t: MTLTexture, x: CGFloat, y: CGFloat) -> QuadU {
            quad(CGRect(x: x.rounded(), y: y.rounded(), width: CGFloat(t.width), height: CGFloat(t.height)), kind: 0)
        }
        // image overlays go under the text overlays: web image first, then the logo
        if o.web.on {
            let w = o.web
            let loaded = (w.propId.flatMap { overlayImages.image(propId: $0) }) ?? overlayImages.image(url: w.url)
            let box = CGRect(x: w.x * Double(width), y: w.y * Double(height), width: w.w * Double(width), height: w.h * Double(height))
            if let l = loaded, box.width >= 1, box.height >= 1,
               let item = imageSprite(l, fit: box, maxSize: nil, opacity: w.opacity, tag: "web") { items.append(item) }
        }
        if o.logo.on, let pid = o.logo.propId, let l = overlayImages.image(propId: pid) {
            let maxW = CGFloat(o.logo.size) * S, maxH = maxW * 100 / 180
            let sc = min(maxW / CGFloat(l.image.width), maxH / CGFloat(l.image.height))
            let w = (CGFloat(l.image.width) * sc).rounded(), h = (CGFloat(l.image.height) * sc).rounded()
            let m = 28 * S
            let right = o.logo.corner == .tr || o.logo.corner == .br, bottom = o.logo.corner == .bl || o.logo.corner == .br
            // keep clear of the LIVE bug (top-right) and the ticker (bottom)
            let x = right ? CGFloat(width) - m - w : m
            let y = bottom ? CGFloat(height) - m - h - (o.ticker ? 48 * S : 0) : m + (right && o.liveBug ? 46 * S : 0)
            if let item = imageSprite(l, fit: CGRect(x: x, y: y, width: w, height: h), maxSize: nil, opacity: o.logo.opacity, tag: "logo") { items.append(item) }
        }
        if o.liveBug {
            var time = "0:00:00"
            if let s = req.liveSince {
                let secs = max(0, Int(Date().timeIntervalSince(s)))
                time = String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
            }
            if let t = sprite("bug|\(time)", { Art.liveBug(time: time, S: S) }) {
                items.append(.sprite(spriteQuad(t, x: (1280 - 210) * S, y: 22 * S), t, nil))
            }
        }
        if o.lowerThird && !o.lowerTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = "lt|\(o.lowerTitle)|\(o.lowerSubtitle)"
            if let t = sprite(key, { Art.lowerThird(title: o.lowerTitle, subtitle: o.lowerSubtitle, S: S)?.0 }) {
                items.append(.sprite(spriteQuad(t, x: 40 * S, y: (720 - (o.ticker ? 150 : 110)) * S), t, nil))
            }
        }
        if o.ticker && !o.tickerText.trimmingCharacters(in: .whitespaces).isEmpty {
            if let bar = sprite("tickbar", { Art.tickerBar(S: S) }) {
                items.append(.sprite(spriteQuad(bar, x: 0, y: (720 - 44) * S), bar, nil))
            }
            var period: CGFloat = 0
            let key = "ticker|\(o.tickerText)"
            if let strip = sprite(key, { if let r = Art.tickerStrip(text: o.tickerText, S: S) { period = r.1; return r.0 }; return nil }) {
                if period == 0 { period = tickerPeriods[key] ?? CGFloat(strip.width) / S / 2 } else { tickerPeriods[key] = period }
                let off = CGFloat((req.time * 90).truncatingRemainder(dividingBy: Double(period)))
                let x = (110 - off) * S
                let clipX = Int(100 * S)
                let sc = MTLScissorRect(x: clipX, y: Int((720 - 44) * S), width: width - clipX, height: Int(44 * S))
                items.append(.sprite(spriteQuad(strip, x: x, y: (720 - 44) * S), strip, sc))
            }
        }
        return items
    }
    /// Image fitted (aspect preserved, centred) into `box` (output pixels), pre-scaled with CoreGraphics and cached as a texture.
    private func imageSprite(_ l: OverlayImageCache.Loaded, fit box: CGRect, maxSize: CGSize?, opacity: Double, tag: String) -> Item? {
        let iw = CGFloat(l.image.width), ih = CGFloat(l.image.height)
        let sc = min(box.width / iw, box.height / ih)
        let w = max(1, Int((iw * sc).rounded())), h = max(1, Int((ih * sc).rounded()))
        let img = l.image
        guard let t = sprite("\(tag)|\(ObjectIdentifier(self).hashValue)|\(l.version)|\(Unmanaged.passUnretained(img).toOpaque())|\(w)x\(h)", {
            Art.image(width: CGFloat(w), height: CGFloat(h), scale: 1) { c in
                c.interpolationQuality = .high
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)     // draw upright in the top-left space
                c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }) else { return nil }
        let r = CGRect(x: (box.minX + (box.width - CGFloat(w)) / 2).rounded(), y: (box.minY + (box.height - CGFloat(h)) / 2).rounded(), width: CGFloat(w), height: CGFloat(h))
        return .sprite(quad(r, kind: 0, opacity: Float(max(0, min(1, opacity)))), t, nil)
    }
    private var tickerPeriods: [String: CGFloat] = [:]
}
