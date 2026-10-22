import Testing
import Foundation
import AVFoundation
@testable import Studio

// Objective noise / artefact measurements on the real mixer render path (offline).
private let sr = 48_000.0
private func sine(_ f: Double, _ amp: Float, from: Int = 0, count: Int) -> [Float] {
    (0..<count).map { amp * Float(sin(2 * Double.pi * f * Double(from + $0) / sr)) }
}
/// Least-squares fit of a free-phase sine at f over x[a..<b]; returns (amplitude, THD+N in dB relative to the fitted tone).
private func fit(_ x: [Float], _ f: Double, _ a: Int, _ b: Int) -> (amp: Double, thdn: Double) {
    // exact 2x2 least squares for A cos + B sin (window need not hold whole cycles)
    var scc = 0.0, sss = 0.0, scs = 0.0, sxc = 0.0, sxs = 0.0
    let w0 = 2 * Double.pi * f / sr
    for i in a..<b { let w = w0 * Double(i), c = cos(w), s = sin(w), v = Double(x[i]); scc += c * c; sss += s * s; scs += c * s; sxc += v * c; sxs += v * s }
    let det = scc * sss - scs * scs
    let A = (sxc * sss - sxs * scs) / det, B = (sxs * scc - sxc * scs) / det
    var res = 0.0
    for i in a..<b { let w = w0 * Double(i); let e = Double(x[i]) - A * cos(w) - B * sin(w); res += e * e }
    let amp = (A * A + B * B).squareRoot()
    return (amp, 10 * log10(max(res / Double(b - a), 1e-30) / (amp * amp / 2)))
}
/// Like fit(), but searches the tone frequency (+-1.5 %) so a legitimate resampling shift is not counted as noise.
private func fitBest(_ x: [Float], _ f: Double, _ a: Int, _ b: Int) -> Double {
    var bestF = f, best = 1e9
    var df = -0.012 * f
    while df <= 0.012 * f { let v = fit(x, f + df, a, b).thdn; if v < best { best = v; bestF = f + df }; df += 1 }
    var lo = bestF - 1, hi = bestF + 1                          // ternary refinement around the coarse optimum
    for _ in 0..<40 {
        let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
        if fit(x, m1, a, b).thdn < fit(x, m2, a, b).thdn { hi = m2 } else { lo = m1 }
    }
    return min(best, fit(x, (lo + hi) / 2, a, b).thdn)
}
private func settings() -> AudioSettings { var s = AudioSettings(); s.phoneLatencyMs = 0; s.duck.enabled = false; return s }

@Suite(.serialized) struct AudioNoiseTests {
    /// Phone tone through the production jitter ring (150 ms) with a producer slightly faster than the consumer and bursty chunks.
    static func servoRun(driftPpm: Double, seconds: Double = 12, extraFrames: Int = 0, freq: Double = 1000) -> (worst: Double, median: Double, underruns: Int, ppm: Int) {
        let m = AudioMixer(jitterTargetMs: 150); m.addSource(id: "device:a", active: true, jitterMs: 150); m.settings = settings()
        var out = [Float](), pos = 0.0, carry = 0.0
        let blocks = Int(seconds * 48_000 / 480)
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for blk in 0..<blocks {
            if blk == 200, extraFrames > 0 { m.push(id: "device:a", left: sine(freq, 0.5, from: Int(pos), count: extraFrames)); pos += Double(extraFrames) }
            // producer delivers 480 * (1 + drift) frames per 10 ms, in 1-3 irregular bursts
            carry += 480 * (1 + driftPpm * 1e-6)
            var n = Int(carry); carry -= Double(n)
            while n > 0 {
                let k = min(n, Int(100 + rnd() * 380)); 
                m.push(id: "device:a", left: sine(freq, 0.5, from: Int(pos), count: k)); pos += Double(k); n -= k
            }
            out += m.renderOffline(frames: 480).l
        }
        var vals = [Double]()
        var i = 20_000
        _ = i
        while i + 960 < out.count { vals.append(fitBest(out, freq, i, i + 960)); if ProcessInfo.processInfo.environment["SERVO_DEBUG"] != nil { print("  t=\(Double(i) / 48000) thdn=\(vals.last!)") }; i += 7200 }   // 20 ms windows: negligible chirp while the servo trims
        vals.sort()
        let st = m.inputStats(id: "device:a")
        return (vals.last ?? 0, vals[vals.count / 2], st.underruns, st.servoPpm)
    }

    @Test func servoSpuriousFloor() {
        // idle servo (in band): bit-exact. Correcting servo (ring 3500 frames over target): <= -60 dB THD+N, no underruns.
        let idle = Self.servoRun(driftPpm: 200)
        print("SERVO idle(200ppm) THD+N worst \(idle.worst) median \(idle.median) dB underruns \(idle.underruns)")
        #expect(idle.worst < -100 && idle.underruns == 0)
        let busy = Self.servoRun(driftPpm: 200, seconds: 20, extraFrames: 4000)
        print("SERVO correcting THD+N worst \(busy.worst) median \(busy.median) dB underruns \(busy.underruns) servoPpm \(busy.ppm)")
        #expect(busy.median < -80 && busy.worst < -55 && busy.underruns == 0)
    }

    @Test func mutedMicIsExactSilence() {
        for jitter in [0.0, 60.0] {
            let m = AudioMixer(jitterTargetMs: jitter); var s = settings(); s.mic.mute = true; m.settings = s
            var worst: Float = 0
            for it in 0..<200 {
                m.push(id: AudioMixer.micID, left: (0..<480).map { _ in Float.random(in: -0.05...0.05) }, right: (0..<480).map { _ in Float.random(in: -0.05...0.05) })
                let o = m.renderOffline(frames: 480)
                if it > 10 { worst = max(worst, o.l.map { abs($0) }.max()!, o.r.map { abs($0) }.max()!) }
            }
            #expect(worst == 0, "muted mic leaked \(worst) (jitter \(jitter))")
            // disabled mic (capture stopped / micEnabled false) behaves the same; unmuting brings audio back
            s.mic.mute = false; s.micEnabled = false; m.settings = s
            for _ in 0..<20 { m.push(id: AudioMixer.micID, left: [Float](repeating: 0.1, count: 480)); #expect(m.renderOffline(frames: 480).l.allSatisfy { $0 == 0 }) }
            s.micEnabled = true; m.settings = s
            var heard: Float = 0
            for _ in 0..<60 { m.push(id: AudioMixer.micID, left: sine(300, 0.3, count: 480)); heard = max(heard, m.renderOffline(frames: 480).l.map { abs($0) }.max()!) }
            #expect(heard > 0.01, "mic did not come back (jitter \(jitter))")
        }
    }

    @Test func idleMixIsDigitalSilence() {
        // mic off, phone present but silent, inactive phone with signal: output is exactly zero (-inf dBFS)
        let m = AudioMixer(jitterTargetMs: 60); m.addSource(id: "device:a", active: true, jitterMs: 150); m.addSource(id: "device:b", active: false, jitterMs: 150)
        var s = settings(); s.micEnabled = false; m.settings = s
        var worst: Float = 0
        for it in 0..<300 {
            m.push(id: "device:a", left: [Float](repeating: 0, count: 480)); m.push(id: "device:b", left: sine(440, 0.5, count: 480))
            let o = m.renderOffline(frames: 480); if it > 20 { worst = max(worst, o.l.map { abs($0) }.max()!) }
        }
        #expect(worst == 0, "idle noise \(20 * log10(Double(worst))) dBFS")
    }

    @Test func underrunConcealmentHasNoClicks() {
        let m = AudioMixer(jitterTargetMs: 60); m.addSource(id: "device:a", active: true, jitterMs: 60); m.settings = settings()
        var out = [Float](), pos = 0
        for it in 0..<200 {
            if it < 60 || it > 80 { m.push(id: "device:a", left: sine(1000, 0.5, from: pos, count: 480)) }   // 200 ms gap in the feed
            pos += 480
            out += m.renderOffline(frames: 480).l
        }
        var maxStep: Float = 0
        for i in 3000..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        let natural = Float(0.5 * 2 * Double.pi * 1000 / sr)
        #expect(m.inputStats(id: "device:a").underruns >= 1)
        #expect(maxStep < natural * 1.3, "step \(maxStep) vs natural \(natural)")
    }

    @Test func masterStaysBelowMinusOneDbTruePeak() {
        let m = AudioMixer(jitterTargetMs: 0)
        for k in 0..<3 { m.addSource(id: "device:\(k)", active: true) }
        m.settings = settings()
        for k in 0..<3 { m.push(id: "device:\(k)", left: sine(900 + Double(k) * 1733, 0.8, count: 48_000)) }
        let o = m.renderOffline(frames: 48_000).l
        var peak: Float = 0
        for i in 2000..<(o.count - 2) {      // 4x Catmull-Rom oversampled peak
            peak = max(peak, abs(o[i]))
            for f in [0.25, 0.5, 0.75] as [Float] {
                let a = o[i - 1], b = o[i], c = o[i + 1], d = o[i + 2]
                peak = max(peak, abs(0.5 * ((2 * b) + (-a + c) * f + (2 * a - 5 * b + 4 * c - d) * f * f + (-a + 3 * b - 3 * c + d) * f * f * f)))
            }
        }
        print("MASTER true peak \(20 * log10(Double(peak))) dBFS")
        #expect(peak <= Float(pow(10, -0.9 / 20)))
    }

    @Test func lookaheadLimiterIsTransparentBelowCeiling() {
        var lim = LookaheadLimiter(); lim.ceilingDb = -1
        var x = sine(440, 0.3, count: 9600); var y = x
        x.withUnsafeMutableBufferPointer { a in y.withUnsafeMutableBufferPointer { b in lim.process(a.baseAddress!, b.baseAddress!, 9600) } }
        let ref = sine(440, 0.3, count: 9600), d = LookaheadLimiter.lookahead - 1
        #expect((1000..<9000).allSatisfy { abs(x[$0] - ref[$0 - d]) < 1e-6 })
    }

    @Test func denoiserReducesNoiseKeepsTone() {
        let d = SpectralDenoiser(); d.strength = 0.7
        var seed: UInt64 = 1
        func noise() -> Float { var a: Float = 0; for _ in 0..<6 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; a += Float(seed >> 40) / Float(1 << 24) - 0.5 }; return a * 0.0035 }   // ~ -50 dBFS RMS
        let n = 96_000
        var l = (0..<n).map { i in noise() + (i >= 48_000 ? 0.2 * Float(sin(2 * Double.pi * 440 * Double(i) / sr)) : 0) }; var r = l
        let inNoise = (l[20_000..<40_000].reduce(0) { $0 + $1 * $1 } / 20_000).squareRoot()
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in d.process(a.baseAddress!, b.baseAddress!, n) } }
        let outNoise = (l[40_000..<47_000].reduce(0) { $0 + $1 * $1 } / 7_000).squareRoot()
        let tone = fit(l, 440, 60_000, 90_000).amp
        print("DENOISE noise \(20 * log10(Double(inNoise))) -> \(20 * log10(Double(outNoise))) dBFS, tone amp \(tone)")
        #expect(20 * log10(Double(inNoise / outNoise)) > 10)
        #expect(abs(20 * log10(tone / 0.2)) < 1.0, "tone \(tone)")
    }

    @Test func denoiserLatencyIs512AndUnityOnLoudSignal() {
        let d = SpectralDenoiser(); d.strength = 0
        var l = [Float](repeating: 0, count: 9600)
        for i in 0..<9600 { l[i] = i < 4800 ? 0.0005 * Float(sin(Double(i) * 1.7)) : 0.5 * Float(sin(2 * Double.pi * 2000 * Double(i) / sr)) }
        var r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in d.process(a.baseAddress!, b.baseAddress!, 9600) } }
        let ref = sine(2000, 0.5, count: 9600)
        var err: Float = 0
        for i in 6500..<9000 { err = max(err, abs(l[i] - ref[i - SpectralDenoiser.latencyFrames])) }
        #expect(err < 0.03, "delay-aligned error \(err)")
    }

    @Test func micMuteWithDenoiserOnStaysExactZero() {
        let m = AudioMixer(jitterTargetMs: 0); var s = settings(); s.voice.denoiseOn = true; s.mic.mute = true; m.settings = s
        m.push(id: AudioMixer.micID, left: (0..<48_000).map { _ in Float.random(in: -0.02...0.02) })
        #expect(m.renderOffline(frames: 48_000).l.dropFirst(2000).allSatisfy { $0 == 0 })
    }

    @Test func aacRoundTripSNR() throws {
        let enc = AudioEncoder(); var data = Data()
        enc.onFrame = { adts, _ in data.append(adts) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let total = 48_000 * 3
        var pos = 0
        while pos < total {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!; b.frameLength = 1024
            for i in 0..<1024 { let v = 0.4 * Float(sin(2 * Double.pi * 1000 * Double(pos + i) / sr)); b.floatChannelData![0][i] = v; b.floatChannelData![1][i] = v }
            enc.feed(b, pts: Double(pos) / sr); pos += 1024
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "aacsnr-\(UUID().uuidString).aac"); try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let x = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        #expect(x.count > 100_000)
        let r = fit(x, 1000, 20_000, 20_000 + 48_000)
        print("AAC 192k roundtrip: amp \(r.amp) THD+N \(r.thdn) dB, bytes \(data.count) -> \(Double(data.count) * 8 / 3 / 1000) kbps")
        #expect(abs(r.amp - 0.4) < 0.01)
        #expect(r.thdn < -30, "SNR \(-r.thdn) dB")
        #expect(AudioEncoder.bitRate == 192_000)
    }

    @Test func bluetoothHFP24kMonoChunkedConversionIsClean() {
        let m = AudioMixer(jitterTargetMs: 0); m.addSource(id: "device:a", active: true); m.settings = settings()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        var pos = 0
        while pos < 48_000 {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 240)!; b.frameLength = 240
            for i in 0..<240 { b.floatChannelData![0][i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(pos + i) / 24_000)) }
            m.push(id: "device:a", buffers: b); pos += 240
        }
        let o = m.renderOffline(frames: 90_000).l
        let r = fit(o, 1000, 20_000, 68_000)
        print("HFP 24k->48k THD+N \(r.thdn) dB amp \(r.amp)")
        #expect(r.thdn < -60 && abs(r.amp - 0.5) < 0.01)
    }
}

@Suite struct SincTests {
    @Test func fracSweep() {
        let cap = 4096
        let x = (0..<cap).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / sr)) }
        var worst = 0.0, at = 0.0
        for k in 0..<1000 { let f = Double(k) / 1000; let a = Sinc.interpolate(x, x, cap, 1000, f).0; let e = abs(Double(a) - 0.5 * sin(2 * Double.pi * 1000 * (1000 + f) / sr)); if e > worst { worst = e; at = f } }
        print("SINCSWEEP worst \(worst) at \(at)")
    }
    @Test func ratioSweepAccuracy() {
        let cap = 100_000
        let x = (0..<cap).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / sr)) }
        var out = [Float](); var rd = 100, frac = 0.0
        for _ in 0..<20_000 { out.append(Sinc.interpolate(x, x, cap, rd, frac).0); frac += 1.0014; while frac >= 1 { frac -= 1; rd += 1 } }
        var worstE = 0.0, wn = 0
        for n in 0..<out.count { var pos = 100.0 + Double(n) * 1.0014; let e = abs(Double(out[n]) - 0.5 * sin(2 * Double.pi * 1000 * pos / sr)); if e > worstE { worstE = e; wn = n } }
        print("SINCRATIO direct worst \(worstE) at n=\(wn)")
        print("SINCRATIO thdn \(fitBest(out, 1000, 5000, 5960)) exact f \(fit(out, 1000 * 1.0014 * 1.0, 5000, 5960).thdn) \(fit(out, 1000 / 1.0014, 5000, 5960).thdn)")
    }
    @Test func fractionalDelayAccuracy() {
        let cap = 4096
        for f in [1000.0, 8000.0, 15000.0] {
            let x = (0..<cap).map { Float(sin(2 * Double.pi * f * Double($0) / sr)) }
            var worst = 0.0
            for frac in [0.0, 0.1, 0.37, 0.5, 0.93] {
                for rd in [100, 777, 2000] {
                    let (a, _) = Sinc.interpolate(x, x, cap, rd, frac)
                    let truth = sin(2 * Double.pi * f * (Double(rd) + frac) / sr)
                    worst = max(worst, abs(Double(a) - truth))
                }
            }
            print("SINC \(f) Hz worst error \(20 * log10(max(worst, 1e-12))) dB")
        }
    }
}
