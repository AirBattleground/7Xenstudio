import Testing
import Foundation
import AVFoundation
@testable import Studio

// Hot-source overload: a dense, loud stereo "game" feed (noise beds + gunshot transients, peaks ~0 dBFS, RMS ~-10 dBFS) through
// the real mixer (fader +6 dB, master limiter) and the real AAC encoder, decoded again. Guards against the "clean at the start,
// then cracking" recording: overs after the AAC round trip, limiter distortion, clipped / collapsed reader output.

private let sr = 48_000.0

// MARK: signal + measurement helpers

/// Deterministic stereo game-like programme: decorrelated (rho ~0.5) band-limited noise beds with bursty envelopes, gunshot
/// transients (instant attack, 80-200 ms decay), normalised so the sample peak is `peak` and the RMS lands near -10 dBFS.
private func gameSignal(seconds: Double, peak: Float = 0.98, bed: Float = 1, drive: Float = 0, bandHz: Double = 16_000, seed s0: UInt64 = 7) -> (l: [Float], r: [Float]) {
    let n = Int(seconds * sr)
    var seed = s0
    func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000 - 1 }
    var l = [Float](repeating: 0, count: n), r = l
    var lpC: Float = 0, lpL: Float = 0, lpR: Float = 0, env: Float = 0.5, envT: Float = 0.5, nextEnv = 0
    var shot: Float = 0, shotDecay: Float = 0.999, nextShot = 4800
    for i in 0..<n {
        if i >= nextEnv { envT = bed * (0.15 + 0.85 * abs(rnd())); nextEnv = i + Int(2400 + abs(rnd()) * 14_400) }
        env += (envT - env) * 0.002
        if i >= nextShot { shot = 0.9 + 0.1 * abs(rnd()); shotDecay = Float(exp(-1 / ((0.08 + 0.12 * Double(abs(rnd()))) * sr / 4))); nextShot = i + Int(14_400 + abs(rnd()) * 19_200) }
        shot *= shotDecay
        let c = rnd(), a = rnd(), b = rnd()
        lpC += (c - lpC) * 0.35; lpL += (a - lpL) * 0.5; lpR += (b - lpR) * 0.5
        let gs = rnd() * shot
        l[i] = env * (0.7 * lpC + 0.55 * lpL) + gs + 0.08 * Float(sin(2 * Double.pi * 180 * Double(i) / sr))
        r[i] = env * (0.7 * lpC + 0.55 * lpR) + 0.85 * gs + 0.08 * Float(sin(2 * Double.pi * 180 * Double(i) / sr + 0.4))
    }
    if drive > 0 {        // "mastered loud" game mix: saturate to a ~10 dB crest factor (RMS ~-10 dBFS at 0 dBFS peaks)
        let p0 = max(l.map { abs($0) }.max()!, r.map { abs($0) }.max()!), td = tanh(drive)
        for i in 0..<n { l[i] = tanh(drive * l[i] / p0) / td; r[i] = tanh(drive * r[i] / p0) / td }
    }
    // like every decoded phone feed (AAC low-passes at ~16-18 kHz): band-limit to 16 kHz with a 63-tap windowed sinc
    l = lowpass(l, bandHz); r = lowpass(r, bandHz)
    let pk = max(l.map { abs($0) }.max()!, r.map { abs($0) }.max()!)
    let g = peak / pk
    for i in 0..<n { l[i] *= g; r[i] *= g }
    return (l, r)
}

private func lowpass(_ x: [Float], _ hz: Double) -> [Float] {
    let n = 63, c = Double(n - 1) / 2, fc = hz / sr
    var h = (0..<n).map { k -> Double in
        let t = Double(k) - c
        let s = t == 0 ? 2 * fc : sin(2 * Double.pi * fc * t) / (Double.pi * t)
        return s * (0.42 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(k) / Double(n - 1)))
    }
    let sum = h.reduce(0, +); h = h.map { $0 / sum }
    let hf = h.map { Float($0) }
    var y = [Float](repeating: 0, count: x.count)
    x.withUnsafeBufferPointer { p in
        for i in 0..<x.count { var a: Float = 0; for k in 0..<n where i - k >= 0 { a += hf[k] * p[i - k] }; y[i] = a }
    }
    return y
}
/// RMS of x above 8 kHz relative to its total RMS (dB): limiter distortion products when the programme itself stops at 4 kHz.
private func hfProductsDb(_ x: [Float]) -> Double {
    let lp = lowpass(x, 8_000)
    var hf = [Float](repeating: 0, count: x.count)
    for i in 31..<x.count { hf[i] = x[i - 31] - lp[i] }                       // linear-phase complement: x delayed - lowpass
    return rmsDb(hf[200...]) - rmsDb(x[200...])
}
private func sine(_ f: Double, _ amp: Float, count: Int) -> [Float] { (0..<count).map { amp * Float(sin(2 * Double.pi * f * Double($0) / sr)) } }

/// Free-phase sine fit over x[a..<b]: (amplitude, THD+N dB relative to the tone).
private func fit(_ x: [Float], _ f: Double, _ a: Int, _ b: Int) -> (amp: Double, thdn: Double) {
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

/// 4x oversampled true peak (32-tap-per-phase Kaiser windowed sinc), linear.
func overloadTruePeak(_ x: [Float]) -> Float {
    let half = 16
    var taps = [[Float]]()
    for f in [0.25, 0.5, 0.75] {
        var row = [Double](); var sum = 0.0
        for k in 0..<(2 * half) {
            let d = Double(k - half + 1) - f
            let s = sin(Double.pi * d) / (Double.pi * d), u = d / Double(half)
            let w = abs(u) >= 1 ? 0 : besselI0(8 * (1 - u * u).squareRoot()) / besselI0(8)
            row.append(s * w); sum += s * w
        }
        taps.append(row.map { Float($0 / sum) })
    }
    var pk: Float = 0
    guard x.count > 2 * half else { return x.map { abs($0) }.max() ?? 0 }
    x.withUnsafeBufferPointer { p in
        for i in 0..<x.count { pk = max(pk, abs(p[i])) }
        for i in half..<(x.count - half) {
            for t in taps {
                var acc: Float = 0
                for k in 0..<(2 * half) { acc += t[k] * p[i - half + 1 + k] }
                pk = max(pk, abs(acc))
            }
        }
    }
    return pk
}
private func besselI0(_ x: Double) -> Double { var s = 1.0, t = 1.0; for k in 1..<40 { t *= (x / 2 / Double(k)) * (x / 2 / Double(k)); s += t }; return s }
private func dbfs(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-9))) }
private func rmsDb(_ x: ArraySlice<Float>) -> Double { 10 * log10(max(1e-20, x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)))) }
private func correlation(_ a: [Float], _ b: [Float]) -> Double {
    var sab = 0.0, saa = 0.0, sbb = 0.0
    for i in 0..<min(a.count, b.count) { let x = Double(a[i]), y = Double(b[i]); sab += x * y; saa += x * x; sbb += y * y }
    return sab / max(1e-20, (saa * sbb).squareRoot())
}
private func absD2(_ x: [Float]) -> [Float] {
    guard x.count >= 3 else { return [] }
    var o = [Float](repeating: 0, count: x.count - 2)
    for i in 1..<(x.count - 1) { let a: Float = x[i + 1] - 2 * x[i]; o[i - 1] = abs(a + x[i - 1]) }
    return o
}
private func percentile(_ x: [Float], _ p: Double) -> Float { let s = x.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }

/// Renders `src` through a fresh offline mixer as phone "device:a" at `faderDb` (jitter rings off, mic off, no ducking).
private func renderMix(_ src: (l: [Float], r: [Float]), faderDb: Double, configure: (inout AudioSettings) -> Void = { _ in }) -> (mixer: AudioMixer, l: [Float], r: [Float]) {
    let m = AudioMixer(jitterTargetMs: 0); m.addSource(id: "device:a", active: true)
    var s = AudioSettings(); s.phoneLatencyMs = 0; s.duck.enabled = false; s.micEnabled = false
    s.phones["device:a"] = { var c = ChannelSettings(); c.gainDb = faderDb; return c }()
    configure(&s)
    m.settings = s
    var ol = [Float](), orr = [Float](); ol.reserveCapacity(src.l.count); orr.reserveCapacity(src.l.count)
    var pos = 0
    while pos < src.l.count {
        let k = min(1024, src.l.count - pos)
        m.push(id: "device:a", left: Array(src.l[pos..<pos + k]), right: Array(src.r[pos..<pos + k]))
        let o = m.renderOffline(frames: k); ol += o.l; orr += o.r; pos += k
    }
    return (m, ol, orr)
}

/// Real AudioEncoder (AAC-LC 192k) -> ADTS file -> Apple decoder. Returns the decoded stereo.
private func aacRoundTrip(_ l: [Float], _ r: [Float], keep path: String? = nil) throws -> (l: [Float], r: [Float]) {
    let enc = AudioEncoder(); var data = Data()
    enc.onFrame = { adts, _ in data.append(adts) }
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    var pos = 0
    while pos + 1024 <= l.count {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!; b.frameLength = 1024
        for i in 0..<1024 { b.floatChannelData![0][i] = l[pos + i]; b.floatChannelData![1][i] = r[pos + i] }
        enc.feed(b, pts: Double(pos) / sr); pos += 1024
    }
    let url = URL(fileURLWithPath: path ?? (NSTemporaryDirectory() + "overload-\(UUID().uuidString).aac"))
    try data.write(to: url); defer { if path == nil { try? FileManager.default.removeItem(at: url) } }
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let n = Int(buf.frameLength)
    return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)),
            Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)))
}

private struct OverloadReport: CustomStringConvertible {
    var truePeakDb = 0.0, samplePeakDb = 0.0, overPct = 0.0, clicksPerSec = 0.0, refClicksPerSec = 0.0, corr = 0.0, rms = 0.0
    var description: String {
        String(format: "TP %+.2f dBTP  sample pk %+.2f dBFS  >1.0 %.4f%%  clicks %.0f/s (clean ref %.0f/s)  L/R corr %.3f  RMS %.1f dBFS",
               truePeakDb, samplePeakDb, overPct, clicksPerSec, refClicksPerSec, corr, rms)
    }
}
/// `ref` = the same programme decoded clean (rendered well below the limiter), used for the click threshold at matched RMS.
private func measure(_ x: (l: [Float], r: [Float]), ref: (l: [Float], r: [Float]), skip: Int = 9600) -> OverloadReport {
    let l = Array(x.l.dropFirst(skip)), r = Array(x.r.dropFirst(skip))
    let rl = Array(ref.l.dropFirst(skip))
    var o = OverloadReport()
    o.truePeakDb = dbfs(max(overloadTruePeak(l), overloadTruePeak(r)))
    o.samplePeakDb = dbfs(max(l.map { abs($0) }.max() ?? 0, r.map { abs($0) }.max() ?? 0))
    o.overPct = 100 * Double(l.filter { abs($0) > 1 }.count + r.filter { abs($0) > 1 }.count) / Double(2 * max(1, l.count))
    o.rms = rmsDb(l[...])
    let gain = Float(pow(10, (o.rms - rmsDb(rl[...])) / 20))
    let refD2 = absD2(rl.map { $0 * gain })
    let thr = percentile(refD2, 0.999)
    o.refClicksPerSec = Double(refD2.filter { $0 > thr }.count) / (Double(rl.count) / sr)
    o.clicksPerSec = Double(absD2(l).filter { $0 > thr }.count) / (Double(l.count) / sr)
    o.corr = correlation(l, r)
    return o
}

private func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit(); return p.terminationStatus
}
private func writeWav(_ l: [Float], _ r: [Float], _ path: String) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count))!; b.frameLength = AVAudioFrameCount(l.count)
    for i in 0..<l.count { b.floatChannelData![0][i] = l[i]; b.floatChannelData![1][i] = r[i] }
    let f = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
    try f.write(from: b)
}

// MARK: probe (numbers for the report; always runs, prints only)

@Suite(.serialized) struct AudioOverloadProbe {
    @Test func probeHotPhoneThroughMixerAndAAC() throws {
        let src = gameSignal(seconds: 12)
        print("OVERLOAD source: RMS \(String(format: "%.1f", rmsDb(src.l[...]))) dBFS  TP \(String(format: "%+.2f", dbfs(max(overloadTruePeak(src.l), overloadTruePeak(src.r))))) dBTP  corr \(String(format: "%.3f", correlation(src.l, src.r)))")
        let clean = renderMix(src, faderDb: -12)
        let refDec = try aacRoundTrip(clean.l, clean.r)
        for fader in [0.0, 6.0] {
            let mx = renderMix(src, faderDb: fader)
            let keep = ProcessInfo.processInfo.environment["OVERLOAD_DIR"].map { "\($0)/hot\(Int(fader)).aac" }
            if let d = ProcessInfo.processInfo.environment["OVERLOAD_DIR"] { try writeWav(mx.l, mx.r, "\(d)/mix\(Int(fader)).wav") }
            let dec = try aacRoundTrip(mx.l, mx.r, keep: keep)
            print("OVERLOAD fader \(fader) mixer-out: \(measure((mx.l, mx.r), ref: (clean.l, clean.r)))")
            print("OVERLOAD fader \(fader) AAC-decoded: \(measure(dec, ref: refDec))")
        }
        // heavy limiting: dense programme ~-10 dBFS RMS band-limited to 4 kHz, so everything the chain adds above 8 kHz is
        // distortion (hard clipping / waveform-following gain = the audible "crackle")
        let dense = gameSignal(seconds: 8, bed: 3, drive: 3, bandHz: 4_000, seed: 11)
        print("OVERLOAD dense source: RMS \(String(format: "%.1f", rmsDb(dense.l[...]))) dBFS, HF products \(String(format: "%.1f", hfProductsDb(dense.l))) dB")
        for fader in [0.0, 6.0] {
            let mx = renderMix(dense, faderDb: fader)
            let dec = try aacRoundTrip(mx.l, mx.r)
            print(String(format: "OVERLOAD dense fader %+.0f: mixer RMS %.1f TP %+.2f dBTP HF products %.1f dB | AAC TP %+.2f dBTP >1.0 %.4f%% HF products %.1f dB",
                         fader, rmsDb(mx.l.dropFirst(9600)), dbfs(max(overloadTruePeak(Array(mx.l.dropFirst(9600))), overloadTruePeak(Array(mx.r.dropFirst(9600))))),
                         hfProductsDb(Array(mx.l.dropFirst(9600))), dbfs(max(overloadTruePeak(Array(dec.l.dropFirst(9600))), overloadTruePeak(Array(dec.r.dropFirst(9600))))),
                         100 * Double(dec.l.filter { abs($0) > 1 }.count) / Double(dec.l.count), hfProductsDb(Array(dec.l.dropFirst(9600)))))
        }
        // THD+N on a 1 kHz tone at -6 dBFS (fader 0) and the same tone pushed +6 dB (into the guard / limiter)
        for (amp, fader) in [(Float(0.5), 0.0), (Float(0.5), 6.0), (Float(0.9), 6.0)] {
            let t = sine(1000, amp, count: 96_000)
            let mx = renderMix((t, t), faderDb: fader)
            let dec = try aacRoundTrip(mx.l, mx.r)
            let a = fit(mx.l, 1000, 48_000, 96_000), b = fit(dec.l, 1000, 48_000, 90_000)
            print(String(format: "OVERLOAD tone %.2f fader %+.0f: mixer amp %.3f THD+N %.1f dB | AAC TP %+.2f dBTP THD+N %.1f dB",
                         amp, fader, a.amp, a.thdn, dbfs(overloadTruePeak(Array(dec.l.dropFirst(9600)))), b.thdn))
        }
    }

    /// The phone reader on a real stereo AAC file (ffmpeg): stereo kept, float kept (values above 1.0 survive), level unity.
    @Test func probeReaderOnStereoAAC() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let dir = NSTemporaryDirectory() + "overload-reader-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = gameSignal(seconds: 4)
        try writeWav(src.l, src.r, dir + "/src.wav")
        #expect(runTool(ff, ["-v", "error", "-y", "-i", dir + "/src.wav", "-c:a", "aac", "-b:a", "192k", dir + "/src.m4a"]) == 0)
        final class Box: @unchecked Sendable { let lock = NSLock(); var l = [Float](), r = [Float]() }
        let box = Box()
        let rd = PhoneAudioReader(input: dir + "/src.m4a", ffmpegPath: ff) { l, r in box.lock.withLock { box.l += l; box.r += r } }
        rd.start(); defer { rd.stop() }
        for _ in 0..<100 where box.lock.withLock({ box.l.count }) < 4 * 48_000 - 4096 { try await Task.sleep(nanoseconds: 50_000_000) }
        rd.stop()
        let (l, r) = box.lock.withLock { (box.l, box.r) }
        print("OVERLOAD reader: frames \(l.count) peak L \(l.map { abs($0) }.max() ?? 0) R \(r.map { abs($0) }.max() ?? 0) corr \(correlation(l, r)) (source corr \(correlation(src.l, src.r))) rms \(rmsDb(l[...])) vs src \(rmsDb(src.l[...]))")
    }
}

// MARK: regression tests

@Suite(.serialized) struct AudioOverloadRegressionTests {
    /// The user's case: a hot phone (peaks ~0 dBFS) with its fader at +6 dB. Nothing may exceed -0.5 dBFS after the AAC round trip.
    @Test func hotSourceAtPlusSixHasNoOversAfterAAC() throws {
        let src = gameSignal(seconds: 4, bed: 3, drive: 3, seed: 21)
        let mx = renderMix(src, faderDb: 6)
        let tl = Array(mx.l.dropFirst(4800)), tr = Array(mx.r.dropFirst(4800))
        let mixTP = dbfs(max(overloadTruePeak(tl), overloadTruePeak(tr)))
        let dec = try aacRoundTrip(mx.l, mx.r)
        let dl = Array(dec.l.dropFirst(4800)), dr = Array(dec.r.dropFirst(4800))
        let pk = max(dl.map { abs($0) }.max() ?? 0, dr.map { abs($0) }.max() ?? 0)
        let overs = dl.filter { abs($0) > 1 }.count + dr.filter { abs($0) > 1 }.count
        print("OVERLOAD regression: mixer TP \(mixTP) dBTP, AAC sample peak \(dbfs(pk)) dBFS, overs \(overs)")
        #expect(mixTP <= -1.8, "mixer true peak \(mixTP) dBTP")
        #expect(dbfs(pk) <= -0.5, "decoded peak \(dbfs(pk)) dBFS")
        #expect(overs == 0)
        #expect(correlation(dl, dr) < 0.9, "stereo collapsed")
    }

    /// Below the knee the whole chain (input guard + master limiter) is bit-transparent apart from the look-ahead delay.
    @Test func chainIsTransparentAtMinus6() {
        let t = sine(1000, 0.5, count: 48_000)
        let mx = renderMix((t, t), faderDb: 0)
        let f = fit(mx.l, 1000, 9600, 48_000)
        #expect(abs(f.amp - 0.5) < 1e-4)
        #expect(f.thdn < -60, "THD+N \(f.thdn) dB")
        let d = LookaheadLimiter.lookahead - 1
        #expect((9600..<48_000).allSatisfy { abs(mx.l[$0] - t[$0 - d]) < 1e-6 })
        // the guard on its own: exact unity below -3 dBFS
        var g = InputGuard(); var l = sine(440, 0.7, count: 9600), r = l
        let ref = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in g.process(a.baseAddress!, b.baseAddress!, 9600) } }
        #expect(l == ref)
    }

    /// A tone pushed into the guard and limiter stays clean (gain, not waveform, is changed) and lands at the true-peak ceiling.
    @Test func sustainedOverloadStaysClean() {
        let t = sine(1000, 0.9, count: 96_000)
        let mx = renderMix((t, t), faderDb: 6)
        let f = fit(mx.l, 1000, 48_000, 96_000)
        #expect(f.thdn < -60, "THD+N \(f.thdn) dB")
        #expect(dbfs(overloadTruePeak(Array(mx.l[48_000...]))) <= -1.95)
    }

    /// Transients: a gunshot on a quiet bed is caught below the ceiling with no hard clipping, the gain recovers quickly after an
    /// isolated hit (fast release) but slowly after seconds of heavy limiting (program-dependent release: no pumping).
    @Test func transientHandling() {
        var lim = LookaheadLimiter()
        let n = 48_000
        var l = sine(200, 0.1, count: n)
        for i in 10_000..<10_480 { l[i] += 1.8 * Float(exp(-Double(i - 10_000) / 100)) * (i % 2 == 0 ? 1 : -1) * Float(sin(Double(i) * 0.3)) }
        var r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in lim.process(a.baseAddress!, b.baseAddress!, n) } }
        let ceil = Float(pow(10, lim.ceilingDb / 20))
        #expect(l.map { abs($0) }.max()! <= ceil + 1e-6)
        #expect(l.filter { abs($0) >= ceil - 1e-6 }.count < 6, "flat-topped (hard clamped) samples")
        // 200 Hz bed level 150 ms after the hit: back within 1 dB
        let d = LookaheadLimiter.lookahead - 1, at = 10_480 + 7200 + d
        let amp = fit(l, 200, at, at + 2400).amp
        #expect(amp > 0.1 * 0.89, "bed after transient \(amp)")

        // sustained: 3 s of heavy limiting, then the bed alone -> still > 1 dB reduced 100 ms later (slow release)
        var lim2 = LookaheadLimiter()
        let m = 4 * 48_000
        var x = (0..<m).map { i -> Float in i < 3 * 48_000 ? 2.0 * Float(sin(2 * Double.pi * 300 * Double(i) / sr)) : 0.1 * Float(sin(2 * Double.pi * 200 * Double(i) / sr)) }
        var y = x
        x.withUnsafeMutableBufferPointer { a in y.withUnsafeMutableBufferPointer { b in lim2.process(a.baseAddress!, b.baseAddress!, m) } }
        let a2 = fit(x, 200, 3 * 48_000 + 4800 + d, 3 * 48_000 + 7200 + d).amp
        #expect(a2 < 0.1 * 0.89, "sustained limiting released too fast: \(a2)")
    }

    /// CLIP LED: lit by a source at -0.3 dBFS (pre-fader) or by a +6 dB fader pushing a -2 dBFS source into the guard; dark for a
    /// -6 dBFS source at 0 dB; latched ~1.5 s.
    @Test func clipLEDShowsHotInputs() {
        func clip(_ amp: Float, fader: Double) -> (Bool, AudioMixer) {
            let t = sine(440, amp, count: 9600)
            let mx = renderMix((t, t), faderDb: fader)
            return (mx.mixer.meters().channels["device:a"]?.clip ?? false, mx.mixer)
        }
        #expect(clip(0.5, fader: 0).0 == false)
        #expect(clip(0.97, fader: -10).0 == true)               // pre-fader: the source itself is too hot
        let (on, m) = clip(0.8, fader: 6)                      // post-fader into the guard
        #expect(on)
        _ = m.renderOffline(frames: 48_000)                   // silence for 1 s: still latched
        #expect(m.meters().channels["device:a"]?.clip == true)
        _ = m.renderOffline(frames: 48_000)
        #expect(m.meters().channels["device:a"]?.clip == false)
    }

    /// The phone reader keeps real stereo and float samples: values above 1.0 are not clipped, L/R stay independent, mono upmixes at unity.
    @Test func readerKeepsStereoAndFloat() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let dir = NSTemporaryDirectory() + "overload-rd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(atPath: dir) }
        let n = 48_000 * 2
        try writeWav(sine(440, 1.4, count: n), sine(1000, 0.5, count: n), dir + "/st.wav")       // L above full scale (float)
        #expect(runTool(ff, ["-v", "error", "-y", "-i", dir + "/st.wav", "-c:a", "pcm_f32le", dir + "/st.mkv"]) == 0)
        #expect(runTool(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=700:sample_rate=48000:duration=2", "-af", "volume=4", "-ac", "1", "-c:a", "pcm_f32le", dir + "/mono.mkv"]) == 0)
        final class Box: @unchecked Sendable { let lock = NSLock(); var l = [Float](), r = [Float]() }
        func read(_ path: String) async throws -> ([Float], [Float]) {
            let box = Box()
            let rd = PhoneAudioReader(input: path, ffmpegPath: ff) { l, r in box.lock.withLock { box.l += l; box.r += r } }
            rd.start()
            for _ in 0..<100 where box.lock.withLock({ box.l.count }) < n - 1024 { try await Task.sleep(nanoseconds: 30_000_000) }
            rd.stop()
            return box.lock.withLock { (box.l, box.r) }
        }
        let (l, r) = try await read(dir + "/st.mkv")
        #expect(l.count >= n - 1024)
        guard l.count >= 48_000 else { return }
        let fl = fit(l, 440, 4800, 48_000), fr = fit(r, 1000, 4800, 48_000)
        print("OVERLOAD reader stereo: L amp \(fl.amp) THD+N \(fl.thdn), R amp \(fr.amp), corr \(correlation(l, r))")
        #expect(abs(fl.amp - 1.4) < 0.01 && fl.thdn < -60, "L clipped or altered: \(fl)")
        #expect(abs(fr.amp - 0.5) < 0.01 && fit(r, 440, 4800, 48_000).amp < 0.001, "R not independent")
        let (ml, mr) = try await read(dir + "/mono.mkv")
        #expect(ml.count >= n - 1024 && ml == mr)
        guard ml.count >= 48_000 else { return }
        #expect(abs(fit(ml, 700, 4800, 48_000).amp - 0.5) < 0.01)
    }

    /// Recording mux: the fragmented MP4 must carry the AAC AudioSpecificConfig (with empty_moov it did not and AVFoundation /
    /// QuickTime showed no audio track at all).
    @Test func recordingMP4CarriesAACConfig() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let dir = NSTemporaryDirectory() + "overload-mp4-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(runTool(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=3:r=30:s=320x240", "-f", "lavfi", "-i", "sine=d=3:sample_rate=48000",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-f", "mpegts", dir + "/in.ts"]) == 0)
        let (args, _) = FFmpegArgs.make(recording: dir + "/rec.mp4", hevcRecording: false, destinations: [], preview: nil)
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = args
        p.standardInput = FileHandle(forReadingAtPath: dir + "/in.ts"); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let tracks = try await AVURLAsset(url: URL(fileURLWithPath: dir + "/rec.mp4")).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "AVFoundation sees no audio track in the recording")
    }
}
