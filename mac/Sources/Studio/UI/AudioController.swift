// UI-side owner of the commentary audio chain: mixer settings (persisted), mic capture, headphone monitor, device
// hot-plug, push-to-talk key handling and the warnings the Audio page shows.
import SwiftUI
import AppKit
import Observation

@MainActor @Observable
final class AudioController {
    @ObservationIgnored let mixer: AudioMixer
    @ObservationIgnored private let store: StudioStore?
    @ObservationIgnored let mic: MicSource
    @ObservationIgnored let monitor = MonitorOutput()
    @ObservationIgnored private var hwToken: AudioDevices.Token?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var muteStopTask: Task<Void, Never>?
    @ObservationIgnored private var micStartedFor: (uid: String?, defaultID: UInt32)?
    @ObservationIgnored private var monitorStartedFor: (uid: String?, defaultID: UInt32)?

    var settings: AudioSettings {
        didSet {
            guard settings != oldValue else { return }
            mixer.settings = settings
            scheduleSave()
            if settings.micEnabled != oldValue.micEnabled || settings.micDeviceUID != oldValue.micDeviceUID { reconcileMic(force: true) }
            if settings.mic.mute != oldValue.mic.mute { muteChanged() }
            if settings.monitor != oldValue.monitor || settings.micDeviceUID != oldValue.micDeviceUID { reconcileMonitor(force: settings.monitor.deviceUID != oldValue.monitor.deviceUID || settings.monitor.enabled != oldValue.monitor.enabled) }
            if settings.talkMode != oldValue.talkMode { pttHeld = false; latched = false }
        }
    }
    var micStatus: MicSource.Status = .idle
    var inputDevices: [AudioDeviceInfo] = []
    var outputDevices: [AudioDeviceInfo] = []
    var monitorMessage: String?
    var feedbackWarning: String?
    var pttHeld = false { didSet { mixer.setTalkHeld(pttHeld) } }
    var latched = false { didSet { mixer.setTalkLatched(latched) } }

    init(mixer: AudioMixer, store: StudioStore?) {
        self.mixer = mixer; self.store = store
        mic = MicSource(mixer: mixer)
        settings = store?.settings.audio ?? AudioSettings()
        mixer.settings = settings
        mic.onStatus = { [weak self] s in Task { @MainActor in self?.micStatus = s } }
        monitor.onConfigChange = { [weak self] in Task { @MainActor in self?.reconcileMonitor(force: true) } }
        refreshDevices()
        hwToken = AudioDevices.observe { [weak self] in Task { @MainActor in self?.hardwareChanged() } }
        installKeys()
        reconcileMic(force: true)
        reconcileMonitor(force: true)
    }

    // MARK: persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store?.setAudio(self.settings)
        }
    }
    func flush() { saveTask?.cancel(); store?.setAudio(settings) }

    // MARK: bindings

    func channel(_ id: String) -> ChannelSettings { settings.channel(id) }
    func setChannel(_ id: String, _ c: ChannelSettings) {
        if id == AudioMixer.micID { settings.mic = c } else { settings.phones[id] = c }
    }
    func update(_ id: String, _ f: (inout ChannelSettings) -> Void) { var c = channel(id); f(&c); setChannel(id, c) }
    func meters() -> MixerMeters { mixer.meters() }
    var micLive: Bool { AudioMixer.micLive(settings, held: pttHeld, latched: latched) }

    // MARK: commentator mic switch (Studio home, menu bar, key M)

    /// True when the commentary mic is muted by the fader mute (the Audio page mute button) or switched off.
    var micMuted: Bool { settings.mic.mute || !settings.micEnabled }
    func setMicMuted(_ muted: Bool) { settings.mic.mute = muted; if !muted { settings.micEnabled = true } }
    func toggleMicMute() { setMicMuted(!micMuted) }
    func selectMicInput(_ uid: String?) { settings.micDeviceUID = uid }
    /// Asks for microphone access when the system can still prompt, otherwise opens System Settings > Privacy > Microphone.
    func requestOrOpenMicSettings() {
        if MicSource.authorization == .notDetermined, MicSource.canPrompt { reconcileMic(force: true) }
        else { Self.openMicPrivacySettings() }
    }
    static func openMicPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }

    // MARK: noise profile

    /// Learns the room noise of the mic (keep quiet for 2 s) / of a phone feed; the clean-up then subtracts exactly that spectrum.
    func learnMicNoise() { mixer.learnNoise(id: AudioMixer.micID) }
    func clearMicNoise() { mixer.clearNoiseProfile(id: AudioMixer.micID) }
    func learnPhoneNoise() { for id in mixer.sourceIDs where id.hasPrefix("device:") { mixer.learnNoise(id: id) } }
    func clearPhoneNoise() { for id in mixer.sourceIDs where id.hasPrefix("device:") { mixer.clearNoiseProfile(id: id) } }

    /// A muted mic already contributes exact digital silence; after 20 s of mute the capture session is released too
    /// (no room noise processed, the system mic indicator goes out) and restarted when un-muted.
    private func muteChanged() {
        muteStopTask?.cancel()
        if settings.mic.mute {
            muteStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.settings.mic.mute, self.settings.micEnabled else { return }
                self.mic.stop(); self.micStatus = .idle
            }
        } else if settings.micEnabled, !micStatus.isRunning { reconcileMic(force: true) }
    }

    // MARK: devices

    func refreshDevices() { inputDevices = AudioDevices.inputs(); outputDevices = AudioDevices.outputs() }

    private func hardwareChanged() {
        refreshDevices()
        reconcileMic(force: false)
        reconcileMonitor(force: false)
    }

    // MARK: mic

    func reconcileMic(force: Bool) {
        guard settings.micEnabled else { mic.stop(); micStatus = .idle; return }
        let defIn = AudioDevices.defaultDevice(input: true)?.id ?? 0
        if !force, micStatus.isRunning, micStartedFor?.uid == settings.micDeviceUID,
           settings.micDeviceUID != nil ? AudioDevices.device(uid: settings.micDeviceUID!) != nil : micStartedFor?.defaultID == defIn { return }
        if let uid = settings.micDeviceUID, AudioDevices.device(uid: uid) == nil {
            mic.stop(); micStatus = .noDevice("Selected microphone is not connected. It will resume when plugged back in."); return
        }
        let st = mic.start(deviceUID: settings.micDeviceUID)
        micStatus = st
        micStartedFor = (settings.micDeviceUID, defIn)
        if st == .needsPermission {
            MicSource.requestAccess { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    if ok { self.micStatus = self.mic.start(deviceUID: self.settings.micDeviceUID) } else { self.micStatus = MicSource.canPrompt ? .denied : .failed("Microphone access needs the bundled app (scripts/bundle.sh).") }
                }
            }
        }
    }

    // MARK: monitor

    private func stopMonitor() { mixer.monitorSink = nil; monitor.stop(); monitorStartedFor = nil }

    func reconcileMonitor(force: Bool) {
        let m = settings.monitor
        feedbackWarning = nil; monitorMessage = nil
        guard m.enabled else { stopMonitor(); return }
        let defOut = AudioDevices.defaultDevice(input: false)
        let dev: AudioDeviceInfo? = m.deviceUID.map { AudioDevices.device(uid: $0) } ?? defOut
        if m.deviceUID != nil, dev == nil { stopMonitor(); monitorMessage = "Headphones are not connected. Monitoring resumes when they are plugged back in."; return }
        let micDev = settings.micDeviceUID.map { AudioDevices.device(uid: $0) } ?? AudioDevices.defaultDevice(input: true)
        feedbackWarning = FeedbackCheck.warning(mic: micDev, monitor: dev)
        if m.headphonesOnly, let d = dev, d.isBuiltInSpeaker || d.transport == .hdmi {
            stopMonitor()
            monitorMessage = "Headphones only: \(d.name) is a speaker output, so monitoring is off. Plug in headphones or pick another output."
            return
        }
        if !force, monitor.running, monitorStartedFor?.uid == m.deviceUID, monitorStartedFor?.defaultID == (m.deviceUID == nil ? (defOut?.id ?? 0) : 0) { return }
        do {
            try monitor.start(deviceUID: m.deviceUID)
            monitorStartedFor = (m.deviceUID, m.deviceUID == nil ? (defOut?.id ?? 0) : 0)
            let mon = monitor
            mixer.monitorSink = { l, r, n in mon.write(l, r, n) }
        } catch {
            stopMonitor(); monitorMessage = "Monitor output failed: \(error.localizedDescription)"
        }
    }

    // MARK: push-to-talk key (hold T)

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            MainActor.assumeIsolated { self?.handleKey(ev) ?? ev }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pttHeld = false }
        }
    }
    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        if ev.keyCode == 46 {                                                            // M: toggle mic mute
            guard ev.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return ev }
            if NSApp.keyWindow?.firstResponder is NSText { return ev }
            if ev.type == .keyDown, !ev.isARepeat { toggleMicMute() }
            return nil
        }
        guard ev.keyCode == 17, settings.talkMode == .pushToTalk,                      // T
              ev.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return ev }
        if ev.type == .keyDown, NSApp.keyWindow?.firstResponder is NSText { return ev }  // typing in a text field
        if ev.type == .keyDown { if !ev.isARepeat { pttHeld = true } } else { pttHeld = false }
        return nil
    }

    func shutdown() {
        flush()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        muteStopTask?.cancel(); mic.stop(); stopMonitor()
    }
}
