import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import Studio

/// Encoder A/B harness (env-gated, skipped normally): STUDIO_HDBENCH=<lossless ref.mkv> STUDIO_HDBENCH_OUT=<out.mp4> [STUDIO_HDBENCH_KBPS=15000] [STUDIO_HDBENCH_HEVC=1]
/// Replays the reference in real time at 60 fps through OutputPipeline (VideoToolbox -> ffmpeg -c copy) so bitrate/SSIM/PSNR can be measured with ffprobe/ffmpeg.
@Suite(.serialized) struct HDBenchTests {
    @Test func replayReference() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ref = env["STUDIO_HDBENCH"], let outPath = env["STUDIO_HDBENCH_OUT"], let ff = FFmpegLocator.locate() else { return }
        let kbps = Int(env["STUDIO_HDBENCH_KBPS"] ?? "") ?? defaultVideoKbps
        let W = 1920, H = 1080, fsize = W * H * 3 / 2
        let dec = Process(); dec.executableURL = URL(fileURLWithPath: ff)
        dec.arguments = ["-v", "error", "-i", ref, "-pix_fmt", "nv12", "-f", "rawvideo", "pipe:1"]
        let pipe = Pipe(); dec.standardOutput = pipe; try dec.run()
        defer { if dec.isRunning { dec.terminate() } }
        let fh = pipe.fileHandleForReading
        let out = OutputPipeline(); out.onLog = { print("HDBENCH log:", $0) }
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = URL(fileURLWithPath: outPath); cfg.videoKbps = kbps; cfg.recordHEVC = env["STUDIO_HDBENCH_HEVC"] != nil
        try out.start(cfg)
        var pbs: [CVPixelBuffer] = []
        for _ in 0..<12 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            pbs.append(pb!)
        }
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let t0 = CFAbsoluteTimeGetCurrent()
        var i = 0, cpu0 = Self.cpu()
        while true {
            let data = try fh.read(upToCount: fsize) ?? Data()
            var buf = data
            while buf.count < fsize, buf.count > 0 { let more = try fh.read(upToCount: fsize - buf.count) ?? Data(); if more.isEmpty { break }; buf.append(more) }
            if buf.count < fsize { break }
            let pb = pbs[i % pbs.count]
            CVPixelBufferLockBaseAddress(pb, [])
            buf.withUnsafeBytes { raw in
                let yS = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cS = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                let yd = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, cd = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
                for r in 0..<H { memcpy(yd + r * yS, raw.baseAddress! + r * W, W) }
                for r in 0..<(H / 2) { memcpy(cd + r * cS, raw.baseAddress! + W * H + r * W, W) }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let due = t0 + Double(i) / 60
            while CFAbsoluteTimeGetCurrent() < due { try await Task.sleep(nanoseconds: 300_000) }
            out.submit(video: pb, pts: host + CMTime(value: Int64(i), timescale: 60))
            i += 1
        }
        let wall = CFAbsoluteTimeGetCurrent() - t0
        let cpu = (Self.cpu() - cpu0) / wall * 100; cpu0 = 0
        try await Task.sleep(nanoseconds: 500_000_000)
        let st = out.stats
        await out.stop()
        print("HDBENCH frames=\(i) wall=\(String(format: "%.1f", wall)) dropped=\(st.droppedFrames) vtLatencyMs=\(String(format: "%.2f", st.encodeLatencyMs)) vtMax=\(String(format: "%.1f", out.maxEncodeLatencyMs)) cpu=\(String(format: "%.0f", cpu))% (includes ref decode/memcpy in-process only)")
    }
    static func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}
