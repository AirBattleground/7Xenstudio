import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Studio

// MARK: helpers

private let sr = 48_000.0
private func tone(_ f: Double, _ amp: Float, from: Int = 0, count: Int, total: Int? = nil) -> [Float] {
    (0..<(total ?? count)).map { i in
        (i >= from && i < from + count) ? amp * Float(sin(2 * Double.pi * f * Double(i) / sr)) : 0
    }
}
/// Amplitude of frequency f in x[a..<b] (Goertzel; returns the sine amplitude).
private func amplitude(_ x: [Float], _ f: Double, _ a: Int, _ b: Int) -> Float {
    let w = 2 * Double.pi * f / sr, c = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for i in a..<b { let s = Double(x[i]) + c * s1 - s2; s2 = s1; s1 = s }
    let re = s1 - s2 * cos(w), im = s2 * sin(w)
    return Float(2 * (re * re + im * im).squareRoot() / Double(b - a))
}
private func db(_ x: Float) -> Double { 20 * log10(Double(max(x, 1e-9))) }
private func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
private func mixer() -> AudioMixer { AudioMixer(jitterTargetMs: 0) }
private func fresh() -> AudioSettings { var s = AudioSettings(); s.phoneLatencyMs = 0; s.voice.denoiseOn = false; return s }   // denoiser off: these tests feed steady tones, which a noise suppressor rightly treats as noise      // phone picture-latency compensation off
private func s0() -> AudioSettings { var s = fresh(); s.duck.enabled = false; return s }

// MARK: gain / mute / math

@Suite struct AudioMathTests {
    @Test func dbConversions() {
        #expect(AudioMath.dbToLinear(0) == 1)
        #expect(abs(AudioMath.dbToLinear(-6.0206) - 0.5) < 1e-4)
        #expect(abs(AudioMath.dbToLinear(6) - 1.9953) < 1e-3)
        #expect(AudioMath.dbToLinear(-60) == 0)         // fader floor = -inf
        #expect(abs(AudioMath.linearToDb(0.5) + 6.0206) < 1e-3)
    }
    @Test func faderLawRoundTrip() {
        #expect(AudioMath.faderDb(position: 0) == -60)
        #expect(AudioMath.faderDb(position: 1) == 6)
        #expect(abs(AudioMath.faderDb(position: 0.8)) < 1e-9)
        for d in stride(from: -60.0, through: 6.0, by: 1.5) {
            #expect(abs(AudioMath.faderDb(position: AudioMath.faderPosition(db: d)) - d) < 1e-9)
        }
    }
    @Test func faderGainMuteAndMasterOnGameChannel() {
        let m = mixer(); m.addSource(id: "device:a", followsProgram: true, active: true)
        var s = s0(); s.phones["device:a"] = { var c = ChannelSettings(); c.gainDb = -6.0206; return c }()
        m.settings = s
        m.push(id: "device:a", left: tone(440, 0.5, count: 48_000))
        var o = m.renderOffline(frames: 24_000).l
        #expect(abs(amplitude(o, 440, 8000, 24_000) - 0.25) < 0.005)
        // mute
        s.phones["device:a"]!.mute = true; m.settings = s
        m.push(id: "device:a", left: tone(440, 0.5, count: 48_000))
        o = m.renderOffline(frames: 24_000).l
        #expect(o[4000..<24_000].allSatisfy { abs($0) < 1e-6 })
        // unmute + master -6 dB
        s.phones["device:a"]!.mute = false; s.phones["device:a"]!.gainDb = 0; s.masterDb = -6.0206; m.settings = s
        m.push(id: "device:a", left: tone(440, 0.5, count: 48_000))
        o = m.renderOffline(frames: 24_000).l
        #expect(abs(amplitude(o, 440, 8000, 24_000) - 0.25) < 0.005)
    }
    @Test func muteRampIsClickFree() {
        let m = mixer(); m.addSource(id: "device:a", followsProgram: true, active: true); m.settings = s0()
        m.push(id: "device:a", left: tone(440, 0.5, count: 96_000))
        _ = m.renderOffline(frames: 4096)
        var s = s0(); s.phones["device:a"] = { var c = ChannelSettings(); c.mute = true; return c }(); m.settings = s
        let o = m.renderOffline(frames: 4096).l
        var maxStep: Float = 0
        for i in 1..<o.count { maxStep = max(maxStep, abs(o[i] - o[i - 1])) }
        #expect(maxStep < 0.05, "step \(maxStep)")      // sine alone steps 0.029 at 440 Hz, amplitude 0.5
    }
    @Test func inactiveSourceIsSilentAndLateRegistrationFollowsProgram() {
        let m = mixer()
        m.setProgramSources(["device:late"])
        m.addSource(id: "device:late")          // registers after the cut: must already be active
        m.addSource(id: "device:off")
        m.settings = s0()
        m.push(id: "device:late", left: tone(440, 0.4, count: 24_000)); m.push(id: "device:off", left: tone(1000, 0.4, count: 24_000))
        let o = m.renderOffline(frames: 24_000).l
        #expect(amplitude(o, 440, 8000, 20_000) > 0.38); #expect(amplitude(o, 1000, 8000, 20_000) < 0.001)
    }
    @Test func meters() {
        let m = mixer(); m.addSource(id: "device:a", active: true); m.settings = s0()
        m.push(id: "device:a", left: tone(440, 0.5, count: 48_000))
        _ = m.renderOffline(frames: 24_000)
        let mt = m.meters()
        let c = mt.channels["device:a"]!
        #expect(abs(c.peak - 0.5) < 0.01); #expect(abs(c.rms - 0.354) < 0.02)
        #expect(abs(mt.master.peak - 0.5) < 0.01)
        #expect(abs(m.peak - 0.5) < 0.01)
    }
}

// MARK: DSP blocks

@Suite struct AudioDSPTests {
    @Test func delayLineIsExact() {
        var d = DelayLine()
        var z = [Float](repeating: 0, count: 2000), zr = z
        z.withUnsafeMutableBufferPointer { l in zr.withUnsafeMutableBufferPointer { r in d.process(l.baseAddress!, r.baseAddress!, 2000, delay: 480) } }   // settle the crossfade
        var x = [Float](repeating: 0, count: 3000); x[100] = 1; x[2999] = 0.5
        var xr = x
        x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in d.process(l.baseAddress!, r.baseAddress!, 3000, delay: 480) } }
        #expect(x[580] == 1); #expect(x.enumerated().allSatisfy { $0.offset == 580 || abs($0.element) < 1e-9 })
        #expect(d.delayFrames == 480)
    }
    @Test func delayZeroIsPassthroughAndMaxDelayWorks() {
        var d = DelayLine()
        var x = tone(440, 0.5, count: 1000); let ref = x; var xr = x
        x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in d.process(l.baseAddress!, r.baseAddress!, 1000, delay: 0) } }
        #expect(x == ref)
        var big = DelayLine()
        var y = [Float](repeating: 0, count: 200_000); y[10] = 1; var yr = y
        y.withUnsafeMutableBufferPointer { l in yr.withUnsafeMutableBufferPointer { r in big.process(l.baseAddress!, r.baseAddress!, 200_000, delay: AudioMath.msToFrames(2000)) } }
        #expect(y[10 + 96_000] > 0.99 || y[10 + 96_000] == 1)
    }
    @Test func delayChangeCrossfadesWithoutAJump() {
        var d = DelayLine()
        var warm = tone(440, 0.5, count: 4800); var wr = warm
        warm.withUnsafeMutableBufferPointer { l in wr.withUnsafeMutableBufferPointer { r in d.process(l.baseAddress!, r.baseAddress!, 4800, delay: 240) } }
        var x = tone(440, 0.5, from: 0, count: 4800); var xr = x
        // continue the sine phase from the warm block
        x = (0..<4800).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double(4800 + $0) / sr)) }; xr = x
        x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in d.process(l.baseAddress!, r.baseAddress!, 4800, delay: 960) } }
        var maxStep: Float = 0
        for i in 1..<x.count { maxStep = max(maxStep, abs(x[i] - x[i - 1])) }
        #expect(maxStep < 0.06, "step \(maxStep)")
    }
    @Test func highPassRemovesRumbleKeepsVoice() {
        var hp = HighPass(cutoff: 80)
        func gain(_ f: Double) -> Double {
            var x = tone(f, 0.5, count: 48_000); var xr = x
            x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in hp.process(l.baseAddress!, r.baseAddress!, 48_000) } }
            return db(amplitude(x, f, 24_000, 48_000) / 0.5)
        }
        #expect(gain(1000) > -0.3); #expect(abs(gain(80) + 3) < 0.7); #expect(gain(30) < -12)
    }
    @Test func gateOpensAndCloses() {
        var g = NoiseGate(); g.thresholdDb = -45; g.reductionDb = 40
        var x = tone(500, 0.3, from: 0, count: 24_000, total: 72_000); var xr = x
        var ctl = [Float](repeating: 0, count: 72_000)
        x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in ctl.withUnsafeMutableBufferPointer { c in
            g.process(l.baseAddress!, r.baseAddress!, 72_000, ctl: c.baseAddress!, apply: true) } } }
        #expect(ctl[10_000] > 0.99); #expect(ctl[70_000] < 0.01)            // open while talking, closed after hold + release
        // quiet room noise (-60 dB) stays closed and is pushed ~40 dB down
        var h = NoiseGate(); h.thresholdDb = -45; h.reductionDb = 40
        var n = tone(300, 0.001, count: 48_000); var nr = n; var c2 = [Float](repeating: 0, count: 48_000)
        n.withUnsafeMutableBufferPointer { l in nr.withUnsafeMutableBufferPointer { r in c2.withUnsafeMutableBufferPointer { c in
            h.process(l.baseAddress!, r.baseAddress!, 48_000, ctl: c.baseAddress!, apply: true) } } }
        #expect(c2.max()! < 0.01); #expect(db(amplitude(n, 300, 24_000, 48_000)) < -95)
    }
    @Test func compressorSteadyStateGain() {
        var c = Compressor(); c.thresholdDb = -18; c.ratio = 3; c.makeupDb = 3
        var x = [Float](repeating: 0.5, count: 48_000); var xr = x
        x.withUnsafeMutableBufferPointer { l in xr.withUnsafeMutableBufferPointer { r in c.process(l.baseAddress!, r.baseAddress!, 48_000) } }
        // -6 dBFS in, 12 dB over threshold -> 8 dB reduction, +3 makeup => -11 dBFS
        #expect(abs(db(x[47_000]) + 11) < 0.5, "got \(db(x[47_000]))")
    }
    @Test func limiterNeverExceedsCeiling() {
        var l = Limiter(); l.ceilingDb = -1
        var x = tone(300, 2.0, count: 48_000); var xr = x
        x.withUnsafeMutableBufferPointer { a in xr.withUnsafeMutableBufferPointer { b in l.process(a.baseAddress!, b.baseAddress!, 48_000) } }
        #expect(x.map { abs($0) }.max()! <= Float(pow(10, -1.0 / 20)) + 1e-6)
    }
    @Test func duckerTimeConstants() {
        var d = Ducker(); d.amountDb = 9; d.attackMs = 50; d.releaseMs = 400
        var g = [Float](repeating: 1, count: 48_000), on = g
        on.withUnsafeBufferPointer { t in g.withUnsafeMutableBufferPointer { o in d.process(trig: t.baseAddress!, gain: o.baseAddress!, 2400, enabled: true) } }
        #expect(abs(Double(d.currentDb) - (-9 * (1 - exp(-1.0)))) < 0.1)       // one attack time constant -> 63 %
        on.withUnsafeBufferPointer { t in g.withUnsafeMutableBufferPointer { o in d.process(trig: t.baseAddress!, gain: o.baseAddress!, 48_000, enabled: true) } }
        #expect(abs(Double(d.currentDb) + 9) < 0.01); #expect(abs(db(g[47_999]) + 9) < 0.01)
        let off = [Float](repeating: 0, count: 19_200)                         // 400 ms of release
        var g2 = [Float](repeating: 1, count: 19_200)
        off.withUnsafeBufferPointer { t in g2.withUnsafeMutableBufferPointer { o in d.process(trig: t.baseAddress!, gain: o.baseAddress!, 19_200, enabled: true) } }
        #expect(abs(Double(d.currentDb) - (-9 * exp(-1.0))) < 0.1)
    }
}

// MARK: PTT / mic / ducking through the mixer (offline)

@Suite struct MixerRenderTests {
    @Test func pushToTalkGatesTheMic() {
        let m = mixer(); var s = s0(); s.talkMode = .pushToTalk; s.voice.gateOn = false; m.settings = s
        m.push(id: AudioMixer.micID, left: tone(1000, 0.3, count: 4 * 48_000))
        let silent = m.renderOffline(frames: 24_000).l
        #expect(silent.map { abs($0) }.max()! < 1e-4)                         // key up: nothing on air
        m.setTalkHeld(true)
        let talking = m.renderOffline(frames: 24_000).l
        #expect(amplitude(talking, 1000, 8000, 24_000) > 0.15)                // key down: voice on air
        #expect(m.meters().micLive)
        m.setTalkHeld(false)
        let after = m.renderOffline(frames: 24_000).l
        #expect(after[12_000..<24_000].map { abs($0) }.max()! < 1e-4)           // released: closed again
        m.setTalkLatched(true)
        #expect(amplitude(m.renderOffline(frames: 24_000).l, 1000, 8000, 24_000) > 0.15)   // latched open
        #expect(AudioMixer.micLive(s, held: false, latched: false) == false)
        #expect(AudioMixer.micLive(s, held: true, latched: false))
        s.talkMode = .open; #expect(AudioMixer.micLive(s, held: false, latched: false))
        s.mic.mute = true; #expect(!AudioMixer.micLive(s, held: true, latched: true))
    }

    /// The headline behaviour: a 440 Hz game tone ducks by 9 dB under a louder voice tone, and comes back.
    @Test func duckingOfflineRender() {
        let m = mixer(); m.addSource(id: "device:g", active: true)
        var s = fresh(); s.duck = DuckSettings(); s.duck.amountDb = 9   // -9 dB, 50 ms / 400 ms
        s.voice.compOn = false; s.voice.limiterOn = false; m.settings = s
        let total = 182_400                                          // 3.8 s
        m.push(id: "device:g", left: tone(440, 0.2, count: total))
        m.push(id: AudioMixer.micID, left: tone(1000, 0.5, from: 48_000, count: 48_000, total: total))     // voice 1.0 s ... 2.0 s
        let o = m.renderOffline(frames: total).l
        let before = amplitude(o, 440, 24_000, 43_200), during = amplitude(o, 440, 78_000, 90_000), after = amplitude(o, 440, 172_800, 182_400)
        let voice = amplitude(o, 1000, 78_000, 90_000)
        #expect(abs(before - 0.2) < 0.004, "before \(before)")
        #expect(abs(db(during / before) + 9) < 0.5, "ducked by \(db(during / before)) dB")
        #expect(abs(db(after / before)) < 0.5, "recovered to \(db(after / before)) dB")
        #expect(voice > 0.4 && voice < 0.51, "voice \(voice)")                  // unity fader, no processing
        #expect(m.meters().duckDb > -1)                                         // released by the end
    }
    @Test func duckingTracksAmountAndDisable() {
        for (enabled, amount, expected) in [(true, 15.0, -15.0), (false, 9.0, 0.0)] {
            let m = mixer(); m.addSource(id: "device:g", active: true)
            var s = fresh(); s.duck.enabled = enabled; s.duck.amountDb = amount; s.voice.compOn = false; s.voice.limiterOn = false; m.settings = s
            m.push(id: "device:g", left: tone(440, 0.2, count: 96_000))
            m.push(id: AudioMixer.micID, left: tone(1000, 0.5, count: 96_000))
            let o = m.renderOffline(frames: 96_000).l
            #expect(abs(db(amplitude(o, 440, 72_000, 96_000) / 0.2) - expected) < 0.6)
        }
    }
    @Test func mutedMicDoesNotDuck() {
        let m = mixer(); m.addSource(id: "device:g", active: true)
        var s = fresh(); s.mic.mute = true; m.settings = s
        m.push(id: "device:g", left: tone(440, 0.2, count: 96_000)); m.push(id: AudioMixer.micID, left: tone(1000, 0.5, count: 96_000))
        let o = m.renderOffline(frames: 96_000).l
        #expect(abs(db(amplitude(o, 440, 48_000, 96_000) / 0.2)) < 0.3)
    }
    @Test func micAndPhoneDelaysAlign() {
        // an impulse in both sources: the mic is delayed by 100 ms, the phone by 0 -> they land 4800 frames apart
        let m = mixer(); m.addSource(id: "device:g", active: true)
        var s = fresh(); s.duck.enabled = false; s.voice = { var v = VoiceChainSettings(); v.hpfOn = false; v.denoiseOn = false; v.gateOn = false; v.compOn = false; v.limiterOn = false; return v }()
        s.mic.delayMs = 100; m.settings = s
        var imp = [Float](repeating: 0, count: 48_000); imp[20_000] = 0.5
        var gimp = [Float](repeating: 0, count: 48_000); gimp[20_000] = -0.5
        m.push(id: AudioMixer.micID, left: imp); m.push(id: "device:g", left: gimp)
        let o = m.renderOffline(frames: 48_000).l
        let lh = LookaheadLimiter.lookahead - 1          // master limiter look-ahead delays both equally
        #expect(abs(o[20_000 + lh] + 0.5) < 0.01)
        #expect(abs(o[24_800 + lh] - 0.5) < 0.02, "mic impulse at +100 ms: \(o[24_800 + lh])")
    }
    @Test func sidetoneAndMonitorBus() {
        let m = mixer(); m.addSource(id: "device:g", active: true)
        var s = fresh(); s.duck.enabled = false; s.voice.gateOn = false; s.voice.compOn = false; s.voice.limiterOn = false
        s.mic.delayMs = 500; s.monitor.enabled = true; s.monitor.sidetoneOn = true; s.monitor.sidetoneDb = -6.0206; m.settings = s
        nonisolated(unsafe) var mon = [Float]()
        m.monitorSink = { l, _, n in mon.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
        m.push(id: AudioMixer.micID, left: tone(1000, 0.4, count: 48_000))
        m.push(id: "device:g", left: tone(440, 0.2, count: 48_000))
        let prog = m.renderOffline(frames: 48_000).l
        #expect(mon.count == 48_000)
        // headphones: own voice immediately (sidetone, -6 dB => 0.2), program has it 500 ms late
        #expect(abs(amplitude(mon, 1000, 4800, 9600) - 0.2) < 0.01)
        #expect(amplitude(prog, 1000, 4800, 9600) < 0.01)
        #expect(amplitude(prog, 1000, 36_000, 46_000) > 0.35)
        #expect(abs(amplitude(mon, 440, 4800, 9600) - 0.2) < 0.01)              // game audio still heard
    }
    @Test func soloSendsPFLToHeadphonesOnly() {
        let m = mixer(); m.addSource(id: "device:g", active: true); m.addSource(id: "device:h", active: true)
        var s = s0(); s.phones["device:g"] = { var c = ChannelSettings(); c.solo = true; c.gainDb = -60; return c }(); s.monitor.enabled = true; m.settings = s
        nonisolated(unsafe) var mon = [Float]()
        m.monitorSink = { l, _, n in mon.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
        m.push(id: "device:g", left: tone(440, 0.4, count: 48_000)); m.push(id: "device:h", left: tone(1000, 0.4, count: 48_000))
        let prog = m.renderOffline(frames: 48_000).l
        #expect(amplitude(mon, 440, 4800, 40_000) > 0.38 && amplitude(mon, 1000, 4800, 40_000) < 0.01)   // pre-fader solo only
        #expect(amplitude(prog, 440, 4800, 40_000) < 0.001 && amplitude(prog, 1000, 4800, 40_000) > 0.38)  // program unaffected
    }
    @Test func masterLimiterPreventsClipping() {
        let m = mixer(); m.addSource(id: "device:a", active: true); m.addSource(id: "device:b", active: true); m.settings = s0()
        m.push(id: "device:a", left: tone(440, 0.9, count: 48_000)); m.push(id: "device:b", left: tone(440, 0.9, count: 48_000))
        let o = m.renderOffline(frames: 48_000).l
        #expect(o.map { abs($0) }.max()! <= 1.0)
    }
    @Test func jitterBufferServoStaysClickFree() {
        // real-time producer 0.02 % faster than the consumer, 60 ms prebuffer: the read-speed servo must keep the ring bounded
        // and the output free of discontinuities
        let m = AudioMixer(jitterTargetMs: 60); m.addSource(id: "device:a", active: true); m.settings = s0()
        var out = [Float](), pos = 0
        for it in 0..<1500 {
            let n = 480 + (it % 10 == 0 ? 1 : 0)
            m.push(id: "device:a", left: (0..<n).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double(pos + $0) / sr)) }); pos += n
            out += m.renderOffline(frames: 480).l
        }
        guard let first = out.firstIndex(where: { abs($0) > 0.01 }) else { Issue.record("no audio"); return }
        #expect(first > 2000 && first < 4500, "prebuffer delay \(first) frames")
        var maxStep: Float = 0
        for i in (first + 200)..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        #expect(maxStep < 0.04, "step \(maxStep)")
        #expect(m.bufferedFrames(id: "device:a") < 6000, "ring level \(m.bufferedFrames(id: "device:a"))")
    }
}

// MARK: sample rate conversion

@Suite struct AudioConversionTests {
    func pcm(rate: Double, channels: AVAudioChannelCount, interleaved: Bool = false, int16: Bool = false, f: Double, from: Int, n: Int) -> AVAudioPCMBuffer {
        let fmt = channels > 2
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!)
            : AVAudioFormat(commonFormat: int16 ? .pcmFormatInt16 : .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let v = 0.5 * sin(2 * Double.pi * f * Double(from + i) / rate)
            for c in 0..<Int(channels) {
                if int16 {
                    if interleaved { b.int16ChannelData![0][i * Int(channels) + c] = Int16(v * 32767) } else { b.int16ChannelData![c][i] = Int16(v * 32767) }
                } else { b.floatChannelData![c][i] = Float(v) }
            }
        }
        return b
    }
    func run(rate: Double, channels: AVAudioChannelCount, interleaved: Bool = false, int16: Bool = false, chunk: Int) -> (clean: Bool, amp: Float, stereo: Bool) {
        let m = mixer(); m.addSource(id: "device:a", active: true); m.settings = s0()
        var pos = 0
        let secs = 2.0
        let total = Int(rate * secs)
        while pos < total { let n = min(chunk, total - pos); m.push(id: "device:a", buffers: pcm(rate: rate, channels: channels, interleaved: interleaved, int16: int16, f: 440, from: pos, n: n)); pos += n }
        let (l, r) = m.renderOffline(frames: 90_000)
        var maxStep: Float = 0
        for i in 600..<88_000 { maxStep = max(maxStep, abs(l[i] - l[i - 1])) }
        let step = 0.5 * 2 * Float.pi * 440 / 48_000
        return (maxStep < step * 1.5, amplitude(l, 440, 20_000, 80_000), (20_000..<20_100).allSatisfy { abs(l[$0] - r[$0]) < 1e-6 })
    }
    @Test func hls44100Stereo() { let r = run(rate: 44_100, channels: 2, chunk: 1024); #expect(r.clean); #expect(abs(r.amp - 0.5) < 0.01) }
    @Test func tapChunksOf441() { let r = run(rate: 44_100, channels: 2, chunk: 441); #expect(r.clean); #expect(abs(r.amp - 0.5) < 0.01) }
    @Test func bluetoothHFP16kMono() { let r = run(rate: 16_000, channels: 1, chunk: 320); #expect(r.clean); #expect(abs(r.amp - 0.5) < 0.02); #expect(r.stereo) }
    @Test func mic48kMonoAndInt16Interleaved() {
        let a = run(rate: 48_000, channels: 1, chunk: 480); #expect(a.clean); #expect(a.stereo); #expect(abs(a.amp - 0.5) < 0.01)
        let b = run(rate: 44_100, channels: 2, interleaved: true, int16: true, chunk: 700); #expect(b.clean); #expect(abs(b.amp - 0.5) < 0.01)
    }
    @Test func eightChannelInterfaceTakesFirstTwo() { let r = run(rate: 48_000, channels: 8, chunk: 480); #expect(r.clean); #expect(abs(r.amp - 0.5) < 0.01) }
    @Test func sampleBufferPathMatchesBufferPath() {
        // CMSampleBuffer (what the phone tap and the capture session deliver) -> mixer
        let m = mixer(); m.addSource(id: "device:a", active: true); m.settings = s0()
        let b = pcm(rate: 44_100, channels: 2, f: 440, from: 0, n: 44_100)
        var asbd = b.format.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let st1 = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 44_100,
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        let st2 = CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: b.audioBufferList)
        #expect(st1 == noErr && st2 == noErr, "st \(st1) \(st2)")
        m.push(id: "device:a", sampleBuffer: sb!)
        let o = m.renderOffline(frames: 40_000).l
        #expect(abs(amplitude(o, 440, 10_000, 40_000) - 0.5) < 0.01)
    }
}

// MARK: settings / devices

@Suite struct AudioSettingsTests {
    @Test func olderStoreLoadsAndRoundTrips() throws {
        let old = #"{"devices":[],"settings":{"name":"X"}}"#
        let doc = try JSONDecoder().decode(StoreDoc.self, from: Data(old.utf8))
        #expect(doc.settings.audio == nil)
        var a = AudioSettings(); a.mic.gainDb = -3; a.duck.amountDb = 12; a.phones["device:z"] = { var c = ChannelSettings(); c.delayMs = 250; return c }()
        var d2 = StoreDoc(); d2.settings.audio = a
        let back = try JSONDecoder().decode(StoreDoc.self, from: JSONEncoder().encode(d2))
        #expect(back.settings.audio == a)
        let partial = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"duck":{"amountDb":6},"mic":{"delayMs":5000}}"#.utf8))
        #expect(partial.duck.amountDb == 6 && partial.duck.attackMs == 50 && partial.duck.releaseMs == 400)
        #expect(partial.mic.delayMs == 2000)                                     // clamped
        #expect(AudioSettings().duck.amountDb == 6 && AudioSettings().mic.delayMs == 0 && AudioSettings().phoneDefault.delayMs == 0)
    }
    @Test func storePersistsAudioSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-store-\(UUID().uuidString)")
        let st = try StudioStore(dir: dir)
        var a = AudioSettings(); a.masterDb = -4; st.setAudio(a)
        let again = try StudioStore(dir: dir)
        #expect(again.settings.audio?.masterDb == -4)
    }
    @Test func feedbackWarning() {
        func dev(_ t: AudioDeviceInfo.Transport, speaker: Bool = false, uid: String = "u") -> AudioDeviceInfo {
            AudioDeviceInfo(id: 1, uid: uid, name: "Dev", hasInput: true, hasOutput: true, transport: t, isBuiltInSpeaker: speaker)
        }
        #expect(FeedbackCheck.warning(mic: dev(.builtIn), monitor: dev(.builtIn, speaker: true, uid: "s")) != nil)      // speakers + built-in mic
        #expect(FeedbackCheck.warning(mic: dev(.builtIn), monitor: dev(.builtIn, speaker: false, uid: "s")) == nil)     // headphone jack
        #expect(FeedbackCheck.warning(mic: dev(.usb, uid: "m"), monitor: dev(.bluetooth, uid: "s")) == nil)
        #expect(FeedbackCheck.warning(mic: dev(.usb, uid: "m"), monitor: dev(.builtIn, speaker: true, uid: "s")) == nil)
        #expect(FeedbackCheck.warning(mic: dev(.usb, uid: "a"), monitor: dev(.hdmi, uid: "a")) != nil)                  // same device
    }
    @Test func deviceListDoesNotCrash() {
        let all = AudioDevices.all()
        for d in all { #expect(!d.uid.isEmpty) }
        _ = AudioDevices.defaultDevice(input: true); _ = AudioDevices.defaultDevice(input: false)
    }
    @Test func micPermissionNeverPromptsUnbundled() {
        // `swift test` binary has no NSMicrophoneUsageDescription: requesting access would kill the process
        #expect(!MicSource.canPrompt)
        nonisolated(unsafe) var answered = false
        if MicSource.authorization == .notDetermined { MicSource.requestAccess { _ in answered = true }; #expect(answered) }
    }
}

// MARK: integration: real OutputPipeline recording with synthetic commentary + game audio

private func solidNV12() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(b, 0)!, 90, CVPixelBufferGetBytesPerRowOfPlane(b, 0) * 1080)
    memset(CVPixelBufferGetBaseAddressOfPlane(b, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * 540)
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}
private func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
    try? p.run()
    let d = o.fileHandleForReading.readDataToEndOfFile() + e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

@Suite(.serialized) struct AudioOutputIntegrationTests {
    @Test func recordedMP4HasAudibleAACStereo48k() async throws {
        guard let ff = FFmpegLocator.locate(), let probe = FFmpegLocator.ffprobe(besides: ff) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rec.mp4")
        let out = OutputPipeline()
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = url
        try out.start(cfg)

        let mx = AudioMixer()
        mx.addSource(id: "device:g")
        mx.setProgramSources(["device:g"])
        var s = fresh(); s.duck.amountDb = 9; s.voice.compOn = true; mx.settings = s
        mx.start(sink: out, originTicks: MachTime.now)

        let frame = solidNV12()
        let t0 = CFAbsoluteTimeGetCurrent()
        var aPos = 0
        var game = 0, voice = 0
        for i in 0..<300 {                                           // 5 s of 60 fps
            let due = t0 + Double(i) / 60
            while CFAbsoluteTimeGetCurrent() < due { try await Task.sleep(nanoseconds: 500_000) }
            out.submit(video: frame, pts: CMTime(value: Int64(i), timescale: 60))
            // producers: game audio (phone, 44.1 kHz) + mic voice (1 kHz bursts from 2 s) delivered in real time
            while Double(aPos) / 48_000 < Double(i + 1) / 60 {
                let n = 800
                let g = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!, frameCapacity: 735)!
                g.frameLength = 735
                for k in 0..<735 { let v = Float(0.25 * sin(2 * Double.pi * 440 * Double(game + k) / 44_100)); g.floatChannelData![0][k] = v; g.floatChannelData![1][k] = v }
                game += 735
                mx.push(id: "device:g", buffers: g)
                var v = [Float](repeating: 0, count: n)
                if aPos >= 96_000 { for k in 0..<n { v[k] = Float(0.4 * sin(2 * Double.pi * 1000 * Double(voice + k) / 48_000)) }; voice += n }
                mx.push(id: AudioMixer.micID, left: v)
                aPos += n
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        mx.stop()
        await out.stop()

        let info = runTool(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name,channels,sample_rate,duration", "-of", "default=nw=0", url.path])
        print("AUDIO ffprobe:\n\(info)")
        #expect(info.contains("codec_name=aac")); #expect(info.contains("channels=2")); #expect(info.contains("sample_rate=48000"))
        let vol = runTool(ff, ["-hide_banner", "-i", url.path, "-vn", "-af", "volumedetect", "-f", "null", "-"])
        func val(_ key: String) -> Double? {
            guard let r = vol.range(of: key + ": ") else { return nil }
            return Double(vol[r.upperBound...].prefix { !" \n".contains($0) })
        }
        print("AUDIO volumedetect: mean=\(val("mean_volume") ?? .nan) max=\(val("max_volume") ?? .nan)")
        let mean = try #require(val("mean_volume")), mx2 = try #require(val("max_volume"))
        #expect(mean > -40, "audible: mean \(mean) dB"); #expect(mx2 > -15 && mx2 < 0, "max \(mx2) dB")
        // the ducked section (voice present) should carry both tones: compare 440 Hz level before/while voice
        let early = runTool(ff, ["-hide_banner", "-ss", "0.5", "-t", "1.0", "-i", url.path, "-vn", "-af", "volumedetect", "-f", "null", "-"])
        #expect(early.contains("mean_volume"))
    }
}

// MARK: phone path: fake phone -> real MediaMTX -> PhoneAudioReader -> mixer

@Suite(.serialized) struct PhoneAudioWiringTests {
    @Test func phoneLatencyCompensationDelaysPhonesNotMic() {
        let m = mixer(); m.addSource(id: "device:p", active: true)
        var s = AudioSettings(); s.duck.enabled = false; s.phoneLatencyMs = 250; s.phoneDefault.delayMs = 50; m.settings = s
        var imp = [Float](repeating: 0, count: 48_000); imp[10_000] = 0.5
        m.push(id: "device:p", left: imp)
        let o = m.renderOffline(frames: 48_000).l
        let at = o.firstIndex { abs($0) > 0.2 } ?? -1
        #expect(at == 10_000 + AudioMath.msToFrames(300) + LookaheadLimiter.lookahead - 1, "phone impulse landed at \(at)")   // + master limiter look-ahead
    }

    @Test func readerDecodesAnyInputTo48kStereo() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        _ = runTool(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "3", "-c:a", "aac", f.path])
        let m = AudioMixer(jitterTargetMs: 60); m.addSource(id: "device:r", active: true, jitterMs: 150)
        var s = fresh(); s.duck.enabled = false; m.settings = s
        let rd = PhoneAudioReader(input: f.path, inputArgs: ["-re"], ffmpegPath: ff) { l, r in m.push(id: "device:r", left: l, right: r) }
        rd.start(); defer { rd.stop() }
        var all = [Float]()
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 50_000_000); all += m.renderOffline(frames: 2400).l }
        let a = rms(all[60_000..<100_000]) * Float(2).squareRoot()      // the servo may bend pitch by up to 1 % while it settles: measure level, not a fixed bin
        print("READER bytes=\(rd.bytesRead) restarts=\(rd.restarts) peak=\(all.map { abs($0) }.max() ?? 0) nonzero=\(all.filter { abs($0) > 0.01 }.count)/\(all.count) buffered=\(m.bufferedFrames(id: "device:r"))")
        #expect(a > 0.1 && a < 0.16, "440 Hz amplitude \(a)")
    }

    /// The whole chain: a fake phone publishes RTMP (video + 440 Hz AAC) to the real MediaMTX; the Studio engine puts it on
    /// Program; the audio that reaches the output sink must carry the tone, and must not before it is on Program.
    @Test func phoneOnProgramReachesTheOutputMix() async throws {
        guard let ff = FFmpegLocator.locate(), MediaMTXSupervisor.findBinary() != nil else { return }
        let ports = MediaMTXPorts(studio: 4421, rtmp: 1961, hls: 8914, api: 9915)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let svc = try IngestService(dir: dir, ports: ports)
        svc.start(); defer { svc.stop() }
        let created = try svc.devices.create(name: "Fake phone")
        let base = "http://127.0.0.1:\(ports.studio)"
        func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
            r.setValue(created.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
        }
        for _ in 0..<30 { if (try? await post("/api/device/hello", ["deviceModel": "iPhone15,2", "osVersion": "17.0", "appVersion": "1.0"]))?.0 == 200 { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let start = try await post("/api/device/stream/start", ["quality": "1080p", "fps": 30])
        let name = try #require(start.1["streamName"] as? String)
        let pub = Process(); pub.executableURL = URL(fileURLWithPath: ff)
        pub.arguments = ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                         "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-f", "flv",
                         "rtmp://127.0.0.1:\(ports.rtmp)/live/\(name)"]
        pub.standardOutput = Pipe(); pub.standardError = Pipe()
        try pub.run(); defer { pub.terminate() }

        final class Sink: VideoSink, @unchecked Sendable {
            let lock = NSLock(); var samples = [Float]()
            func submit(video: CVPixelBuffer, pts: CMTime) {}
            func submit(audio: CMSampleBuffer) {
                guard let bb = CMSampleBufferGetDataBuffer(audio) else { return }
                var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                let n = len / 8
                ptr!.withMemoryRebound(to: Float.self, capacity: n * 2) { f in lock.lock(); for i in 0..<n { samples.append(f[2 * i]) }; lock.unlock() }
            }
        }
        let sink = Sink()
        let engine = StudioEngine()
        var s = fresh(); s.duck.enabled = false; s.phoneLatencyMs = 0; engine.audio.settings = s
        let mx = engine.audio
        svc.sourceProvider.onPhoneCreated = { mx.addSource(id: $0, followsProgram: true, jitterMs: 150) }
        svc.sourceProvider.phoneAudio = { k, l, r in mx.push(id: k, left: l, right: r) }
        #expect(engine.start(fps: 60, sink: sink, provider: svc.sourceProvider))
        defer { engine.stop() }
        let scene = Scene(id: "p", name: "p", layout: .full, slots: [.device(id: created.device.id)])
        engine.setPreview(scene)                                    // preview only: the phone source exists, audio must stay off the mix
        try await Task.sleep(nanoseconds: 6_000_000_000)
        let beforeCount = sink.lock.withLock { sink.samples.count }
        let pre = sink.lock.withLock { sink.samples }
        #expect(beforeCount > 48_000 * 4)
        #expect(pre.map { abs($0) }.max() ?? 1 < 0.001, "phone leaked into the mix while not on Program")
        engine.setProgram(scene, fade: false)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let all = sink.lock.withLock { sink.samples }
        let tail = Array(all[(all.count - 48_000 * 2)...])
        let a = rms(tail[...]) * Float(2).squareRoot()
        print("PHONE->MIX 440Hz amplitude on Program: \(a) (source tone 0.125 default sine amplitude)")
        #expect(a > 0.09 && a < 0.16, "phone audio level on Program: \(a)")
    }
}
