import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

struct EncodedVideo { var annexB: Data; var pts90k: UInt64; var keyframe: Bool }

enum OutputError: Error, LocalizedError {
    case ffmpegMissing(String), encoder(String), launch(String)
    var errorDescription: String? {
        switch self {
        case .ffmpegMissing(let p): return "ffmpeg not found (\(p)). Install it with `brew install ffmpeg`."
        case .encoder(let m): return "Video encoder: \(m)"
        case .launch(let m): return "Could not start ffmpeg: \(m)"
        }
    }
}

/// Rate-control tuning. Defaults are the shipping values; STUDIO_VT="q=0.9,rt=0,peak=1.5,mode=avg|cbr|vbr,minqp=,maxqp=,delay=,v=1" overrides them for A/B measurement.
struct VTTuning {
    enum Mode { case average, constant, variable }
    var quality: Double? = 0.75
    var realtime = true
    var peak = 1.5            // DataRateLimits = peak x average over 1 s (0 = off)
    var mode = Mode.average
    var minQP: Int?, maxQP: Int?, maxFrameDelay: Int?
    var verbose = false
    static var current: VTTuning {
        var t = VTTuning()
        guard let raw = ProcessInfo.processInfo.environment["STUDIO_VT"] else { return t }
        for kv in raw.split(separator: ",") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init); guard p.count == 2 else { continue }
            switch p[0] {
            case "q": t.quality = p[1] == "none" ? nil : Double(p[1])
            case "rt": t.realtime = p[1] != "0"
            case "peak": t.peak = Double(p[1]) ?? t.peak
            case "mode": t.mode = p[1] == "cbr" ? .constant : p[1] == "vbr" ? .variable : .average
            case "minqp": t.minQP = Int(p[1])
            case "maxqp": t.maxQP = Int(p[1])
            case "delay": t.maxFrameDelay = Int(p[1])
            case "v": t.verbose = true
            default: break
            }
        }
        return t
    }
}

/// Hardware VideoToolbox encoder (H.264 High or HEVC Main) producing Annex-B access units. Strict CFR input.
final class VideoEncoder: @unchecked Sendable {
    let codec: CMVideoCodecType
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var inflight = 0
    private(set) var latencySum = 0.0, latencyCount = 0, latencyMax = 0.0
    var onFrame: ((EncodedVideo) -> Void)?
    private let fps: Int

    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return inflight }
    var meanLatencyMs: Double { lock.lock(); defer { lock.unlock() }; return latencyCount == 0 ? 0 : latencySum / Double(latencyCount) * 1000 }
    var maxLatencyMs: Double { lock.lock(); defer { lock.unlock() }; return latencyMax * 1000 }

    init(codec: CMVideoCodecType, width: Int, height: Int, fps: Int, kbps: Int, speedOverQuality: Bool = false) throws {
        self.codec = codec; self.fps = fps
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        ]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw OutputError.encoder("VTCompressionSessionCreate failed (\(st)); no hardware encoder?") }
        session = s
        func set(_ k: CFString, _ v: Any) { let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef); if r != noErr, tuning.verbose { NSLog("VT set %@ failed %d", k as String, r) } }
        let tuning = VTTuning.current
        let hevc = codec == kCMVideoCodecType_HEVC
        set(kVTCompressionPropertyKey_RealTime, tuning.realtime)
        set(kVTCompressionPropertyKey_ProfileLevel, hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        switch tuning.mode {
        case .constant:
            set(kVTCompressionPropertyKey_ConstantBitRate, kbps * 1000)
        case .variable:
            if #available(macOS 26.0, *) { set(kVTCompressionPropertyKey_VariableBitRate, kbps * 1000) } else { set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000) }
            if tuning.peak > 0 { set(kVTCompressionPropertyKey_DataRateLimits, [Int(Double(kbps) * 1000 * tuning.peak / 8), 1] as [Int]) }
        case .average:
            set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000)
            if tuning.peak > 0 { set(kVTCompressionPropertyKey_DataRateLimits, [Int(Double(kbps) * 1000 * tuning.peak / 8), 1] as [Int]) }
        }
        if let q = tuning.quality { set(kVTCompressionPropertyKey_Quality, q) }
        if let d = tuning.maxFrameDelay { set(kVTCompressionPropertyKey_MaxFrameDelayCount, d) }
        if let q = tuning.minQP { set(kVTCompressionPropertyKey_MinAllowedFrameQP, q) }
        if let q = tuning.maxQP { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, q) }
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, speedOverQuality)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if !hevc { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC) }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// Encode one frame (pts/duration strictly CFR). Output arrives on onFrame from a VT thread.
    func encode(_ pb: CVPixelBuffer, frameIndex: Int64, forceKey: Bool) {
        guard let session else { return }
        lock.lock(); inflight += 1; lock.unlock()
        let t0 = CFAbsoluteTimeGetCurrent()
        let pts = CMTime(value: frameIndex, timescale: Int32(fps))
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                                 duration: CMTime(value: 1, timescale: Int32(fps)),
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            let dt = CFAbsoluteTimeGetCurrent() - t0
            self.lock.lock(); self.inflight -= 1; self.latencySum += dt; self.latencyCount += 1; self.latencyMax = max(self.latencyMax, dt); self.lock.unlock()
            guard status == noErr, let sb, let au = VideoEncoder.annexB(sb, hevc: self.codec == kCMVideoCodecType_HEVC) else { return }
            self.onFrame?(EncodedVideo(annexB: au.0, pts90k: UInt64(max(0, frameIndex)) * 90000 / UInt64(self.fps), keyframe: au.1))
        }
        if st != noErr { lock.lock(); inflight -= 1; lock.unlock() }
    }

    func flush() { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }

    func invalidate() {
        flush()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// length-prefixed (AVCC/HVCC) -> Annex-B, with AUD and (on keyframes) parameter sets in-band.
    static func annexB(_ sb: CMSampleBuffer, hevc: Bool) -> (Data, Bool)? {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var key = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first {
            key = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        let sc: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        out.append(contentsOf: sc); out.append(contentsOf: hevc ? [0x46, 0x01, 0x50] : [0x09, 0xF0])
        var nalLen: Int32 = 4
        if key {
            var count = 0
            func ps(_ i: Int) -> Data? {
                var p: UnsafePointer<UInt8>?; var size = 0; var c = 0
                let st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &c, nalUnitHeaderLengthOut: &nalLen)
                           : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &c, nalUnitHeaderLengthOut: &nalLen)
                count = c
                guard st == noErr, let p else { return nil }
                return Data(bytes: p, count: size)
            }
            _ = ps(0)
            for i in 0..<count { if let d = ps(i) { out.append(contentsOf: sc); out.append(d) } }
        } else {
            var p: UnsafePointer<UInt8>?; var size = 0; var c = 0
            _ = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &c, nalUnitHeaderLengthOut: &nalLen)
                     : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &c, nalUnitHeaderLengthOut: &nalLen)
        }
        let total = CMBlockBufferGetDataLength(bb)
        var data = Data(count: total)
        let st = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
        guard st == noErr else { return nil }
        let n = Int(nalLen)
        var i = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while i + n <= total {
                var len = 0
                for k in 0..<n { len = (len << 8) | Int(raw[i + k]) }
                i += n
                if len <= 0 || i + len > total { break }
                out.append(contentsOf: sc); out.append(raw.baseAddress!.advanced(by: i).assumingMemoryBound(to: UInt8.self), count: len)
                i += len
            }
        }
        return (out, key)
    }
}
