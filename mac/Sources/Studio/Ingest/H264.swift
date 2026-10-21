// Annex-B H.264 parsing + VideoToolbox hardware decode for the phone video path (ffmpeg `-c:v copy -f h264 pipe:1` -> here).
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

/// Splits an Annex-B byte stream into NAL units (3- and 4-byte start codes, chunk boundaries anywhere).
/// A NAL is emitted once the next start code is seen; `at` is the timestamp of the chunk in which its start code arrived.
struct AnnexBParser {
    struct NAL { var bytes: [UInt8]; var at: Double }
    private var buf: [UInt8] = []
    private var scan = 0
    private var open: Int?            // index in buf of the first payload byte of the NAL being collected
    private var openAt = 0.0

    mutating func reset() { buf.removeAll(keepingCapacity: true); scan = 0; open = nil }

    mutating func feed(_ chunk: UnsafeBufferPointer<UInt8>, at: Double) -> [NAL] {
        buf.append(contentsOf: chunk)
        var out: [NAL] = []
        var i = scan
        let n = buf.count
        while i + 2 < n {
            if buf[i + 2] > 1 { i += 3; continue }                       // fast skip: no start code can begin at i, i+1, i+2
            if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                if let o = open {
                    var end = i                                           // strip trailing zero bytes (4-byte start code / trailing_zero_8bits)
                    while end > o, buf[end - 1] == 0 { end -= 1 }
                    if end > o { out.append(NAL(bytes: Array(buf[o..<end]), at: openAt)) }
                }
                open = i + 3; openAt = at; i += 3
            } else { i += 1 }
        }
        scan = max(0, n - 2)
        // drop consumed bytes
        let keepFrom = open ?? max(0, n - 3)
        if keepFrom > 0 { buf.removeFirst(keepFrom); if open != nil { open = 0 }; scan = max(0, scan - keepFrom) }
        return out
    }
    /// The NAL still open at end of stream (only safe when the producer finished a whole unit).
    mutating func flush() -> NAL? {
        defer { reset() }
        guard let o = open else { return nil }
        var end = buf.count
        while end > o, buf[end - 1] == 0 { end -= 1 }
        return end > o ? NAL(bytes: Array(buf[o..<end]), at: openAt) : nil
    }
}

struct AccessUnit {
    var nals: [[UInt8]]
    var at: Double
    var isIDR: Bool { nals.contains { $0[0] & 0x1f == 5 } }
    var sps: [UInt8]? { nals.first { $0[0] & 0x1f == 7 } }
    var pps: [UInt8]? { nals.first { $0[0] & 0x1f == 8 } }
    /// AVCC payload: 4-byte big-endian length prefixes; parameter sets, AUD and SEI are dropped (they live in the format description).
    var avcc: [UInt8] {
        var out: [UInt8] = []
        for n in nals {
            let t = n[0] & 0x1f
            guard t >= 1 && t <= 5 else { continue }
            let c = UInt32(n.count)
            out.append(contentsOf: [UInt8(c >> 24), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)])
            out.append(contentsOf: n)
        }
        return out
    }
}

/// Groups NALs into access units. An AU ends when the next one starts: a slice with first_mb_in_slice == 0, or an
/// AUD/SEI/SPS/PPS arriving after the AU already holds a slice.
struct AccessUnitBuilder {
    private var cur: [[UInt8]] = []
    private var hasVCL = false
    private var at = 0.0
    mutating func add(_ nal: AnnexBParser.NAL) -> AccessUnit? {
        guard let h = nal.bytes.first else { return nil }
        let t = h & 0x1f
        let isSlice = (t == 1 || t == 5)
        var starts = false
        if hasVCL {
            if isSlice { starts = nal.bytes.count > 1 && (nal.bytes[1] & 0x80) != 0 }   // first_mb_in_slice == 0  <=>  ue(v) leading bit 1
            else if t == 6 || t == 7 || t == 8 || t == 9 { starts = true }
        }
        var done: AccessUnit?
        if starts { done = AccessUnit(nals: cur, at: at); cur = []; hasVCL = false }
        if cur.isEmpty { at = nal.at }
        cur.append(nal.bytes)
        if isSlice { hasVCL = true }
        return done
    }
    mutating func flush() -> AccessUnit? {
        defer { cur = []; hasVCL = false }
        return hasVCL ? AccessUnit(nals: cur, at: at) : nil
    }
    mutating func reset() { cur = []; hasVCL = false }
}

/// VTDecompressionSession wrapper: hardware, NV12 video range, IOSurface + Metal compatible, real-time.
final class H264Decoder {
    typealias Output = (CVPixelBuffer, _ arrival: Double, _ decodeSeconds: Double) -> Void
    private var session: VTDecompressionSession?
    private var desc: CMVideoFormatDescription?
    private var sps: [UInt8]?, pps: [UInt8]?
    private var ptsTick: Int64 = 0
    private(set) var sessionsCreated = 0
    private(set) var decodeErrors = 0
    private let flightLock = NSLock()
    private var _inFlight = 0
    /// Frames submitted to VideoToolbox whose output has not arrived yet (backlog => the caller should drop to the next IDR).
    var inFlight: Int { flightLock.lock(); defer { flightLock.unlock() }; return _inFlight }
    private let output: Output
    init(output: @escaping Output) { self.output = output }
    deinit { invalidate() }

    var ready: Bool { session != nil }
    func invalidate() {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil; desc = nil
    }
    func forgetParameters() { invalidate(); sps = nil; pps = nil }

    /// Returns false if the AU could not be decoded (caller should wait for the next IDR).
    @discardableResult
    func decode(_ au: AccessUnit) -> Bool {
        if let s = au.sps, let p = au.pps, s != sps || p != pps {          // new / changed parameter sets (reconnect, resolution change)
            if au.isIDR {
                sps = s; pps = p; invalidate()
                guard makeSession() else { return false }
            }
        }
        if session == nil {
            guard au.isIDR, sps != nil, pps != nil, makeSession() else { return false }   // keyframe wait
        }
        let data = au.avcc
        guard !data.isEmpty, let session, let desc else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr
        else { return false }
        ptsTick += 1
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: ptsTick, timescale: 60), decodeTimeStamp: CMTime(value: ptsTick, timescale: 60))
        var size = data.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: desc, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return false }
        let at = au.at, out = output, t0 = CACurrentMediaTime()
        var flags = VTDecodeInfoFlags()
        flightLock.lock(); _inFlight += 1; flightLock.unlock()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], infoFlagsOut: &flags) { [weak self] status, _, image, _, _ in
            self?.flightLock.lock(); self?._inFlight -= 1; self?.flightLock.unlock()
            if status == noErr, let image { out(image, at, CACurrentMediaTime() - t0) }
        }
        if st != noErr {
            flightLock.lock(); _inFlight -= 1; flightLock.unlock()
            decodeErrors += 1
            if st == kVTInvalidSessionErr || st == kVTVideoDecoderMalfunctionErr { invalidate() }
            return false
        }
        return true
    }

    private func makeSession() -> Bool {
        guard let sps, let pps else { return false }
        var fd: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBufferPointer { sp in pps.withUnsafeBufferPointer { pp in
            let ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!], sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                       nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        } }
        guard st == noErr, let fd else { return false }
        let spec: [String: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &s) == noErr, let s else { return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s; desc = fd; sessionsCreated += 1
        return true
    }
}
