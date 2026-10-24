// Software mixer. Every source owns a jitter-buffered ring that producers fill with push(); the mixer pulls fixed blocks on the
// video clock, runs the per-channel strips (voice chain on the mic, delay, fader, mute, auto-ducking of game audio, PFL),
// sums to the master (limited) and emits 48 kHz stereo Float32 interleaved CMSampleBuffers to the output sink.
// All DSP is plain Swift (Engine/AudioDSP.swift) so the same render path runs offline in tests via renderOffline().
import Foundation
import AVFoundation
import CoreMedia
import os

/// `clip`: latched ~1.5 s after the channel's pre-fader input reached -0.5 dBFS or its post-fader level hit 0 dBFS (input guard
/// limiting); on the master, after the bus reached 0 dBFS before the limiter.
struct ChannelMeter: Equatable { var peak: Float = 0, rms: Float = 0, clip = false }
struct MixerMeters {
    var master = ChannelMeter()
    var channels: [String: ChannelMeter] = [:]
    var gateOpen: Float = 0             // 0...1, mic above the gate
    var duckDb: Float = 0               // current game-audio reduction (<= 0)
    var compReductionDb: Float = 0
    var micLive = true
    var micDenoiseDb: Float = 0         // average noise suppression of the voice clean-up (dB, >= 0)
    var micLearning = false, micProfile = false
}

final class AudioInput {
    enum Kind { case voice, game }
    let id: String
    let kind: Kind
    var followsProgram: Bool
    var active: Bool
    var trim: Float = 1                    // legacy linear multiplier (setVolume)
    /// Frames the ring should hold; 0 disables prebuffering and the drift servo (offline tests).
    let jitterTarget: Int

    fileprivate let cap = 192_000
    fileprivate var l: [Float], r: [Float]
    fileprivate var rd = 0, count = 0
    fileprivate var primed = false, fadeIn = 0
    fileprivate var holdL: Float = 0, holdR: Float = 0              // last emitted sample: underrun concealment fades it out
    fileprivate var concealLeft = 0
    fileprivate var frac = 0.0, ratio = 1.0, errSmooth = 0.0       // drift servo: fractional read position, read speed, smoothed ring-level error
    fileprivate static let concealLen = 96
    fileprivate let lock = OSAllocatedUnfairLock()
    fileprivate var converter: AVAudioConverter?
    fileprivate var converterFormat: AVAudioFormat?
    var lastPushAt: UInt64 = 0
    /// Diagnostics (read via AudioMixer.inputStats): ring underruns (gaps played as silence), frames discarded by the burst guard, total frames in.
    fileprivate(set) var underruns = 0, droppedFrames = 0, framesIn = 0, primes = 0
    fileprivate(set) var servoPpm = 0

    // render-thread state
    var hp = HighPass(), speech = SpeechDetector(), gate = NoiseGate(), comp = Compressor(), lim = Limiter()
    var guardLim = InputGuard()             // post-fader safety limiter: one hot source cannot slam the master
    var delay = DelayLine(), ctlDelay = MonoDelay()
    var denoise: SpectralDenoiser?
    var faderGain: Float = -1, talkGain: Float = 0
    var meter = MeterState()

    init(id: String, followsProgram: Bool, active: Bool, jitterTarget: Int) {
        self.id = id; self.followsProgram = followsProgram; self.active = active; self.jitterTarget = jitterTarget
        kind = id == AudioMixer.micID ? .voice : .game
        l = [Float](repeating: 0, count: cap); r = l
    }

    var bufferedFrames: Int { lock.withLock { count } }

    fileprivate func write(_ pl: UnsafePointer<Float>, _ pr: UnsafePointer<Float>, _ n: Int) {
        lock.withLock {
            if n >= cap { rd = 0; count = 0 }
            // a source that bursts (stream start, stalled network catching up) must not leave seconds of latency behind:
            // beyond 5x the jitter target keep only the newest 2x
            var drop = max(0, count + n - cap)
            if jitterTarget > 0, count + n > jitterTarget * 5 { drop = max(drop, min(count, count + n - jitterTarget * 2)) }
            if drop > 0 { rd = (rd + drop) % cap; count -= drop; droppedFrames += drop }
            framesIn += n
            var w = (rd + count) % cap
            for i in 0..<n { l[w] = pl[i]; r[w] = pr[i]; w += 1; if w == cap { w = 0 } }
            count += n
        }
    }

    /// Pulls n frames. The ring is read at exactly 1.0x while its level stays within +-15 % of the target (bit-exact passthrough);
    /// only beyond that does the read speed trim, proportionally to the (slowly smoothed, 0.5 s) excess and capped at +-0.5 %,
    /// using a 32-tap Kaiser-windowed-sinc fractional-delay interpolator (see `Sinc`). The previous servo changed its speed
    /// continuously by up to +-1 % with LINEAR interpolation: every tone picked up distortion (THD+N about -41 dB, high frequencies
    /// dulled) and bursty arrivals frequency-modulated the whole signal. An underrun fades the last sample out over 96 frames
    /// instead of cutting to zero, then re-primes with a fade-in.
    fileprivate func pull(_ ol: UnsafeMutablePointer<Float>, _ or: UnsafeMutablePointer<Float>, _ n: Int) {
        lock.withLock {
            var i = 0
            func tail(from k0: Int) {
                for k in k0..<n {
                    if concealLeft > 0 {
                        let g = Float(concealLeft) / Float(AudioInput.concealLen); let w = g * g * (3 - 2 * g)
                        ol[k] = holdL * w; or[k] = holdR * w; concealLeft -= 1
                    } else { ol[k] = 0; or[k] = 0 }
                }
            }
            if jitterTarget > 0, !primed {
                if count >= jitterTarget { primed = true; fadeIn = 96; primes += 1; concealLeft = 0; frac = 0; ratio = 1; errSmooth = 0 } else { tail(from: 0); return }
            }
            if jitterTarget > 0 {
                errSmooth += (Double(count - jitterTarget) - errSmooth) * (1 - exp(-Double(n) / AudioMixer.sampleRate / 0.5))
                let band = Double(jitterTarget) * 0.15
                let excess = errSmooth > band ? errSmooth - band : (errSmooth < -band ? errSmooth + band : 0)
                ratio = 1 + max(-0.005, min(0.005, 0.01 * excess / Double(jitterTarget)))
                servoPpm = Int((ratio - 1) * 1e6)
            }
            while i < n {
                let exact = frac == 0 && ratio == 1
                let need = exact ? 1 : Sinc.taps / 2 + 1
                if count < need {
                    if jitterTarget > 0 { primed = false; frac = 0; underruns += 1; concealLeft = AudioInput.concealLen }
                    tail(from: i)
                    return
                }
                var a = l[rd], b = r[rd]
                if !exact { (a, b) = Sinc.interpolate(l, r, cap, rd, frac) }
                if fadeIn > 0 { let g = Float(96 - fadeIn + 1) / 96; a *= g; b *= g; fadeIn -= 1 }
                ol[i] = a; or[i] = b; holdL = a; holdR = b
                frac += ratio
                while frac >= 1 { frac -= 1; rd += 1; if rd == cap { rd = 0 }; count -= 1 }
                i += 1
            }
        }
    }
    fileprivate func flush() { lock.withLock { rd = 0; count = 0; primed = false; frac = 0; ratio = 1; errSmooth = 0; concealLeft = 0 } }
}

/// 32-tap Kaiser (beta 9) windowed-sinc fractional-delay interpolator, 128 phases with linear interpolation between phases
/// (error below -100 dB); flat to about 0.9 x Nyquist, exact (a pure delta) at frac = 0.
enum Sinc {
    static let taps = 32, phases = 128
    static let table: [Float] = {
        func i0(_ x: Double) -> Double { var s = 1.0, t = 1.0; for k in 1..<40 { t *= (x / 2 / Double(k)) * (x / 2 / Double(k)); s += t }; return s }
        let beta = 9.0, norm = i0(beta), half = Double(taps / 2)
        var t = [Float](repeating: 0, count: (phases + 1) * taps)
        for p in 0...phases {
            let f = Double(p) / Double(phases)
            var sum = 0.0, row = [Double](repeating: 0, count: taps)
            for k in 0..<taps {
                let x = Double(k - (taps / 2 - 1)) - f                     // tap k reads sample rd + k - 15
                let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let u = x / half
                let w = abs(u) >= 1 ? 0 : i0(beta * (1 - u * u).squareRoot()) / norm
                row[k] = sinc * w; sum += row[k]
            }
            for k in 0..<taps { t[p * taps + k] = Float(row[k] / sum) }     // unity DC gain at every phase
        }
        return t
    }()
    static func interpolate(_ l: [Float], _ r: [Float], _ cap: Int, _ rd: Int, _ frac: Double) -> (Float, Float) {
        let fp = frac * Double(phases), p = min(Int(fp), phases - 1), fr = Float(fp - Double(p))
        var sl: Float = 0, sr: Float = 0
        table.withUnsafeBufferPointer { t in
            let t0 = t.baseAddress! + p * taps, t1 = t0 + taps
            var idx = rd - (taps / 2 - 1)
            if idx < 0 { idx += cap }
            for k in 0..<taps {
                let w = t0[k] + (t1[k] - t0[k]) * fr
                sl += w * l[idx]; sr += w * r[idx]
                idx += 1; if idx == cap { idx = 0 }
            }
        }
        return (sl, sr)
    }
}

final class AudioMixer {
    static let sampleRate = 48_000.0
    static let chunk = 1024
    static let micID = "mic"
    let format = AVAudioFormat(standardFormatWithSampleRate: AudioMixer.sampleRate, channels: 2)!

    private var inputs: [String: AudioInput] = [:]
    private let inputsLock = NSLock()
    private var programIDs: Set<String> = []
    private var crossfadeFramesNow = 0, crossfadeLeft = 0
    private let jitterFrames: Int

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "studio.audio", qos: .userInteractive)
    private var emitted: Int64 = 0
    private var originTicks: UInt64 = 0
    private weak var sink: VideoSink?
    private var interleaved: AVAudioPCMBuffer!
    private var outFormat: CMAudioFormatDescription?
    private(set) var running = false

    private let stateLock = NSLock()
    private var _settings = AudioSettings()
    private var talkHeld = false, talkLatched = false
    private var learnRequests: [String: Bool] = [:]        // id -> true = learn, false = clear (consumed by the render thread)
    private var _meters = MixerMeters()
    private var _peak: Float = 0

    // render-thread state
    private var ducker = Ducker(), masterLimiter = LookaheadLimiter(), masterHP = HighPass()
    private var masterGain: Float = -1
    private var masterMeter = MeterState()
    private let blk = AudioMixer.chunk
    private var progL: [Float], progR: [Float], monL: [Float], monR: [Float], soloL: [Float], soloR: [Float]
    private var sideL: [Float], sideR: [Float], micPostL: [Float], micPostR: [Float]
    private var tmpL: [Float], tmpR: [Float], ctl: [Float], gateCtl: [Float], duckCtl: [Float], duckG: [Float], mg: [Float]

    /// Receives the headphone feed (monitor bus) for every rendered block; nil when no monitor output is running.
    var monitorSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?

    /// Program peak (max of L/R, decaying), 0...1, for the monitor meters.
    var peak: Float { stateLock.withLock { _peak } }
    var masterVolume: Float {
        get { AudioMath.dbToLinear(settings.masterDb) }
        set { var s = settings; s.masterDb = AudioMath.linearToDb(newValue); settings = s }
    }
    var settings: AudioSettings {
        get { stateLock.withLock { _settings } }
        set { stateLock.withLock { _settings = newValue } }
    }

    /// `jitterTargetMs` = how much audio each ring holds before it plays (absorbs bursty/late producers). 0 = none (offline tests).
    init(jitterTargetMs: Double = 60) {
        jitterFrames = AudioMath.msToFrames(jitterTargetMs)
        func z() -> [Float] { [Float](repeating: 0, count: AudioMixer.chunk) }
        progL = z(); progR = z(); monL = z(); monR = z(); soloL = z(); soloR = z(); sideL = z(); sideR = z()
        micPostL = z(); micPostR = z(); tmpL = z(); tmpR = z(); ctl = z(); gateCtl = z(); duckCtl = z(); duckG = z(); mg = z()
        var asbd = AudioStreamBasicDescription(mSampleRate: AudioMixer.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outFormat)
        // true peak (4x oversampled) <= -2 dBTP: AAC-LC 192k overshoots dense, hard-limited programme by up to ~1.2 dB (measured), so
        // the decoded recording / stream stays at or below about -0.7 dBFS
        masterLimiter.ceilingDb = -2.0
        addSource(id: AudioMixer.micID, followsProgram: false, active: true)
    }

    // MARK: sources

    /// Registers a source. `id` is `engineSourceKey(ref)` for scene sources (e.g. "device:abc"), or any string with
    /// followsProgram = false for always-on sources (the mic is "mic").
    /// `jitterMs` overrides the ring depth for bursty producers (ffmpeg pipes); ignored when the mixer runs without jitter buffers.
    func addSource(id: String, followsProgram: Bool = true, active: Bool? = nil, jitterMs: Double? = nil) {
        inputsLock.lock(); defer { inputsLock.unlock() }
        if inputs[id] != nil { return }
        let on = active ?? (followsProgram ? programIDs.contains(id) : true)
        inputs[id] = AudioInput(id: id, followsProgram: followsProgram, active: on, jitterTarget: jitterFrames == 0 ? 0 : AudioMath.msToFrames(jitterMs ?? Double(jitterFrames) / AudioMixer.sampleRate * 1000))
    }
    func removeSource(id: String) {
        guard id != AudioMixer.micID else { return }
        inputsLock.lock(); inputs[id] = nil; inputsLock.unlock()
    }
    func hasSource(_ id: String) -> Bool { inputsLock.lock(); defer { inputsLock.unlock() }; return inputs[id] != nil }
    var sourceIDs: [String] { inputsLock.lock(); defer { inputsLock.unlock() }; return inputs.keys.sorted() }
    /// Legacy linear trim (kept for callers that predate the fader settings).
    func setVolume(id: String, _ v: Float) { inputsLock.lock(); inputs[id]?.trim = v; inputsLock.unlock() }
    func setActive(id: String, _ a: Bool) { inputsLock.lock(); inputs[id]?.active = a; inputsLock.unlock() }
    /// Marks program-following sources active iff their id is in `ids` (remembered for sources that register later).
    /// `fadeMs` > 0 makes the audio follow a video transition: faders glide linearly over that time instead of switching in ~20 ms.
    func setProgramSources(_ ids: Set<String>, fadeMs: Double = 0) {
        inputsLock.lock(); defer { inputsLock.unlock() }
        stateLock.withLock { crossfadeFramesNow = AudioMath.msToFrames(fadeMs); crossfadeLeft = crossfadeFramesNow + 2 * AudioMixer.chunk }
        programIDs = ids
        for i in inputs.values where i.followsProgram { i.active = ids.contains(i.id) }
    }
    struct InputStats { var buffered = 0, underruns = 0, droppedFrames = 0, framesIn = 0, primes = 0, servoPpm = 0, active = false }
    func inputStats(id: String) -> InputStats {
        inputsLock.lock(); let i = inputs[id]; inputsLock.unlock()
        guard let i else { return InputStats() }
        return i.lock.withLock { InputStats(buffered: i.count, underruns: i.underruns, droppedFrames: i.droppedFrames, framesIn: i.framesIn, primes: i.primes, servoPpm: i.servoPpm, active: i.active) }
    }
    func bufferedFrames(id: String) -> Int { inputsLock.lock(); let i = inputs[id]; inputsLock.unlock(); return i?.bufferedFrames ?? 0 }

    // MARK: talk (push-to-talk)

    func setTalkHeld(_ held: Bool) { stateLock.withLock { talkHeld = held } }
    func setTalkLatched(_ on: Bool) { stateLock.withLock { talkLatched = on } }
    var talkState: (held: Bool, latched: Bool) { stateLock.withLock { (talkHeld, talkLatched) } }
    /// Whether the mic is currently allowed through to the program.
    static func micLive(_ s: AudioSettings, held: Bool, latched: Bool) -> Bool {
        !s.mic.mute && s.micEnabled && (s.talkMode == .open || held || latched)
    }

    // MARK: noise profile

    /// Learns the noise profile of an input (the mic by default) from the next ~2 s: keep the room quiet while it runs.
    func learnNoise(id: String = AudioMixer.micID) { stateLock.withLock { learnRequests[id] = true } }
    func clearNoiseProfile(id: String = AudioMixer.micID) { stateLock.withLock { learnRequests[id] = false } }

    // MARK: push


    /// Push decoded audio (any PCM format; converted to 48k stereo float). Thread-safe, non-blocking.
    func push(id: String, buffers buf: AVAudioPCMBuffer) {
        inputsLock.lock(); let inp = inputs[id]; inputsLock.unlock()
        guard let inp = inp, buf.frameLength > 0 else { return }
        var src = buf
        if buf.format != format {
            if inp.converterFormat != buf.format {
                inp.converter = AVAudioConverter(from: buf.format, to: format)
                inp.converter?.primeMethod = .none                      // chunk-wise sample-rate conversion must not insert priming silence per buffer
                inp.converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                inp.converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                if buf.format.channelCount > 2 { inp.converter?.channelMap = [0, 1] }
                inp.converterFormat = buf.format
            }
            guard let conv = inp.converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * AudioMixer.sampleRate / buf.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err != nil { return }
            src = out
        }
        guard let ch = src.floatChannelData, src.frameLength > 0 else { return }
        inp.write(ch[0], src.format.channelCount > 1 ? ch[1] : ch[0], Int(src.frameLength))
    }
    func push(id: String, sampleBuffer sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var a = asbd.pointee
        guard let fmt = AVAudioFormat(cmAudioFormatDescription: fd) as AVAudioFormat? ?? AVAudioFormat(streamDescription: &a) else { return }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        pcm.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList) == noErr else { return }
        push(id: id, buffers: pcm)
    }
    /// Raw planar push (already 48 kHz), used by tests and synthetic sources.
    func push(id: String, left: [Float], right: [Float]? = nil) {
        inputsLock.lock(); let inp = inputs[id]; inputsLock.unlock()
        guard let inp, !left.isEmpty else { return }
        let r = right ?? left
        left.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in inp.write(lp.baseAddress!, rp.baseAddress!, min(left.count, r.count)) } }
    }

    // MARK: meters

    func meters() -> MixerMeters { stateLock.withLock { _meters } }

    // MARK: run

    func start(sink: VideoSink, originTicks: UInt64) {
        stop()
        self.sink = sink; self.originTicks = originTicks; emitted = 0
        interleaved = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMixer.sampleRate, channels: 2, interleaved: true)!, frameCapacity: AVAudioFrameCount(AudioMixer.chunk))
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t; t.resume()
    }
    func stop() {
        timer?.cancel(); timer = nil
        running = false
    }

    private func pump() {
        guard MachTime.now >= originTicks else { return }
        let nowSec = MachTime.seconds(ticks: MachTime.now &- originTicks)
        let target = Int64(nowSec * AudioMixer.sampleRate)
        while target - emitted >= Int64(AudioMixer.chunk) {
            renderBlock(AudioMixer.chunk)
            emit(pts: emitted)
            emitted += Int64(AudioMixer.chunk)
        }
    }

    /// Offline render (tests / bounce): `frames` of program audio, same path as live.
    func renderOffline(frames: Int) -> (l: [Float], r: [Float]) {
        var ol = [Float](), orr = [Float]()
        ol.reserveCapacity(frames); orr.reserveCapacity(frames)
        var left = frames
        while left > 0 {
            let n = min(blk, left)
            renderBlock(n)
            ol.append(contentsOf: progL[0..<n]); orr.append(contentsOf: progR[0..<n])
            left -= n
        }
        return (ol, orr)
    }

    // MARK: render

    private func renderBlock(_ n: Int) {
        let s = settings
        let (held, latched) = talkState
        inputsLock.lock(); let ins = Array(inputs.values); inputsLock.unlock()
        let live = AudioMixer.micLive(s, held: held, latched: latched)
        let learns: [String: Bool] = stateLock.withLock { let l = learnRequests; learnRequests = [:]; return l }
        for i in 0..<n { progL[i] = 0; progR[i] = 0; monL[i] = 0; monR[i] = 0; soloL[i] = 0; soloR[i] = 0
            sideL[i] = 0; sideR[i] = 0; micPostL[i] = 0; micPostR[i] = 0; duckCtl[i] = 0 }
        let crossfade: Int = stateLock.withLock { let c = crossfadeLeft > 0 ? crossfadeFramesNow : 0; crossfadeLeft = max(0, crossfadeLeft - n); return c }
        let anySolo = ins.contains { s.channel($0.id).solo }
        var gateOpen: Float = 0, compGR: Float = 0, micDenoiseDb: Float = 0, micLearning = false, micProfile = false
        var chMeters: [String: ChannelMeter] = [:]

        // master gain ramp (shared by program and the headphone feed)
        let mTarget: Float = s.masterMute ? 0 : AudioMath.dbToLinear(s.masterDb)
        if masterGain < 0 { masterGain = mTarget }
        for i in 0..<n { mg[i] = rampGain(masterGain, mTarget, i, n) }
        masterGain = mTarget

        tmpL.withUnsafeMutableBufferPointer { tl in tmpR.withUnsafeMutableBufferPointer { tr in
        let l = tl.baseAddress!, r = tr.baseAddress!
        // 1) voice inputs (mic): voice chain, talk gate, delay, fader
        for inp in ins where inp.kind == .voice {
            let ch = s.channel(inp.id)
            let v = s.voice
            if let cmd = learns[inp.id] {
                if inp.denoise == nil { inp.denoise = SpectralDenoiser() }
                if cmd { inp.denoise!.learn() } else { inp.denoise!.clearProfile() }
            }
            // A muted / disabled mic contributes EXACT digital zeros: once the 10 ms mute ramp has finished nothing is pulled,
            // processed or mixed (room noise cannot leak through gate floors or make-up gain) and the ring is dropped.
            if !live && inp.talkGain == 0 {
                inp.pull(l, r, n)                                  // keep draining the ring so it stays live-aligned, but discard
                for i in 0..<n { l[i] = 0; r[i] = 0 }
                inp.faderGain = 0
                inp.meter.update(l, r, n)
                chMeters[inp.id] = ChannelMeter(peak: inp.meter.peak, rms: inp.meter.rms, clip: false)
                continue
            }
            inp.pull(l, r, n)
            var micIn: Float = 0
            for i in 0..<n { micIn = max(micIn, abs(l[i]), abs(r[i])) }
            ctl.withUnsafeMutableBufferPointer { cp in
                let c = cp.baseAddress!
                if v.hpfOn { inp.hp.configure(cutoff: v.hpfHz); inp.hp.process(l, r, n) }
                if v.denoiseOn {
                    if inp.denoise == nil { inp.denoise = SpectralDenoiser() }
                    inp.denoise!.strength = Float(v.denoiseStrength); inp.denoise!.process(l, r, n)
                    micDenoiseDb = max(micDenoiseDb, inp.denoise!.reductionDb)
                } else if let d = inp.denoise, d.learning { d.process(l, r, n) }
                micLearning = micLearning || (inp.denoise?.learning ?? false); micProfile = micProfile || (inp.denoise?.hasProfile ?? false)
                // ducking trigger: speech level (RMS) on the cleaned mic, independent of the noise gate threshold
                inp.speech.thresholdDb = s.duck.thresholdDb; inp.speech.holdMs = s.duck.holdMs
                inp.speech.process(l, r, n, ctl: c)
                inp.gate.thresholdDb = v.gateThresholdDb; inp.gate.reductionDb = v.gateReductionDb; inp.gate.holdMs = v.gateHoldMs
                gateCtl.withUnsafeMutableBufferPointer { inp.gate.process(l, r, n, ctl: $0.baseAddress!, apply: v.gateOn) }
                if v.compOn {
                    inp.comp.thresholdDb = v.compThresholdDb; inp.comp.ratio = v.compRatio; inp.comp.makeupDb = v.compMakeupDb
                    inp.comp.process(l, r, n)
                }
                if v.limiterOn { inp.lim.ceilingDb = v.limiterCeilingDb; inp.lim.process(l, r, n) }
                // talk / mute gate: 5 ms linear attack, 10 ms linear release that lands on EXACTLY 0 (click-free key press, true silence)
                let tgt: Float = live ? 1 : 0
                let up: Float = 1 / Float(AudioMath.msToFrames(5)), down: Float = 1 / Float(AudioMath.msToFrames(10))
                var tg = inp.talkGain
                for i in 0..<n {
                    tg = tgt > tg ? min(tgt, tg + up) : max(tgt, tg - down)
                    if tg == 0 { l[i] = 0; r[i] = 0; c[i] = 0 } else { l[i] *= tg; r[i] *= tg; c[i] *= tg }
                }
                inp.talkGain = tg
                for i in 0..<n { sideL[i] += l[i]; sideR[i] += r[i] }
                inp.delay.process(l, r, n, delay: AudioMath.msToFrames(ch.delayMs))
                inp.ctlDelay.process(c, n, delay: AudioMath.msToFrames(ch.delayMs))
                for i in 0..<n { duckCtl[i] = max(duckCtl[i], c[i]) }
            }
            gateOpen = max(gateOpen, inp.gate.smoothedOpen); compGR = max(compGR, inp.comp.lastReductionDb)
            let fT: Float = (ch.mute ? 0 : AudioMath.dbToLinear(ch.gainDb)) * inp.trim
            if inp.faderGain < 0 { inp.faderGain = fT }
            for i in 0..<n { let g = rampGain(inp.faderGain, fT, i, n); l[i] *= g; r[i] *= g }
            inp.faderGain = fT
            let micPost = inp.guardLim.process(l, r, n)
            for i in 0..<n { progL[i] += l[i]; progR[i] += r[i]; micPostL[i] += l[i]; micPostR[i] += r[i] }
            inp.meter.update(l, r, n)
            inp.meter.flagClip(micIn >= MeterState.clipThreshold || micPost >= 1, n)
            chMeters[inp.id] = ChannelMeter(peak: inp.meter.peak, rms: inp.meter.rms, clip: inp.meter.clipLatched)
            if ch.solo { for i in 0..<n { soloL[i] += sideL[i]; soloR[i] += sideR[i] } }
        }

        // 2) ducking envelope from the mic, applied to all game channels
        duckCtl.withUnsafeBufferPointer { dc in duckG.withUnsafeMutableBufferPointer { dg in
            ducker.amountDb = s.duck.amountDb; ducker.attackMs = s.duck.attackMs; ducker.releaseMs = s.duck.releaseMs
            ducker.process(trig: dc.baseAddress!, gain: dg.baseAddress!, n, enabled: s.duck.enabled)
        } }

        // 3) game inputs (phones / music / media)
        for inp in ins where inp.kind == .game {
            let ch = s.channel(inp.id)
            inp.pull(l, r, n)
            if s.phoneDenoiseOn {
                if inp.denoise == nil { inp.denoise = SpectralDenoiser() }
                inp.denoise!.strength = Float(s.phoneDenoiseStrength); inp.denoise!.process(l, r, n)
            }
            if let cmd = learns[inp.id] {
                if inp.denoise == nil { inp.denoise = SpectralDenoiser() }
                if cmd { inp.denoise!.learn() } else { inp.denoise!.clearProfile() }
            }
            if s.phoneGateOn {
                // gentle downward expander for hissy feeds: 12 dB max, slow release so music tails survive
                inp.gate.thresholdDb = s.phoneGateThresholdDb; inp.gate.reductionDb = 12; inp.gate.holdMs = 250; inp.gate.releaseMs = 400
                gateCtl.withUnsafeMutableBufferPointer { inp.gate.process(l, r, n, ctl: $0.baseAddress!, apply: true) }
            }
            let phoneMs = inp.id.hasPrefix("device:") ? s.phoneLatencyMs : 0         // phones arrive near-live, the picture ~100 ms later
            inp.delay.process(l, r, n, delay: AudioMath.msToFrames(ch.delayMs + phoneMs))
            if ch.solo { for i in 0..<n { soloL[i] += l[i]; soloR[i] += r[i] } }       // PFL: pre-fader, pre-duck
            var preFader: Float = 0
            for i in 0..<n { preFader = max(preFader, abs(l[i]), abs(r[i])) }
            let fT: Float = inp.active ? (ch.mute ? 0 : AudioMath.dbToLinear(ch.gainDb)) * inp.trim : 0
            if inp.faderGain < 0 { inp.faderGain = fT }
            if crossfade > 0, inp.faderGain != fT {
                // scene take with a video fade: the audio follows the picture, linear over the transition (no gap, no dip)
                var g0 = inp.faderGain
                let full = max(AudioMath.dbToLinear(ch.gainDb) * inp.trim, 1e-3)
                let step = full / Float(crossfade)
                for i in 0..<n {
                    g0 = fT > g0 ? min(fT, g0 + step) : max(fT, g0 - step)
                    let g = g0 * duckG[i]
                    l[i] *= g; r[i] *= g
                }
                inp.faderGain = g0
            } else {
                for i in 0..<n { let g = rampGain(inp.faderGain, fT, i, n) * duckG[i]; l[i] *= g; r[i] *= g }
                inp.faderGain = fT
            }
            // post-fader safety limiter (unity below -3 dBFS), then onto the buses
            let postFader = inp.guardLim.process(l, r, n)
            for i in 0..<n { progL[i] += l[i]; progR[i] += r[i]; monL[i] += l[i]; monR[i] += r[i] }
            inp.meter.update(l, r, n)
            inp.meter.flagClip((inp.active && preFader >= MeterState.clipThreshold) || postFader >= 1, n)
            chMeters[inp.id] = ChannelMeter(peak: inp.meter.peak, rms: inp.meter.rms, clip: inp.meter.clipLatched)
        }
        } }

        // 4) master gain + limiter
        for i in 0..<n { progL[i] *= mg[i]; progR[i] *= mg[i] }
        progL.withUnsafeMutableBufferPointer { pl in progR.withUnsafeMutableBufferPointer { pr in
            if s.masterHpfOn { masterHP.configure(cutoff: s.masterHpfHz); masterHP.process(pl.baseAddress!, pr.baseAddress!, n) }
            var bus: Float = 0
            for i in 0..<n { bus = max(bus, abs(pl[i]), abs(pr[i])) }
            masterLimiter.process(pl.baseAddress!, pr.baseAddress!, n)
            masterMeter.update(pl.baseAddress!, pr.baseAddress!, n)
            masterMeter.flagClip(bus >= 1, n)
        } }

        // 5) headphone feed
        if let sinkMon = monitorSink {
            let lvl = AudioMath.dbToLinear(s.monitor.levelDb)
            let sideLvl = AudioMath.dbToLinear(s.monitor.sidetoneDb)
            for i in 0..<n {
                if anySolo { monL[i] = soloL[i] * lvl; monR[i] = soloR[i] * lvl }
                else if s.monitor.sidetoneOn {
                    monL[i] = (monL[i] * mg[i] + sideL[i] * sideLvl) * lvl; monR[i] = (monR[i] * mg[i] + sideR[i] * sideLvl) * lvl
                } else {
                    monL[i] = (monL[i] + micPostL[i]) * mg[i] * lvl; monR[i] = (monR[i] + micPostR[i]) * mg[i] * lvl
                }
                monL[i] = min(max(monL[i], -1), 1); monR[i] = min(max(monR[i], -1), 1)
            }
            monL.withUnsafeBufferPointer { a in monR.withUnsafeBufferPointer { b in sinkMon(a.baseAddress!, b.baseAddress!, n) } }
        }

        stateLock.withLock {
            _peak = masterMeter.peak
            _meters = MixerMeters(master: ChannelMeter(peak: masterMeter.peak, rms: masterMeter.rms, clip: masterMeter.clipLatched),
                                  channels: chMeters, gateOpen: gateOpen, duckDb: ducker.currentDb, compReductionDb: compGR, micLive: live,
                                  micDenoiseDb: micDenoiseDb, micLearning: micLearning, micProfile: micProfile)
        }
    }

    private func emit(pts: Int64) {
        let n = AudioMixer.chunk
        guard let fd = outFormat, let sink = sink, let dst = interleaved.floatChannelData?[0] else { return }
        for i in 0..<n { dst[2 * i] = progL[i]; dst[2 * i + 1] = progR[i] }
        let bytes = n * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let bb = block,
              CMBlockBufferReplaceDataBytes(with: dst, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) == noErr else { return }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: n,
                presentationTimeStamp: CMTime(value: pts, timescale: Int32(AudioMixer.sampleRate)), packetDescriptions: nil, sampleBufferOut: &sb) == noErr,
              let s = sb else { return }
        sink.submit(audio: s)
    }
}
