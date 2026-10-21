import Testing
import Foundation
import CoreMedia
import CoreVideo
import AVFoundation
@testable import Studio

@Suite struct OutputUnitTests {
    @Test func redactsStreamKeys() {
        let s = redactKeys("Failed rtmp://a.rtmp.youtube.com/live2/abcd-1234-efgh: refused")
        #expect(!s.contains("abcd-1234"))
        #expect(s.contains("rtmp://a.rtmp.youtube.com/live2/"))
    }
    @Test func parsesSlaveFailure() {
        let f = parseSlaveFailure("[tee @ 0x1] Slave muxer #1 failed: Connection refused, continuing with 1/2 slaves.")
        #expect(f?.index == 1); #expect(f?.error == "Connection refused")
    }
    @Test func progressMeter() {
        var t = 0.0
        let m = ProgressMeter(now: { t })
        t = 0; m.feed("frame=0\ntotal_size=0\nout_time_us=0\nprogress=continue\n")
        t = 2; m.feed("frame=120\ntotal_size=300000\nout_time_us=2000000\nprogress=continue\n")
        #expect(m.fps == 60); #expect(m.kbps == 1200)
    }
    @Test func argsAreCopyOnlyAndTee() {
        let d = Destination(id: "1", name: "YT", kind: .youtube, url: "rtmp://x/live2", key: "KEY")
        let (a, labels) = FFmpegArgs.make(recording: "/tmp/a b.mp4", hevcRecording: false, destinations: [d], preview: nil)
        #expect(a.contains("copy")); #expect(!a.contains("libx264"))
        #expect(labels == ["YT"])
        let tee = a.last!
        #expect(a.contains("+frag_keyframe+empty_moov+default_base_moof"))
        #expect(tee.contains("onfail=ignore"))
        #expect(tee.contains("rtmp://x/live2/KEY"))
    }
    @Test func tsPacketsAre188AndCRC() {
        let m = TSMuxer()
        let psi = m.psi(hevc: true)
        #expect(psi.count == 376); #expect(psi[0] == 0x47 && psi[188] == 0x47)
        #expect(TSMuxer.crc32mpeg([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00]) == 0x2AB1_04B2)
        for n in [1, 150, 160, 183, 184, 185, 1000, 5000] {
            let v = m.video(annexB: Data(repeating: 7, count: n), pts: 1_000_000, keyframe: true)
            #expect(v.count % 188 == 0, "n=\(n)")
            let a = m.audio(adts: Data(repeating: 1, count: n), pts: 90000)
            #expect(a.count % 188 == 0)
        }
    }
    @Test func locatorFindsHomebrewOrNil() {
        if let p = FFmpegLocator.locate() { #expect(FileManager.default.isExecutableFile(atPath: p)) }
    }
}

// MARK: integration

private func makeNV12(_ seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var rng = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 1)
    for row in 0..<1080 { for x in 0..<1920 {
        rng = rng &* 1664525 &+ 1013904223
        y[row * ys + x] = UInt8(truncatingIfNeeded: 16 + ((x + seed * 12) >> 3 & 0x7F) + Int(rng >> 29))
    } }
    let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
    let us = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
    for row in 0..<540 { for x in 0..<960 { uv[row * us + x * 2] = UInt8(100 + (row >> 3) % 60); uv[row * us + x * 2 + 1] = UInt8(120 + (x >> 3) % 60) } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

private func audioBuffer(frames: Int, startFrame: Int, pts: CMTime) -> CMSampleBuffer {
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { let v = Float(sin(Double(startFrame + i) * 2 * .pi * 440 / 48000)) * 0.3; samples[2 * i] = v; samples[2 * i + 1] = v }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fd: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
    var bb: CMBlockBuffer?
    let bytes = samples.count * 4
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fd!, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

private func run(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
    try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

private func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

@Suite(.serialized) struct OutputIntegrationTests {
    func encodeThreeSeconds(hevc: Bool) async throws -> (URL, OutputStats, Double, Double) {
        guard let ff = FFmpegLocator.locate(), let probe = FFmpegLocator.ffprobe(besides: ff) else { throw OutputError.ffmpegMissing("ffmpeg") }
        _ = probe
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(hevc ? "rec-hevc.mp4" : "rec.mp4")
        let out = OutputPipeline()
        out.onLog = { print("[out]", $0) }
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = url; cfg.recordHEVC = hevc
        try out.start(cfg)
        let frames = (0..<30).map(makeNV12)
        let t0 = CFAbsoluteTimeGetCurrent(), c0 = cpuSeconds()
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        var aFrame = 0
        for i in 0..<180 {
            let due = t0 + Double(i) / 60
            while CFAbsoluteTimeGetCurrent() < due { try await Task.sleep(nanoseconds: 500_000) }
            let pts = host + CMTime(value: Int64(i), timescale: 60)
            out.submit(video: frames[i % 30], pts: pts)
            while Double(aFrame) / 48000 < Double(i + 1) / 60 {
                out.submit(audio: audioBuffer(frames: 800, startFrame: aFrame, pts: host + CMTime(value: Int64(aFrame), timescale: 48000)))
                aFrame += 800
            }
        }
        try await Task.sleep(nanoseconds: 2_100_000_000) // let a progress block land
        let stats = out.stats
        await out.stop()
        let wall = CFAbsoluteTimeGetCurrent() - t0
        return (url, stats, (cpuSeconds() - c0) / wall * 100, wall)
    }

    @Test func threeSecondsOfSynthetic1080p60() async throws {
        let (url, stats, cpu, wall) = try await encodeThreeSeconds(hevc: false)
        let ff = FFmpegLocator.locate()!, probe = FFmpegLocator.ffprobe(besides: ff)!
        let j = run(probe, ["-v", "error", "-count_frames", "-show_entries", "stream=codec_name,width,height,avg_frame_rate,r_frame_rate,nb_read_frames,duration,profile", "-of", "default=nw=0", url.path])
        print("ffprobe:\n\(j)")
        print("STATS dropped=\(stats.droppedFrames) kbps=\(stats.kbps) fps=\(stats.encodeFPS) VTlatency=\(String(format: "%.2f", stats.encodeLatencyMs))ms CPU=\(String(format: "%.0f", cpu))% wall=\(wall)s")
        #expect(j.contains("codec_name=h264")); #expect(j.contains("width=1920")); #expect(j.contains("height=1080"))
        #expect(j.contains("codec_name=aac"))
        let fr = j.split(separator: "\n").first { $0.hasPrefix("avg_frame_rate=") }.map { String($0.dropFirst(15)) } ?? ""
        let parts = fr.split(separator: "/").compactMap(Double.init)
        let fps = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 0
        #expect(abs(fps - 60) < 6, "fps \(fps)")
        #expect(stats.droppedFrames < 10)
        #expect(stats.kbps > 1000, "progress meter reported \(stats.kbps) kbps")
    }

    @Test func hevcRecordingKeepsH264Feed() async throws {
        let (url, stats, cpu, _) = try await encodeThreeSeconds(hevc: true)
        let ff = FFmpegLocator.locate()!, probe = FFmpegLocator.ffprobe(besides: ff)!
        let j = run(probe, ["-v", "error", "-show_entries", "stream=codec_name,width,height", "-of", "default=nw=0", url.path])
        print("HEVC ffprobe:\n\(j)  CPU=\(cpu)% kbps=\(stats.kbps)")
        #expect(j.contains("codec_name=hevc")); #expect(j.contains("codec_name=aac"))
    }
}
