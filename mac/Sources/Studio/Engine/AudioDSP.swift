// Pure audio DSP building blocks for the mixer (48 kHz float, in-place block processing). No AVFoundation here so the
// math is unit-testable offline. Everything is single-threaded: the mixer calls it from its render queue.
import Foundation
import Accelerate

enum AudioMath {
    /// Fader floor: at or below this the channel is treated as silent (-inf).
    static let floorDb: Double = -60
    static func dbToLinear(_ db: Double) -> Float { db <= floorDb ? 0 : Float(pow(10, db / 20)) }
    static func linearToDb(_ lin: Float) -> Double { lin <= 1e-6 ? -120 : 20 * log10(Double(lin)) }
    /// One-pole smoothing coefficient for a time constant in ms at `sr` (0 = instant).
    static func coef(ms: Double, sr: Double = AudioMixer.sampleRate) -> Float {
        ms <= 0 ? 1 : Float(1 - exp(-1 / (ms / 1000 * sr)))
    }
    /// Fader law: position 0...1 <-> dB, piecewise linear with 0 dB at 80 % of the travel (+6 dB at the top, -inf at the bottom).
    private static let taper: [(p: Double, db: Double)] = [(0, -60), (0.1, -40), (0.3, -20), (0.5, -10), (0.8, 0), (1, 6)]
    static func faderDb(position p: Double) -> Double {
        let x = min(max(p, 0), 1)
        for i in 1..<taper.count where x <= taper[i].p {
            let a = taper[i - 1], b = taper[i]
            return a.db + (b.db - a.db) * (x - a.p) / (b.p - a.p)
        }
        return taper.last!.db
    }
    static func faderPosition(db: Double) -> Double {
        let d = min(max(db, taper.first!.db), taper.last!.db)
        for i in 1..<taper.count where d <= taper[i].db {
            let a = taper[i - 1], b = taper[i]
            return a.p + (b.p - a.p) * (d - a.db) / (b.db - a.db)
        }
        return 1
    }
    static func msToFrames(_ ms: Double) -> Int { max(0, Int((ms / 1000 * AudioMixer.sampleRate).rounded())) }
}

/// 2nd order Butterworth high-pass (rumble / handling noise). Stereo, transposed direct form II.
struct HighPass {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1 = [Float](repeating: 0, count: 2), z2 = [Float](repeating: 0, count: 2)
    private(set) var cutoff: Double = 0
    init(cutoff: Double = 80) { configure(cutoff: cutoff) }
    mutating func configure(cutoff fc: Double, sr: Double = AudioMixer.sampleRate) {
        guard fc != cutoff else { return }
        cutoff = fc
        let w0 = 2 * Double.pi * fc / sr, cosw = cos(w0), alpha = sin(w0) / (2 * 0.70710678)
        let a0 = 1 + alpha
        b0 = Float((1 + cosw) / 2 / a0); b1 = Float(-(1 + cosw) / a0); b2 = b0
        a1 = Float(-2 * cosw / a0); a2 = Float((1 - alpha) / a0)
    }
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for (c, p) in [l, r].enumerated() {
            var s1 = z1[c], s2 = z2[c]
            for i in 0..<n {
                let x = p[i]
                let y = b0 * x + s1
                s1 = b1 * x - a1 * y + s2
                s2 = b2 * x - a2 * y
                p[i] = y
            }
            // a silent input must decay to exact zero, never to denormals (CPU spikes + non-zero output)
            z1[c] = abs(s1) < 1e-20 ? 0 : s1; z2[c] = abs(s2) < 1e-20 ? 0 : s2
        }
    }
}

/// Integer-sample stereo delay with a short crossfade when the delay changes (no clicks while dragging a slider).
struct DelayLine {
    private(set) var cap: Int
    private var bl: [Float], br: [Float]
    private var w = 0
    private var current = 0            // delay in effect (frames)
    private var fadeFrom = 0, fadeLeft = 0
    static let fadeFrames = 480
    init(maxFrames: Int = AudioMath.msToFrames(4000) + 4) {
        cap = maxFrames; bl = [Float](repeating: 0, count: maxFrames); br = bl
    }
    var delayFrames: Int { current }
    private func read(_ b: [Float], _ d: Int) -> Float { b[((w - 1 - d) % cap + cap) % cap] }
    /// Processes in place. `delay` in frames (clamped to capacity).
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, delay target: Int) {
        let t = min(max(0, target), cap - 2)
        if t != current && fadeLeft == 0 { fadeFrom = current; current = t; fadeLeft = DelayLine.fadeFrames }
        else if t != current { current = t }       // retarget mid-fade: the fade finishes towards the newest value
        for i in 0..<n {
            bl[w] = l[i]; br[w] = r[i]; w = (w + 1) % cap
            // sample just written sits at delay 0 -> read(delay d) gives x[n - d]
            var ol = read(bl, current), or = read(br, current)
            if fadeLeft > 0 {
                let a = Float(DelayLine.fadeFrames - fadeLeft) / Float(DelayLine.fadeFrames)
                let ofl = read(bl, fadeFrom), ofr = read(br, fadeFrom)
                ol = ofl + (ol - ofl) * a; or = ofr + (or - ofr) * a
                fadeLeft -= 1
            }
            l[i] = ol; r[i] = or
        }
    }
}

/// Mono float delay (used to line the ducking trigger up with the delayed mic).
struct MonoDelay {
    private var b: [Float]; private var w = 0
    init(maxFrames: Int = AudioMath.msToFrames(4000) + 4) { b = [Float](repeating: 0, count: maxFrames) }
    mutating func process(_ x: UnsafeMutablePointer<Float>, _ n: Int, delay: Int) {
        let cap = b.count, d = min(max(0, delay), cap - 2)
        for i in 0..<n { b[w] = x[i]; w = (w + 1) % cap; x[i] = b[((w - 1 - d) % cap + cap) % cap] }
    }
}

/// Downward expander / gate. Produces a per-sample `open` control 0...1 (smoothed) that is also what drives the ducker.
struct NoiseGate {
    var thresholdDb = -45.0
    var reductionDb = 40.0
    var holdMs = 150.0, attackMs = 3.0, releaseMs = 120.0
    var hysteresisDb = 3.0
    private var env: Float = 0, gate: Float = 0, isOpen = false, holdLeft = 0
    private(set) var smoothedOpen: Float = 0

    /// Fills `ctl[i]` with the detector state (1 when above threshold incl. hold, else 0, smoothed) and, when `apply`,
    /// attenuates l/r by the gate gain (closed = -reductionDb).
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int,
                          ctl: UnsafeMutablePointer<Float>, apply: Bool) {
        let cEnvA = AudioMath.coef(ms: 1), cEnvR = AudioMath.coef(ms: 40)
        let cA = AudioMath.coef(ms: attackMs), cR = AudioMath.coef(ms: releaseMs)
        let hold = AudioMath.msToFrames(holdMs)
        let thOpen = Float(pow(10, thresholdDb / 20)), thClose = Float(pow(10, (thresholdDb - hysteresisDb) / 20))
        let floorG = Float(pow(10, -reductionDb / 20))
        for i in 0..<n {
            let a = max(abs(l[i]), abs(r[i]))
            env += (a - env) * (a > env ? cEnvA : cEnvR)
            if isOpen {
                if env < thClose { if holdLeft > 0 { holdLeft -= 1 } else { isOpen = false } } else { holdLeft = hold }
            } else if env > thOpen { isOpen = true; holdLeft = hold }
            let tgt: Float = isOpen ? 1 : 0
            gate += (tgt - gate) * (tgt > gate ? cA : cR)
            ctl[i] = gate
            if apply {
                let g = floorG + (1 - floorG) * gate
                l[i] *= g; r[i] *= g
            }
        }
        smoothedOpen = gate
    }
}

/// Speech detector for the auto-ducker: ~30 ms RMS of the (high-passed) mic against a threshold with 3 dB hysteresis and a hold.
/// Unlike a peak gate it ignores room noise and short clicks, so the game audio is only lowered while someone really talks.
struct SpeechDetector {
    var thresholdDb = -35.0, holdMs = 300.0, hysteresisDb = 3.0
    private var ms: Float = 0, isOpen = false, holdLeft = 0, smooth: Float = 0
    private(set) var smoothedOpen: Float = 0
    mutating func process(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int, ctl: UnsafeMutablePointer<Float>) {
        let c = AudioMath.coef(ms: 30), cS = AudioMath.coef(ms: 5)
        let hold = AudioMath.msToFrames(holdMs)
        let thOpen = Float(pow(10, thresholdDb / 10)), thClose = Float(pow(10, (thresholdDb - hysteresisDb) / 10))
        for i in 0..<n {
            ms += (0.5 * (l[i] * l[i] + r[i] * r[i]) - ms) * c
            if isOpen { if ms < thClose { if holdLeft > 0 { holdLeft -= 1 } else { isOpen = false } } else { holdLeft = hold } }
            else if ms > thOpen { isOpen = true; holdLeft = hold }
            smooth += ((isOpen ? 1 : 0) - smooth) * cS
            ctl[i] = smooth
        }
        smoothedOpen = smooth
    }
}

/// Feed-forward compressor with soft knee; detector on the louder channel (linked stereo).
struct Compressor {
    var thresholdDb = -18.0, ratio = 3.0, kneeDb = 6.0, makeupDb = 3.0
    var attackMs = 10.0, releaseMs = 150.0
    private var grDb: Float = 0           // smoothed gain reduction (>= 0)
    private(set) var lastReductionDb: Float = 0
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let cA = AudioMath.coef(ms: attackMs), cR = AudioMath.coef(ms: releaseMs)
        let t = Float(thresholdDb), knee = Float(kneeDb), slope = Float(1 - 1 / max(1, ratio))
        for i in 0..<n {
            let a = max(abs(l[i]), abs(r[i]), 1e-6)
            let x = 20 * log10(a)
            let over = x - t
            var target: Float = 0
            if 2 * over > knee { target = over * slope }
            else if 2 * over > -knee { let k = over + knee / 2; target = slope * k * k / (2 * max(knee, 1e-3)) }
            grDb += (target - grDb) * (target > grDb ? cA : cR)
            // make-up gain fades in with the gain reduction: a signal below the threshold (room noise, silence) is never boosted
            let g = pow(10, (-grDb + Float(makeupDb) * min(1, grDb / 4)) / 20)
            l[i] *= g; r[i] *= g
        }
        lastReductionDb = grDb
    }
}

/// Brickwall peak limiter: instant attack (gain follows the peak immediately), exponential release, hard ceiling.
struct Limiter {
    var ceilingDb = -1.0
    var releaseMs = 80.0
    private var gain: Float = 1
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let ceil = Float(pow(10, ceilingDb / 20)), cR = AudioMath.coef(ms: releaseMs)
        for i in 0..<n {
            let a = max(abs(l[i]), abs(r[i]))
            let need = a > ceil ? ceil / a : 1
            if need < gain { gain = need } else { gain += (1 - gain) * cR }
            var ol = l[i] * gain, or = r[i] * gain
            ol = min(max(ol, -ceil), ceil); or = min(max(or, -ceil), ceil)     // numerical safety
            l[i] = ol; r[i] = or
        }
    }
}

/// Auto-ducker: smooths a dB gain towards `-amount` while the trigger is high, back to 0 dB when low.
struct Ducker {
    var amountDb = 9.0                  // positive = how much to lower
    var attackMs = 50.0, releaseMs = 400.0
    private(set) var currentDb: Float = 0
    /// `trig[i]` 0...1 (1 = duck). Writes the linear gain to `gain[i]`.
    mutating func process(trig: UnsafePointer<Float>, gain: UnsafeMutablePointer<Float>, _ n: Int, enabled: Bool) {
        let cA = AudioMath.coef(ms: attackMs), cR = AudioMath.coef(ms: releaseMs)
        let depth = Float(-abs(amountDb))
        for i in 0..<n {
            let tgt: Float = enabled ? depth * min(max(trig[i], 0), 1) : 0
            currentDb += (tgt - currentDb) * (tgt < currentDb ? cA : cR)
            gain[i] = pow(10, currentDb / 20)
        }
    }
}

/// Peak / RMS meter state for a block stream, with a decaying peak for display.
struct MeterState {
    private(set) var peak: Float = 0           // decayed display peak (linear)
    private(set) var rms: Float = 0            // smoothed RMS (linear)
    private(set) var clipped = false
    mutating func update(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var pk: Float = 0, sum: Float = 0
        for i in 0..<n { let a = abs(l[i]), b = abs(r[i]); pk = max(pk, a, b); sum += 0.5 * (a * a + b * b) }
        let blockRMS = (sum / Float(n)).squareRoot()
        peak = max(pk, peak * 0.93)
        rms += (blockRMS - rms) * (blockRMS > rms ? 0.6 : 0.2)
        clipped = pk >= 0.999
    }
    /// Clip LED: latched for `holdSeconds` after any block flagged `over` (the operator needs to see a 1 ms over).
    private(set) var clipHoldLeft = 0
    var clipLatched: Bool { clipHoldLeft > 0 }
    mutating func flagClip(_ over: Bool, _ n: Int, holdSeconds: Double = 1.5) {
        if over { clipHoldLeft = Int(holdSeconds * AudioMixer.sampleRate) } else { clipHoldLeft = max(0, clipHoldLeft - n) }
    }
    /// Pre-fader input level at which a channel's CLIP LED lights (-0.5 dBFS).
    static let clipThreshold = Float(pow(10, -0.5 / 20))
}

/// Gain ramp helper: linear ramp from `from` to `to` across a block.
@inline(__always) func rampGain(_ from: Float, _ to: Float, _ i: Int, _ n: Int) -> Float { from + (to - from) * Float(i + 1) / Float(n) }

/// True-peak look-ahead limiter for the master bus.
/// - Detection: sample peak plus the inter-sample peaks at 1/4, 1/2 and 3/4 between samples from a 12-tap-per-phase 4x
///   polyphase interpolator (ITU-R BS.1770 style), so the AAC encoder's reconstruction overshoot stays under the ceiling. The old
///   cubic midpoint estimate missed up to +3 dB of inter-sample peak on dense, hot programme (true peak +2 dBTP at a "-1 dB" ceiling,
///   decoded AAC above 0 dBFS).
/// - Gain: sliding minimum of the required gain over the 5 ms look-ahead (monotonic deque), smoothed by two cascaded box filters
///   (an S-shaped attack with a continuous slope: no gain steps, no hard clamp in normal operation) that has fully landed before the
///   peak leaves the delay line.
/// - Release: program dependent. A one-pole tracks how much reduction has been sustained (~400 ms); isolated transients release in
///   `fastReleaseMs`, sustained heavy limiting slides towards `slowReleaseMs` (no pumping / waveform-following gain on dense audio).
/// - The final clamp at the ceiling is a last-resort numerical safety only. Latency: `lookahead - 1` frames.
struct LookaheadLimiter {
    var ceilingDb = -2.0
    var fastReleaseMs = 50.0, slowReleaseMs = 500.0
    static let lookahead = 240                                  // 5 ms
    static let ispHalf = 6                                      // 4x interpolator: 12 taps per phase, centred between x[t-6] and x[t-5]
    // coverage: a requirement written at step s holds the gain for outputs s-(L+1-B1-B2) ... s; the inter-sample peak written at step t
    // belongs to outputs t-6 / t-5, so B1 + B2 = L + 1 - (ispHalf + 1)
    static let box1 = (lookahead - ispHalf) / 2, box2 = lookahead - ispHalf - box1
    /// ISP interpolation taps (3 phases x 12), Kaiser-windowed sinc, unity DC.
    static let ispTaps: [Float] = {
        let half = ispHalf, n = 2 * ispHalf
        func i0(_ x: Double) -> Double { var s = 1.0, t = 1.0; for k in 1..<30 { t *= (x / 2 / Double(k)) * (x / 2 / Double(k)); s += t }; return s }
        var out = [Float]()
        for f in [0.25, 0.5, 0.75] {
            var row = [Double](), sum = 0.0
            for k in 0..<n {
                let x = Double(k) - Double(n - 1) + Double(half) - f        // tap k reads x[t-11+k]; target x[t-6+f]
                let s = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let u = x / Double(half)
                let w = abs(u) >= 1 ? 0 : i0(5 * (1 - u * u).squareRoot()) / i0(5)
                row.append(s * w); sum += s * w
            }
            out += row.map { Float($0 / sum) }
        }
        return out
    }()

    private let L = LookaheadLimiter.lookahead
    private var dl: [Float], dr: [Float]                        // audio delay line
    private var hl: [Float], hr: [Float], hw = 0                // detector history (12 newest inputs, ring)
    private var dqIdx: [Int], dqVal: [Float], dqHead = 0, dqCount = 0      // monotonic deque for the sliding minimum
    private var b1: [Float], b2: [Float], b1w = 0, b2w = 0
    private var s1: Double, s2: Double
    private var t = 0                                           // input sample counter (for the deque)
    private var w = 0
    private var rel: Float = 1
    private var sustainDb: Float = 0
    private(set) var lastReductionDb: Float = 0
    init() {
        dl = [Float](repeating: 0, count: LookaheadLimiter.lookahead); dr = dl
        hl = [Float](repeating: 0, count: 2 * LookaheadLimiter.ispHalf); hr = hl
        dqIdx = [Int](repeating: 0, count: LookaheadLimiter.lookahead + 1); dqVal = [Float](repeating: 1, count: LookaheadLimiter.lookahead + 1)
        b1 = [Float](repeating: 1, count: LookaheadLimiter.box1); b2 = [Float](repeating: 1, count: LookaheadLimiter.box2)
        s1 = Double(LookaheadLimiter.box1); s2 = Double(LookaheadLimiter.box2)
    }
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ cnt: Int) {
        let ceil = Float(pow(10, ceilingDb / 20))
        let cSus = AudioMath.coef(ms: 400)
        let fastK = Float(1 / (fastReleaseMs / 1000 * AudioMixer.sampleRate)), slowK = Float(1 / (slowReleaseMs / 1000 * AudioMixer.sampleRate))
        let taps = LookaheadLimiter.ispTaps, nT = 2 * LookaheadLimiter.ispHalf, cap = dqIdx.count
        let B1 = LookaheadLimiter.box1, B2 = LookaheadLimiter.box2
        var worst: Float = 1
        taps.withUnsafeBufferPointer { tp in
        for i in 0..<cnt {
            let xl = l[i], xr = r[i]
            hl[hw] = xl; hr[hw] = xr; hw += 1; if hw == nT { hw = 0 }      // hw now points at the oldest of the 12
            var pk = max(abs(xl), abs(xr))
            for p in 0..<3 {                                        // 72 MACs per frame: cheap enough to run always
                var al: Float = 0, ar: Float = 0
                var j = hw
                for k in 0..<nT { let c = tp[p * nT + k]; al += c * hl[j]; ar += c * hr[j]; j += 1; if j == nT { j = 0 } }
                pk = max(pk, abs(al), abs(ar))
            }
            let req: Float = pk > ceil ? ceil / pk : 1
            // sliding minimum over the last L requirements
            while dqCount > 0 {
                let back = (dqHead + dqCount - 1) % cap
                if dqVal[back] >= req { dqCount -= 1 } else { break }
            }
            let ins = (dqHead + dqCount) % cap
            dqIdx[ins] = t; dqVal[ins] = req; dqCount += 1
            while dqIdx[dqHead] <= t - L { dqHead += 1; if dqHead == cap { dqHead = 0 }; dqCount -= 1 }
            let m = dqVal[dqHead]
            t += 1
            // two cascaded box filters
            s1 += Double(m) - Double(b1[b1w]); b1[b1w] = m; b1w += 1; if b1w == B1 { b1w = 0 }
            let a = Float(s1 / Double(B1))
            s2 += Double(a) - Double(b2[b2w]); b2[b2w] = a; b2w += 1; if b2w == B2 { b2w = 0 }
            let g = min(1, Float(s2 / Double(B2)))
            // program-dependent release
            if g <= rel { rel = g } else {
                let k = fastK + (slowK - fastK) * min(1, max(0, sustainDb / 6))
                rel += (g - rel) * k
                if rel > g { rel = g }
            }
            let grDb: Float = rel >= 0.99999 ? 0 : -20 * log10(rel)
            sustainDb += (grDb - sustainDb) * cSus
            dl[w] = xl; dr[w] = xr
            let rp = w + 1 == L ? 0 : w + 1                        // oldest entry = written L-1 samples ago
            let ol = dl[rp] * rel, or = dr[rp] * rel
            w = rp
            l[i] = min(max(ol, -ceil), ceil); r[i] = min(max(or, -ceil), ceil)
            worst = min(worst, rel)
        }
        }
        if abs(s1 - Double(B1)) < 1e-6 && abs(s2 - Double(B2)) < 1e-6 { s1 = Double(B1); s2 = Double(B2) }     // idle: kill float drift
        lastReductionDb = -20 * log10(max(worst, 1e-6))
    }
}

/// Per-source input guard after the fader (zero latency): a soft-knee peak "gain rider" that leaves the channel bit-exact while its
/// post-fader peak envelope stays below `kneeDb` (-3 dBFS) and above it pulls the whole channel down smoothly (soft knee -3...0 dBFS,
/// 8:1 beyond; 3 ms attack / 250 ms release on the gain in dB, 10 ms peak hold), so a hot phone pushed +6 dB arrives at the master
/// around 0 dBFS instead of +6 dBFS and the master true-peak limiter only shaves the last dB or two.
/// Deliberately no clipping / instant-attack stage: measured on dense hot programme, a waveform-following guard (instant attack +
/// tanh) added distortion products at -54 dB where this rider plus the look-ahead master limiter stays at the source's -88 dB.
/// The master limiter remains the hard ceiling.
struct InputGuard {
    var kneeDb = -3.0, ratio = 8.0
    var attackMs = 3.0, releaseMs = 250.0, holdMs = 10.0, envReleaseMs = 120.0
    private var env: Float = 0, holdLeft = 0
    private var grDb: Float = 0
    private(set) var lastReductionDb: Float = 0
    /// Returns the largest input (post-fader, pre-guard) sample of the block, for the clip LED.
    @discardableResult
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
        let kneeLo = Float(kneeDb), width: Float = 3, t0 = kneeLo + width / 2, slope = Float(1 - 1 / max(1, ratio))
        let cA = AudioMath.coef(ms: attackMs), cR = AudioMath.coef(ms: releaseMs), cE = AudioMath.coef(ms: envReleaseMs)
        let hold = AudioMath.msToFrames(holdMs), lin = Float(pow(10, kneeDb / 20))
        var inPk: Float = 0, worst: Float = 0
        for i in 0..<n {
            let a = max(abs(l[i]), abs(r[i]))
            inPk = max(inPk, a)
            if a >= env { env = a; holdLeft = hold } else if holdLeft > 0 { holdLeft -= 1 } else { env += (a - env) * cE }
            var target: Float = 0
            if env > lin {
                let x = 20 * log10(env), over = x - t0
                if over >= width / 2 { target = over * slope }
                else { let k = over + width / 2; target = slope * k * k / (2 * width) }
            }
            if grDb == 0 && target == 0 { continue }                    // the common case: exact unity
            grDb += (target - grDb) * (target > grDb ? cA : cR)
            if grDb < 1e-4 && target == 0 { grDb = 0; continue }
            let g = pow(10, -grDb / 20)
            l[i] *= g; r[i] *= g
            worst = max(worst, grDb)
        }
        if env < 1e-9 { env = 0 }
        lastReductionDb = worst
        return inPk
    }
}

/// Spectral noise suppressor (Wiener / decision-directed, sqrt-Hann STFT, 512-point frames, 50 % overlap = 10.7 ms latency)
/// on Accelerate's real FFT. Noise is tracked adaptively (minimum statistics) or taken from a learned profile
/// (`learn()` averages the next ~2 s of what it hears; call it while only room noise is present).
final class SpectralDenoiser {
    static let size = 512, hop = 256, bins = 256
    static let latencyFrames = size
    var strength: Float = 0.6                      // 0...1
    private(set) var learning = false
    private(set) var hasProfile = false
    private(set) var reductionDb: Float = 0        // average attenuation of the last frame (for the meter)
    private let log2n = vDSP_Length(9)
    private let setup: FFTSetup
    private let win: [Float]
    private var ch: [Chan] = [Chan(), Chan()]
    private var profile = [Float](repeating: 0, count: SpectralDenoiser.bins)
    private var learnLeft = 0, learnFrames = 0
    private var learnAcc = [Float](repeating: 0, count: SpectralDenoiser.bins)
    private var re = [Float](repeating: 0, count: SpectralDenoiser.bins), im = [Float](repeating: 0, count: SpectralDenoiser.bins)
    private var frame = [Float](repeating: 0, count: SpectralDenoiser.size)

    private final class Chan {
        var inBuf = [Float](repeating: 0, count: SpectralDenoiser.size)       // last `size` input samples, oldest first
        var acc = [Float](repeating: 0, count: SpectralDenoiser.size)         // overlap-add accumulator
        var cur = [Float](repeating: 0, count: SpectralDenoiser.hop)          // block being played out
        var j = 0, fill = 0
        var pn = [Float](repeating: -1, count: SpectralDenoiser.bins)         // adaptive noise power
        var ps = [Float](repeating: 0, count: SpectralDenoiser.bins)          // smoothed power
        var gPrev = [Float](repeating: 1, count: SpectralDenoiser.bins)
        var pPrev = [Float](repeating: 0, count: SpectralDenoiser.bins)
    }

    init() {
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        win = (0..<SpectralDenoiser.size).map { Float(sin(Double.pi * Double($0) / Double(SpectralDenoiser.size))) }   // periodic sqrt-Hann
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func learn(seconds: Double = 2) {
        learnLeft = Int(seconds * AudioMixer.sampleRate) / SpectralDenoiser.hop; learnFrames = 0
        learnAcc = [Float](repeating: 0, count: SpectralDenoiser.bins); learning = true
    }
    func clearProfile() { hasProfile = false; learning = false; learnLeft = 0 }
    func reset() { ch = [Chan(), Chan()]; reductionDb = 0 }

    /// In place, stereo. Output is delayed by `latencyFrames`.
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for c in 0..<2 {
            let p = c == 0 ? l : r
            let st = ch[c]
            for i in 0..<n {
                let out = st.cur[st.j]; st.j += 1
                                st.inBuf[SpectralDenoiser.size - SpectralDenoiser.hop + st.fill] = p[i]; st.fill += 1
                p[i] = out
                if st.fill == SpectralDenoiser.hop {
                    transform(st, firstChannel: c == 0)
                    // advance: keep the newest (size - hop) samples as the head of the next frame
                    for k in 0..<(SpectralDenoiser.size - SpectralDenoiser.hop) { st.inBuf[k] = st.inBuf[k + SpectralDenoiser.hop] }
                    st.fill = 0; st.j = 0
                }
            }
        }
    }

    private func transform(_ st: Chan, firstChannel: Bool) {
        let N = SpectralDenoiser.size, B = SpectralDenoiser.bins
        // after the head shift the frame is inBuf[0..<N) with newest hop at the end
        for k in 0..<N { frame[k] = st.inBuf[k] * win[k] }
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(B)) }
            }
            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            // zrip forward output is scaled by 2: power in true units = (v/2)^2
            let sPtr = rp.baseAddress!, iPtr = ip.baseAddress!
            var redSum: Float = 0
            let strengthV = min(max(strength, 0), 1)
            let beta = 0.35 + 2.4 * strengthV                         // Wiener strictness (1 = plain Wiener)
            let gmin = Float(pow(10, -(6 + 24 * Double(strengthV)) / 20))
            let overshoot: Float = 1 + 1.5 * strengthV
            for k in 0..<B {
                let a = sPtr[k] * 0.5, b = iPtr[k] * 0.5
                let pw = a * a + b * b + 1e-14
                st.ps[k] = st.ps[k] == 0 ? pw : st.ps[k] * 0.6 + pw * 0.4
                if st.pn[k] < 0 { st.pn[k] = st.ps[k] }
                else if st.ps[k] < st.pn[k] { st.pn[k] = st.ps[k] }
                else { st.pn[k] *= 1.0015 }
                if firstChannel, learning { learnAcc[k] += pw }
                let noise = (hasProfile ? profile[k] : st.pn[k] * 1.8) * overshoot + 1e-14
                let gamma = pw / noise
                let xi = 0.9 * st.gPrev[k] * st.gPrev[k] * st.pPrev[k] / noise + 0.1 * max(gamma - 1, 0)
                var g = xi / (xi + beta)
                g = max(gmin, min(1, g))
                st.gPrev[k] = g; st.pPrev[k] = pw
                sPtr[k] = g * sPtr[k]; iPtr[k] = g * iPtr[k]
                redSum += g
            }
            if firstChannel { reductionDb = -20 * log10(max(redSum / Float(B), 1e-4)) }
            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
            frame.withUnsafeMutableBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(B)) }
            }
        } }
        // forward zrip scales by 2 and the inverse by N: a full round trip returns 2N x the signal
        let scale = 1 / Float(2 * N)
        for k in 0..<N { st.acc[k] += frame[k] * win[k] * scale }
        for k in 0..<SpectralDenoiser.hop { st.cur[k] = st.acc[k] }
        for k in 0..<(N - SpectralDenoiser.hop) { st.acc[k] = st.acc[k + SpectralDenoiser.hop] }
        for k in (N - SpectralDenoiser.hop)..<N { st.acc[k] = 0 }
        if firstChannel, learning {
            learnFrames += 1; learnLeft -= 1
            if learnLeft <= 0 {
                learning = false
                if learnFrames > 0 { for k in 0..<B { profile[k] = learnAcc[k] / Float(learnFrames) }; hasProfile = true }
            }
        }
    }
}
