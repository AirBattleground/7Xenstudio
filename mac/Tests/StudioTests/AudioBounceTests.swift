import Testing
import Foundation
import AVFoundation
@testable import Studio

/// Offline "real pipeline" bounce: a recorded programme (rec.wav) enters the mixer as a phone feed through the production jitter ring
/// (bursty arrival, 300 ppm fast producer), master limiter, AAC encoder, decoded again: before/after numbers via ffmpeg ebur128.
@Suite(.serialized) struct AudioBounceTests {
    @Test func bounceRecordedProgramme() throws {
        let inURL = URL(fileURLWithPath: "/tmp/audio-shots/rec.wav")
        guard FileManager.default.fileExists(atPath: inURL.path), let tag = ProcessInfo.processInfo.environment["BOUNCE_TAG"] else { return }
        let f = try AVAudioFile(forReading: inURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let secs = 60, frames = 48_000 * secs
        f.framePosition = AVAudioFramePosition(48_000 * (Int(ProcessInfo.processInfo.environment["BOUNCE_START"] ?? "0") ?? 0))
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try f.read(into: buf, frameCount: AVAudioFrameCount(frames))
        let L = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        let R = Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: Int(buf.frameLength)))
        let m = AudioMixer(jitterTargetMs: 150); m.addSource(id: "device:a", active: true, jitterMs: 150)
        var s = AudioSettings(); s.phoneLatencyMs = 0; s.duck.enabled = false; s.micEnabled = false
        s.phones["device:a"] = { var c = ChannelSettings(); c.gainDb = 6; return c }()
        m.settings = s
        let enc = AudioEncoder(); var adts = Data(); enc.onFrame = { d, _ in adts.append(d) }
        var seed: UInt64 = 3
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        var pos = 0, carry = 0.0, outPos = 0
        var outL = [Float](), outR = [Float]()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        while pos < L.count - 2000 {
            carry += 480 * 1.0003
            var n = Int(carry); carry -= Double(n)
            while n > 0 { let k = min(n, Int(100 + rnd() * 380), L.count - pos); if k <= 0 { break }
                m.push(id: "device:a", left: Array(L[pos..<pos + k]), right: Array(R[pos..<pos + k])); pos += k; n -= k }
            let o = m.renderOffline(frames: 480); outL += o.l; outR += o.r
            if outL.count - outPos >= 1024 {
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!; b.frameLength = 1024
                for i in 0..<1024 { b.floatChannelData![0][i] = outL[outPos + i]; b.floatChannelData![1][i] = outR[outPos + i] }
                enc.feed(b, pts: Double(outPos) / 48_000); outPos += 1024
            }
        }
        let dir = "/tmp/audio-shots/"
        try adts.write(to: URL(fileURLWithPath: dir + "bounce-\(tag).aac"))
        let wf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let pre = AVAudioPCMBuffer(pcmFormat: wf, frameCapacity: AVAudioFrameCount(outL.count))!; pre.frameLength = AVAudioFrameCount(outL.count)
        for i in 0..<outL.count { pre.floatChannelData![0][i] = outL[i]; pre.floatChannelData![1][i] = outR[i] }
        let wavOut = try AVAudioFile(forWriting: URL(fileURLWithPath: dir + "premix-\(tag).wav"), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
        try wavOut.write(from: pre)
        let st = m.inputStats(id: "device:a")
        print("BOUNCE[\(tag)] underruns \(st.underruns) servoPpm \(st.servoPpm) aacBytes \(adts.count) (\(Double(adts.count) * 8 / Double(secs) / 1000) kbps)")
    }
}
