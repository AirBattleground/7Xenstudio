// Commentator microphone switch for the Studio home screen (transition bar + the player's hover bar).
// Same source of truth as the Audio page: AudioController.settings (mic mute / input device / fader), persisted by the controller.
import SwiftUI
import AppKit

enum MicUIState: Equatable {
    case live, muted, holdToTalk
    case needsPermission, denied, noDevice(String)

    var isWarning: Bool { switch self { case .needsPermission, .denied, .noDevice: true; default: false } }

    static func resolve(_ s: AudioSettings, status: MicSource.Status, held: Bool, latched: Bool, inputCount: Int) -> MicUIState {
        if s.micEnabled {
            switch status {
            case .denied: return .denied
            case .needsPermission: return .needsPermission
            case .noDevice(let t), .failed(let t): return .noDevice(t)
            default: if inputCount == 0 { return .noDevice("No microphone found") }
            }
        }
        if AudioMixer.micLive(s, held: held, latched: latched) { return .live }
        return (s.micEnabled && !s.mic.mute && s.talkMode == .pushToTalk) ? .holdToTalk : .muted
    }
}

/// Segmented level meter drawn with CALayers and refreshed by an AppKit timer: no SwiftUI invalidation per update
/// (every SwiftUI graph update of this window costs ~10 ms of main thread, so a 20 Hz TimelineView cost ~20 % of a core).
private struct MicLevelMeter: NSViewRepresentable {
    let audio: AudioController
    var live: Bool
    var segments: Int
    final class V: NSView {
        var level: () -> Float = { 0 }
        var segs: [CALayer] = []
        var lit = -1
        private var timer: Timer?
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }
        func configure(segments n: Int) {
            guard segs.count != n else { return }
            segs.forEach { $0.removeFromSuperlayer() }
            segs = (0..<n).map { _ in let l = CALayer(); l.cornerRadius = 1; layer?.addSublayer(l); return l }
            lit = -1; needsLayout = true
        }
        override func layout() {
            super.layout()
            guard !segs.isEmpty else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let gap: CGFloat = 1.5, w = (bounds.width - gap * CGFloat(segs.count - 1)) / CGFloat(segs.count)
            for (i, l) in segs.enumerated() { l.frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: max(0, w), height: bounds.height) }
            CATransaction.commit(); lit = -1; update()
        }
        func update() {
            guard !segs.isEmpty else { return }
            let n = Int((CGFloat(max(0, min(1, level())).squareRoot()) * CGFloat(segs.count)).rounded())
            guard n != lit else { return }
            lit = n
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, l) in segs.enumerated() {
                let frac = Double(i) / Double(segs.count)
                let c = frac > 0.88 ? NSColor(Theme.program) : frac > 0.7 ? NSColor(Theme.warn) : NSColor(Theme.ok)
                l.backgroundColor = c.withAlphaComponent(i < n ? 1 : 0.14).cgColor
            }
            CATransaction.commit()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate(); timer = nil
            guard window != nil else { return }
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.update() }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common); timer = t
        }
        deinit { timer?.invalidate() }
    }
    func makeNSView(context: Context) -> V { let v = V(frame: .zero); v.configure(segments: segments); v.level = levelFn(); return v }
    func updateNSView(_ v: V, context: Context) { v.configure(segments: segments); v.level = levelFn(); v.lit = -1; v.update() }
    private func levelFn() -> () -> Float {
        let a = audio, on = live
        return { on ? (a.meters().channels[AudioMixer.micID]?.peak ?? 0) : 0 }
    }
}

struct MicSwitch: View {
    let audio: AudioController
    var compact = false
    @State private var pressed = false
    @State private var showPanel = false
    @State private var sound = false

    var body: some View {
        let state = MicUIState.resolve(audio.settings, status: audio.micStatus, held: audio.pttHeld, latched: audio.latched, inputCount: audio.inputDevices.count)
        // "You're muted" needs the gate state: sampled 4x/s, and the view is only invalidated when it flips.
        content(state, sound: sound)
            .onReceive(Timer.publish(every: 0.25, tolerance: 0.1, on: .main, in: .common).autoconnect()) { _ in
                let s = audio.settings.voice.gateOn && audio.meters().gateOpen > 0.5
                if s != sound { sound = s }
            }
    }

    @ViewBuilder private func content(_ state: MicUIState, sound: Bool) -> some View {
        let live = state == .live
        let tint: Color = live ? Theme.ok : state.isWarning ? Theme.warn : state == .holdToTalk ? Theme.muted : Theme.program
        let youreMuted = (state == .muted || state == .holdToTalk) && sound
        HStack(spacing: compact ? 6 : 8) {
            if state.isWarning {
                warning(state)
            } else {
                button(state, tint: tint, youreMuted: youreMuted)
                MicLevelMeter(audio: audio, live: live, segments: compact ? 8 : 12)
                    .frame(width: compact ? 40 : 64, height: 6).opacity(live ? 1 : 0.35)
            }
            Button { showPanel.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 18, height: compact ? 24 : 30)
                    .foregroundStyle(compact ? Color.white : Theme.muted)
            }
            .buttonStyle(.plain).help("Microphone input, level and Audio mixer").accessibilityLabel("Microphone options")
            .popover(isPresented: $showPanel, arrowEdge: .bottom) { MicPanel(audio: audio, close: { showPanel = false }) }
        }
    }

    private func button(_ state: MicUIState, tint: Color, youreMuted: Bool) -> some View {
        let live = state == .live
        let label = youreMuted ? "YOU'RE MUTED" : live ? "MIC LIVE" : state == .holdToTalk ? "HOLD TO TALK" : "MIC MUTED"
        return HStack(spacing: 6) {
            Image(systemName: live ? "mic.fill" : "mic.slash.fill").font(.system(size: compact ? 12 : 15, weight: .bold))
            if !compact {
                Text(label).font(.system(size: 11, weight: .heavy)).tracking(0.8).lineLimit(1).fixedSize()
                if youreMuted { StatusDot(color: Theme.warn, pulse: true) }
            } else if youreMuted { StatusDot(color: Theme.warn, pulse: true) }
        }
        .foregroundStyle(live ? Color.black.opacity(0.85) : Color.white)
        .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 24 : 34)
        .background(live ? tint : tint.opacity(0.28), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(tint.opacity(live ? 0 : 0.8), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                if audio.settings.talkMode == .pushToTalk { if audio.settings.mic.mute { audio.setMicMuted(false) }; audio.pttHeld = true }
            }
            .onEnded { _ in
                pressed = false
                if audio.settings.talkMode == .pushToTalk { audio.pttHeld = false } else { audio.toggleMicMute() }
            })
        .help(audio.settings.talkMode == .pushToTalk ? "Hold to talk (or hold T). M toggles mute." : "Click to mute or unmute the commentary mic (M)")
        .accessibilityElement().accessibilityLabel("Microphone").accessibilityValue(label)
        .accessibilityAddTraits(.isButton).accessibilityAction { audio.toggleMicMute() }
    }

    private func warning(_ state: MicUIState) -> some View {
        let (text, action): (String, String) = {
            switch state {
            case .denied: return ("Mic blocked", "Open Settings")
            case .needsPermission: return ("Mic needs permission", "Allow")
            case .noDevice(let t): return (t, "Choose")
            default: return ("", "")
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            if !compact { Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(1).frame(maxWidth: 150, alignment: .leading) }
            Button(action) { if case .noDevice = state { showPanel = true } else { audio.requestOrOpenMicSettings() } }
                .buttonStyle(.studio(.secondary, height: compact ? 22 : 28))
        }
        .help(state == .denied ? MicSource.Status.denied.text : text)
    }
}

/// Popover behind the chevron: input device, mic fader and a shortcut to the Audio page.
struct MicPanel: View {
    let audio: AudioController
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Microphone").font(.system(size: 12, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                deviceRow("System default", uid: nil)
                ForEach(audio.inputDevices) { d in deviceRow(d.label, uid: d.uid) }
                if let uid = audio.settings.micDeviceUID, !audio.inputDevices.contains(where: { $0.uid == uid }) {
                    Text("Selected microphone is not connected").font(Theme.Font.caption).foregroundStyle(Theme.warn).padding(.leading, 22)
                }
            }
            Divider()
            LabeledSlider(label: "Mic level", value: Binding(get: { audio.channel(AudioMixer.micID).gainDb }, set: { v in audio.update(AudioMixer.micID) { $0.gainDb = v } }),
                          range: -30...12, step: 0.5, unit: "dB", format: "%+.1f")
            Divider()
            Button { close(); NotificationCenter.default.post(name: .studioNavigate, object: StudioPage.audio.rawValue) } label: {
                Label("Open Audio mixer…", systemImage: "slider.vertical.3")
            }.buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .padding(14).frame(width: 270)
        .onAppear { audio.refreshDevices() }
    }
    private func deviceRow(_ title: String, uid: String?) -> some View {
        let sel = audio.settings.micDeviceUID == uid
        return Button { audio.selectMicInput(uid) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").opacity(sel ? 1 : 0).frame(width: 14)
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12, weight: sel ? .semibold : .regular)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(sel ? .isSelected : [])
    }
}
