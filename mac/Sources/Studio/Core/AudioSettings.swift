// Persisted mixer / commentary settings (additive: every key is optional when decoding, so older stores keep loading).
import Foundation

struct ChannelSettings: Codable, Hashable {
    var gainDb = 0.0
    var mute = false
    var solo = false          // PFL: sends the channel to the operator's headphones only, never changes the broadcast
    var delayMs = 0.0         // 0...2000
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        gainDb = (try? c.decodeIfPresent(Double.self, forKey: .gainDb)) ?? gainDb
        mute = (try? c.decodeIfPresent(Bool.self, forKey: .mute)) ?? mute
        solo = (try? c.decodeIfPresent(Bool.self, forKey: .solo)) ?? solo
        delayMs = min(2000, max(0, (try? c.decodeIfPresent(Double.self, forKey: .delayMs)) ?? delayMs))
    }
    private enum K: String, CodingKey { case gainDb, mute, solo, delayMs }
}

enum TalkMode: String, Codable, CaseIterable { case open, pushToTalk }

struct VoiceChainSettings: Codable, Hashable {
    var hpfOn = true, hpfHz = 80.0
    var gateOn = true, gateThresholdDb = -45.0, gateReductionDb = 60.0, gateHoldMs = 150.0
    var compOn = true, compThresholdDb = -18.0, compRatio = 3.0, compMakeupDb = 3.0
    var limiterOn = true, limiterCeilingDb = -1.0
    /// "Voice clean-up": spectral noise suppression (fans, hiss, room tone) ahead of the gate; strength 0...1.
    var denoiseOn = true, denoiseStrength = 0.6
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        denoiseOn = v(.denoiseOn, denoiseOn); denoiseStrength = v(.denoiseStrength, denoiseStrength)
        hpfOn = v(.hpfOn, hpfOn); hpfHz = v(.hpfHz, hpfHz)
        gateOn = v(.gateOn, gateOn); gateThresholdDb = v(.gateThresholdDb, gateThresholdDb)
        gateReductionDb = v(.gateReductionDb, gateReductionDb); gateHoldMs = v(.gateHoldMs, gateHoldMs)
        compOn = v(.compOn, compOn); compThresholdDb = v(.compThresholdDb, compThresholdDb)
        compRatio = v(.compRatio, compRatio); compMakeupDb = v(.compMakeupDb, compMakeupDb)
        limiterOn = v(.limiterOn, limiterOn); limiterCeilingDb = v(.limiterCeilingDb, limiterCeilingDb)
        if gateReductionDb == 40 { gateReductionDb = 60 }     // the old default let room noise through only 40 dB down
    }
    private enum K: String, CodingKey { case denoiseOn, denoiseStrength, hpfOn, hpfHz, gateOn, gateThresholdDb, gateReductionDb, gateHoldMs, compOn, compThresholdDb, compRatio, compMakeupDb, limiterOn, limiterCeilingDb }
}

struct DuckSettings: Codable, Hashable {
    var enabled = true
    var amountDb = 6.0            // how far the game audio drops while you talk (9 dB was the old default and ducked on room noise)
    var attackMs = 50.0, releaseMs = 400.0
    /// Speech detector (RMS of the mic, dBFS): ducking only starts above this, so room noise / fans never lower the game audio.
    var thresholdDb = -35.0
    var holdMs = 300.0
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        enabled = v(.enabled, enabled); amountDb = v(.amountDb, amountDb); attackMs = v(.attackMs, attackMs); releaseMs = v(.releaseMs, releaseMs)
        thresholdDb = v(.thresholdDb, thresholdDb); holdMs = v(.holdMs, holdMs)
        if amountDb == 9 { amountDb = 6 }          // the old default: move to the gentler one (an explicit 9 is indistinguishable, and still one slider drag away)
    }
    private enum K: String, CodingKey { case enabled, amountDb, attackMs, releaseMs, thresholdDb, holdMs }
}

struct MonitorSettings: Codable, Hashable {
    var enabled = false
    var deviceUID: String? = nil          // nil = system default output
    var levelDb = 0.0
    var sidetoneOn = false, sidetoneDb = -6.0
    var headphonesOnly = true             // refuse to monitor through built-in speakers (feedback guard)
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        enabled = v(.enabled, enabled); deviceUID = v(.deviceUID, deviceUID); levelDb = v(.levelDb, levelDb)
        sidetoneOn = v(.sidetoneOn, sidetoneOn); sidetoneDb = v(.sidetoneDb, sidetoneDb); headphonesOnly = v(.headphonesOnly, headphonesOnly)
    }
    private enum K: String, CodingKey { case enabled, deviceUID, levelDb, sidetoneOn, sidetoneDb, headphonesOnly }
}

struct AudioSettings: Codable, Hashable {
    var mic = ChannelSettings()
    var phoneDefault = ChannelSettings()
    var phones: [String: ChannelSettings] = [:]      // keyed by mixer source id ("device:<id>")
    var masterDb = 0.0
    var masterMute = false
    /// How far the decoded phone picture lags the live phone audio (read near-live over RTMP). Phone audio is delayed by this plus the
    /// channel's own delay. The picture path (ffmpeg remux -> VideoToolbox -> 50-80 ms jitter buffer -> engine frame) measures ~80-120 ms
    /// (PhoneSource.metrics.latency, plus ~one 60 Hz frame of compositing); tune per setup with the phone latency control.
    static let defaultPhoneLatencyMs = 120.0
    var phoneLatencyMs = AudioSettings.defaultPhoneLatencyMs
    var voice = VoiceChainSettings()
    var duck = DuckSettings()
    var talkMode = TalkMode.open
    var micEnabled = true
    var micDeviceUID: String? = nil                  // nil = system default input
    var monitor = MonitorSettings()
    /// Phone (game) audio clean-up, off by default: noise suppression and a gentle downward expander for hissy phone feeds.
    var phoneDenoiseOn = false, phoneDenoiseStrength = 0.4
    var phoneGateOn = false, phoneGateThresholdDb = -60.0
    /// Optional 80 Hz rumble filter on the master bus.
    var masterHpfOn = false, masterHpfHz = 80.0
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        phoneDenoiseOn = v(.phoneDenoiseOn, phoneDenoiseOn); phoneDenoiseStrength = v(.phoneDenoiseStrength, phoneDenoiseStrength)
        phoneGateOn = v(.phoneGateOn, phoneGateOn); phoneGateThresholdDb = v(.phoneGateThresholdDb, phoneGateThresholdDb)
        masterHpfOn = v(.masterHpfOn, masterHpfOn); masterHpfHz = v(.masterHpfHz, masterHpfHz)
        mic = v(.mic, mic); phoneDefault = v(.phoneDefault, phoneDefault); phones = v(.phones, phones)
        masterDb = v(.masterDb, masterDb); masterMute = v(.masterMute, masterMute); phoneLatencyMs = min(2000, max(0, v(.phoneLatencyMs, phoneLatencyMs)))
        if phoneLatencyMs == 1000 { phoneLatencyMs = AudioSettings.defaultPhoneLatencyMs }   // old HLS-era default
        voice = v(.voice, voice); duck = v(.duck, duck); talkMode = v(.talkMode, talkMode)
        micEnabled = v(.micEnabled, micEnabled); micDeviceUID = v(.micDeviceUID, micDeviceUID); monitor = v(.monitor, monitor)
    }
    private enum K: String, CodingKey { case mic, phoneDefault, phones, masterDb, masterMute, phoneLatencyMs, voice, duck, talkMode, micEnabled, micDeviceUID, monitor, phoneDenoiseOn, phoneDenoiseStrength, phoneGateOn, phoneGateThresholdDb, masterHpfOn, masterHpfHz }

    func channel(_ id: String) -> ChannelSettings {
        id == AudioMixer.micID ? mic : (phones[id] ?? phoneDefault)
    }
}
