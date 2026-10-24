// Audio page (vertical-fader mixer for live commentary) and the compact mixer used in the Studio inspector.
import SwiftUI
import AppKit

// MARK: - Meter + fader primitives

/// Vertical dB meter: dim bar = RMS, bright bar = peak. 60 dB range.
struct LevelMeter: View {
    var peak: Float; var rms: Float; var clip = false
    var width: CGFloat = 8
    static func pos(_ lin: Float) -> CGFloat { CGFloat(max(0, min(1, (AudioMath.linearToDb(lin) + 60) / 60))) }
    var body: some View {
        Canvas { ctx, size in
            let r = RoundedRectangle(cornerRadius: 2, style: .continuous).path(in: CGRect(origin: .zero, size: size))
            ctx.fill(r, with: .color(Theme.well))
            ctx.clip(to: r)
            let h = size.height
            func bar(_ p: CGFloat, _ opacity: Double) {
                let top = h * (1 - p)
                // green below -18 dB, amber to -6, red above
                let yAmber = h * (1 - 0.7), yRed = h * (1 - 0.9)
                for (y0, y1, c) in [(h, yAmber, Theme.ok), (yAmber, yRed, Theme.warn), (yRed, 0.0, Theme.program)] where top < y0 {
                    let a = max(top, y1)
                    ctx.fill(Path(CGRect(x: 0, y: a, width: size.width, height: y0 - a)), with: .color(c.opacity(opacity)))
                }
            }
            bar(LevelMeter.pos(rms), 0.45)
            let pk = LevelMeter.pos(peak)
            ctx.fill(Path(CGRect(x: 0, y: h * (1 - pk) - 1, width: size.width, height: 2)), with: .color(clip ? Theme.program : Theme.text.opacity(0.9)))
        }
        .frame(width: width)
        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityElement().accessibilityLabel("Level").accessibilityValue(String(format: "%.0f dB", AudioMath.linearToDb(peak)))
    }
}

func dbText(_ db: Double) -> String { db <= AudioMath.floorDb ? "-inf" : String(format: "%+.1f", db) }

/// Vertical fader with dB scale. Double-click resets to 0 dB.
struct VFader: View {
    @Binding var db: Double
    var height: CGFloat = 190
    var tint: Color = Theme.accent
    private let marks: [Double] = [6, 0, -10, -20, -40]
    var body: some View {
        let p = CGFloat(AudioMath.faderPosition(db: db))
        HStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                ForEach(marks, id: \.self) { m in
                    Text(m == 0 ? "0" : String(Int(m))).font(Theme.Font.mono(8)).foregroundStyle(m == 0 ? Theme.text : Theme.faint)
                        .frame(width: 18, alignment: .trailing)
                        .offset(y: height * (1 - CGFloat(AudioMath.faderPosition(db: m))) - 5)
                }
            }.frame(width: 18, height: height)
            ZStack(alignment: .top) {
                Capsule().fill(Theme.well).frame(width: 6)
                Capsule().fill(tint.opacity(0.5)).frame(width: 6, height: max(2, height * p)).frame(maxHeight: .infinity, alignment: .bottom)
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.92))
                    .frame(width: 30, height: 14)
                    .overlay(Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: height * (1 - p) - 7)
            }
            .frame(width: 34, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let pos = 1 - Double(v.location.y / height)
                db = (AudioMath.faderDb(position: pos) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { db = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Fader").accessibilityValue("\(dbText(db)) dB")
        .accessibilityAdjustableAction { dir in db = min(6, max(-60, db + (dir == .increment ? 1 : -1))) }
    }
}

struct SmallToggleButton: View {
    var title: String; var on: Bool; var color: Color; var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 22)
                .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.muted)
                .background(on ? color : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Strips

struct ChannelStrip: View {
    let audio: AudioController
    let id: String
    let title: String
    var subtitle: String? = nil
    var live = true                      // false: dimmed (phone not on Program)
    var isMic = false
    var body: some View {
        let ch = audio.channel(id)
        VStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(title).font(Theme.Font.bodyBold).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle ?? " ").font(Theme.Font.label).foregroundStyle(live ? Theme.ok : Theme.faint).lineLimit(1)
            }.frame(width: 84)
            HStack(spacing: 4) {
                Text(dbText(ch.gainDb)).font(Theme.Font.mono(11, .semibold)).foregroundStyle(ch.mute ? Theme.faint : Theme.text)
                    .frame(width: 48, height: 20).background(Theme.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                ClipLED(audio: audio, id: id)
            }
            HStack(alignment: .top, spacing: 6) {
                VFader(db: Binding(get: { audio.channel(id).gainDb }, set: { v in audio.update(id) { $0.gainDb = v } }),
                       tint: isMic ? Theme.program : Theme.accent)
                StripMeter(audio: audio, id: id)
            }
            HStack(spacing: 4) {
                SmallToggleButton(title: "M", on: ch.mute, color: Theme.program, help: "Mute \(title)") { audio.update(id) { $0.mute.toggle() } }
                SmallToggleButton(title: "S", on: ch.solo, color: Theme.warn, help: "Solo \(title) in headphones (PFL)") { audio.update(id) { $0.solo.toggle() } }
            }.frame(width: 84)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .card(fill: Theme.panelHi.opacity(0.6))
        .opacity(live ? 1 : 0.55)
    }
}

/// Meter that refreshes ~25 Hz straight from the mixer (no Observation churn).
struct StripMeter: View {
    let audio: AudioController
    let id: String?          // nil = master
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25)) { _ in
            let m = audio.meters()
            let c = id.map { m.channels[$0] ?? ChannelMeter() } ?? m.master
            LevelMeter(peak: c.peak, rms: c.rms, clip: c.clip)
        }
    }
}

/// CLIP lamp next to a strip's gain readout, latched ~1.5 s by the mixer. Channel: the source itself reached -0.5 dBFS before the
/// fader, or the fader pushed it into the channel's safety limiter (0 dBFS). Master: the bus hit 0 dBFS before the master limiter.
struct ClipLED: View {
    let audio: AudioController
    let id: String?          // nil = master
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
            let m = audio.meters()
            let on = (id.map { m.channels[$0]?.clip ?? false } ?? m.master.clip)
            Text("CLIP").font(.system(size: 8, weight: .heavy)).tracking(0.3)
                .foregroundStyle(on ? Color.white : Theme.faint)
                .frame(width: 30, height: 20)
                .background(on ? Theme.program : Theme.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help(id == nil ? "Master bus over 0 dBFS before the limiter: lower the master or the hottest channels"
                                : "Input too hot: the source reached -0.5 dBFS, or this fader is pushing it into the channel limiter. Lower the fader (0 dB or below).")
                .accessibilityLabel(on ? "Clipping" : "No clipping")
        }
    }
}

struct MasterStrip: View {
    let audio: AudioController
    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 1) {
                Text("Master").font(Theme.Font.bodyBold).foregroundStyle(Theme.text)
                Text("PROGRAM").font(Theme.Font.label).foregroundStyle(Theme.program)
            }.frame(width: 84)
            HStack(spacing: 4) {
                Text(dbText(audio.settings.masterDb)).font(Theme.Font.mono(11, .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 48, height: 20).background(Theme.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                ClipLED(audio: audio, id: nil)
            }
            HStack(alignment: .top, spacing: 6) {
                VFader(db: Binding(get: { audio.settings.masterDb }, set: { audio.settings.masterDb = $0 }), tint: Theme.program)
                StripMeter(audio: audio, id: nil)
                StripMeter(audio: audio, id: nil)
            }
            SmallToggleButton(title: "M", on: audio.settings.masterMute, color: Theme.program, help: "Mute master") { audio.settings.masterMute.toggle() }.frame(width: 84)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .card(fill: Theme.panelHi.opacity(0.6))
    }
}

/// Hold-to-talk button (also driven by the T key in push-to-talk mode).
struct TalkButton: View {
    let audio: AudioController
    var compact = false
    var body: some View {
        let ptt = audio.settings.talkMode == .pushToTalk
        let live = audio.micLive
        Group {
            if ptt {
                VStack(spacing: 2) {
                    Text(live ? "ON AIR" : "HOLD TO TALK").font(.system(size: compact ? 11 : 13, weight: .heavy)).tracking(1)
                    if !compact { Text("hold T, or click to latch").font(Theme.Font.mono(9)).opacity(0.7) }
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 28 : 44)
                .foregroundStyle(.white)
                .background(live ? Theme.program : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !audio.pttHeld { audio.pttHeld = true } }
                    .onEnded { _ in audio.pttHeld = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { audio.latched.toggle() })
                .help("Hold to talk. Double-click to latch the mic open.")
            } else {
                Button { audio.update(AudioMixer.micID) { $0.mute.toggle() } } label: {
                    Text(live ? "MIC LIVE" : "MIC MUTED").font(.system(size: compact ? 11 : 13, weight: .heavy)).tracking(1)
                        .frame(maxWidth: .infinity, minHeight: compact ? 28 : 44)
                }.buttonStyle(.studio(live ? .primary(Theme.program) : .secondary, height: compact ? 28 : 44))
            }
        }
        .accessibilityLabel("Talk").accessibilityValue(live ? "Mic live" : "Mic off")
    }
}

// MARK: - Page

struct AudioMixerPage: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let audio = model.services.audio {
            AudioMixerContent(audio: audio)
        } else {
            EmptyState(icon: "speaker.slash", title: "Audio is not available", message: "The mixer runs with the real studio backend.")
        }
    }
}

struct AudioMixerContent: View {
    @Environment(AppModel.self) var model
    let audio: AudioController

    func onProgram(_ deviceID: String) -> Bool {
        model.program?.slots.contains { if case .device(let id)? = $0 { return id == deviceID } else { return false } } ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio").font(Theme.Font.title).foregroundStyle(Theme.text)
                    Text("Commentary mixer: your voice over the phones' game audio, on air.").font(Theme.Font.body).foregroundStyle(Theme.muted)
                }
                AudioAlerts(audio: audio)
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(text: "Faders")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                ChannelStrip(audio: audio, id: AudioMixer.micID, title: "Mic",
                                             subtitle: audio.micLive ? "LIVE" : "OFF", live: audio.micStatus.isRunning, isMic: true)
                                ForEach(model.devices) { d in
                                    ChannelStrip(audio: audio, id: "device:\(d.id)", title: d.name, subtitle: onProgram(d.id) ? "ON PROGRAM" : "STANDBY", live: onProgram(d.id))
                                }
                                MasterStrip(audio: audio)
                            }.padding(.bottom, 2)
                        }
                        if model.devices.isEmpty { Text("Phones appear here as soon as you add them.").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
                        TalkPanel(audio: audio)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: Theme.Space.m) {
                        SyncPanel(audio: audio)
                        DuckPanel(audio: audio)
                        VoicePanel(audio: audio)
                        CleanupPanel(audio: audio)
                        HeadphonesPanel(audio: audio)
                    }.frame(width: 340)
                }
            }
            .padding(Theme.Space.xl).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
        }
        .toggleStyle(StudioToggleStyle())
        .onAppear { audio.refreshDevices() }
    }
}

struct AudioAlerts: View {
    let audio: AudioController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if audio.settings.micEnabled {
                switch audio.micStatus {
                case .denied:
                    alert("Microphone access is blocked. Allow 7XEN Studio in System Settings > Privacy & Security > Microphone.", Theme.program, action: ("Open Settings", {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }))
                case .needsPermission: alert("Waiting for microphone permission...", Theme.warn)
                case .noDevice(let s), .failed(let s): alert(s, Theme.warn)
                default: EmptyView()
                }
            }
            if let w = audio.feedbackWarning { alert(w, Theme.warn) }
            if let m = audio.monitorMessage { alert(m, Theme.warn) }
        }
    }
    func alert(_ text: String, _ color: Color, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).buttonStyle(.studio(.secondary, height: 24)) }
        }
        .padding(10).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(color.opacity(0.4)))
    }
}

// MARK: - Panels

struct LabeledSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String
    var format: String = "%.0f"
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(Theme.Font.caption).foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: format, value) + " " + unit).font(Theme.Font.mono(11)).foregroundStyle(Theme.text)
            }
            Slider(value: $value, in: range, step: step).controlSize(.small).accessibilityLabel(label)
        }
    }
}

struct TalkPanel: View {
    let audio: AudioController
    var body: some View {
        Panel(title: "Commentary mic", icon: "mic.fill", trailing: {
            Toggle("", isOn: Binding(get: { audio.settings.micEnabled }, set: { audio.settings.micEnabled = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }) {
            HStack(spacing: 8) {
                Picker("Input", selection: Binding(get: { audio.settings.micDeviceUID ?? "" }, set: { audio.settings.micDeviceUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(audio.inputDevices) { Text($0.label).tag($0.uid) }
                }.labelsHidden().frame(maxWidth: .infinity)
                IconButton(systemName: "arrow.clockwise", label: "Rescan audio devices") { audio.refreshDevices(); audio.reconcileMic(force: true) }
            }
            HStack(spacing: 6) {
                StatusDot(color: audio.micStatus.isRunning ? Theme.ok : Theme.faint)
                Text(audio.micStatus.isRunning ? "Capturing: \(audio.micStatus.text)" : audio.micStatus.text).font(Theme.Font.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Picker("Mode", selection: Binding(get: { audio.settings.talkMode }, set: { audio.settings.talkMode = $0 })) {
                Text("Open mic").tag(TalkMode.open)
                Text("Push to talk (T)").tag(TalkMode.pushToTalk)
            }.pickerStyle(.segmented).labelsHidden()
            TalkButton(audio: audio)
            if audio.settings.talkMode == .pushToTalk {
                Toggle("Latch open (hands-free)", isOn: Binding(get: { audio.latched }, set: { audio.latched = $0 }))
            }
        }
    }
}

struct SyncPanel: View {
    @Environment(AppModel.self) var model
    let audio: AudioController
    var body: some View {
        Panel(title: "Sync", icon: "timer") {
            LabeledSlider(label: "Mic delay", value: Binding(get: { audio.channel(AudioMixer.micID).delayMs }, set: { v in audio.update(AudioMixer.micID) { $0.delayMs = v } }),
                          range: 0...2000, step: 10, unit: "ms")
            LabeledSlider(label: "Phone audio delay (all phones)", value: Binding(get: { audio.settings.phoneDefault.delayMs }, set: { v in
                audio.settings.phoneDefault.delayMs = v
                for k in audio.settings.phones.keys { audio.settings.phones[k]?.delayMs = v }
            }), range: 0...2000, step: 10, unit: "ms")
            Text("Clap test: clap next to the phone while commenting, record a few seconds, and watch the clap in the Recordings page. If the voice comes late, raise Phone audio delay; if early, raise Mic delay. Leave both at 0 if it already looks right.")
                .font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DuckPanel: View {
    let audio: AudioController
    var body: some View {
        Panel(title: "Auto-duck", icon: "arrow.down.right.and.arrow.up.left", trailing: {
            DuckReadout(audio: audio)
        }) {
            Toggle("Lower game audio while I talk", isOn: Binding(get: { audio.settings.duck.enabled }, set: { audio.settings.duck.enabled = $0 }))
            Group {
                LabeledSlider(label: "Amount", value: Binding(get: { audio.settings.duck.amountDb }, set: { audio.settings.duck.amountDb = $0 }), range: 0...24, step: 1, unit: "dB")
                LabeledSlider(label: "Speech threshold", value: Binding(get: { audio.settings.duck.thresholdDb }, set: { audio.settings.duck.thresholdDb = $0 }), range: -60...(-15), step: 1, unit: "dB")
                LabeledSlider(label: "Attack", value: Binding(get: { audio.settings.duck.attackMs }, set: { audio.settings.duck.attackMs = $0 }), range: 5...300, step: 5, unit: "ms")
                LabeledSlider(label: "Release", value: Binding(get: { audio.settings.duck.releaseMs }, set: { audio.settings.duck.releaseMs = $0 }), range: 50...2000, step: 10, unit: "ms")
            }.disabled(!audio.settings.duck.enabled).opacity(audio.settings.duck.enabled ? 1 : 0.4)
        }
    }
}

struct DuckReadout: View {
    let audio: AudioController
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
            let d = audio.meters().duckDb
            Text(d < -0.5 ? String(format: "%.1f dB", d) : "0 dB").font(Theme.Font.mono(10)).foregroundStyle(d < -0.5 ? Theme.warn : Theme.faint)
        }
    }
}

struct VoicePanel: View {
    let audio: AudioController
    var body: some View {
        let v = audio.settings.voice
        Panel(title: "Voice chain", icon: "waveform", trailing: {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
                let m = audio.meters()
                Pill(text: m.gateOpen > 0.5 ? "GATE OPEN" : "GATE CLOSED", color: m.gateOpen > 0.5 ? Theme.ok : Theme.faint)
            }
        }) {
            Toggle("High-pass 80 Hz", isOn: Binding(get: { v.hpfOn }, set: { audio.settings.voice.hpfOn = $0 }))
            Toggle("Voice clean-up (noise reduction)", isOn: Binding(get: { v.denoiseOn }, set: { audio.settings.voice.denoiseOn = $0 }))
            Group {
                LabeledSlider(label: "Clean-up strength", value: Binding(get: { v.denoiseStrength * 100 }, set: { audio.settings.voice.denoiseStrength = $0 / 100 }), range: 0...100, step: 5, unit: "%")
                TimelineView(.animation(minimumInterval: 1.0 / 5)) { _ in
                    let m = audio.meters()
                    HStack(spacing: 8) {
                        Button(m.micLearning ? "Listening..." : "Learn room noise") { audio.learnMicNoise() }.buttonStyle(.studio(.secondary, height: 24)).disabled(m.micLearning)
                        if m.micProfile { Button("Forget") { audio.clearMicNoise() }.buttonStyle(.studio(.ghost, height: 24)) }
                        Spacer(minLength: 0)
                        Text(m.micProfile ? "Profile learned" : "Adaptive").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                    }
                }
            }.disabled(!v.denoiseOn).opacity(v.denoiseOn ? 1 : 0.4)
            Toggle("Noise gate", isOn: Binding(get: { v.gateOn }, set: { audio.settings.voice.gateOn = $0 }))
            LabeledSlider(label: "Gate threshold", value: Binding(get: { v.gateThresholdDb }, set: { audio.settings.voice.gateThresholdDb = $0 }), range: -70...(-15), step: 1, unit: "dB")
                .disabled(!v.gateOn).opacity(v.gateOn ? 1 : 0.4)
            Toggle("Compressor", isOn: Binding(get: { v.compOn }, set: { audio.settings.voice.compOn = $0 }))
            Group {
                LabeledSlider(label: "Threshold", value: Binding(get: { v.compThresholdDb }, set: { audio.settings.voice.compThresholdDb = $0 }), range: -40...0, step: 1, unit: "dB")
                LabeledSlider(label: "Ratio", value: Binding(get: { v.compRatio }, set: { audio.settings.voice.compRatio = $0 }), range: 1...10, step: 0.5, unit: ": 1", format: "%.1f")
                LabeledSlider(label: "Makeup", value: Binding(get: { v.compMakeupDb }, set: { audio.settings.voice.compMakeupDb = $0 }), range: 0...12, step: 0.5, unit: "dB", format: "%.1f")
            }.disabled(!v.compOn).opacity(v.compOn ? 1 : 0.4)
            Toggle("Limiter (-1 dBFS)", isOn: Binding(get: { v.limiterOn }, set: { audio.settings.voice.limiterOn = $0 }))
        }
    }
}

struct CleanupPanel: View {
    let audio: AudioController
    var body: some View {
        let st = audio.settings
        Panel(title: "Phone audio clean-up", icon: "sparkles") {
            Toggle("Reduce hiss and noise on phone audio", isOn: Binding(get: { st.phoneDenoiseOn }, set: { audio.settings.phoneDenoiseOn = $0 }))
            Group {
                LabeledSlider(label: "Strength", value: Binding(get: { st.phoneDenoiseStrength * 100 }, set: { audio.settings.phoneDenoiseStrength = $0 / 100 }), range: 0...100, step: 5, unit: "%")
                HStack(spacing: 8) {
                    Button("Learn phone noise") { audio.learnPhoneNoise() }.buttonStyle(.studio(.secondary, height: 24))
                    Button("Forget") { audio.clearPhoneNoise() }.buttonStyle(.studio(.ghost, height: 24))
                    Spacer(minLength: 0)
                }
                Text("Learn while the game is silent (menu, pause). Off by default: it can dull music.").font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.disabled(!st.phoneDenoiseOn).opacity(st.phoneDenoiseOn ? 1 : 0.4)
            Toggle("Gentle gate on quiet phone audio", isOn: Binding(get: { st.phoneGateOn }, set: { audio.settings.phoneGateOn = $0 }))
            LabeledSlider(label: "Gate threshold", value: Binding(get: { st.phoneGateThresholdDb }, set: { audio.settings.phoneGateThresholdDb = $0 }), range: -80...(-35), step: 1, unit: "dB")
                .disabled(!st.phoneGateOn).opacity(st.phoneGateOn ? 1 : 0.4)
            Toggle("Master rumble filter (80 Hz)", isOn: Binding(get: { st.masterHpfOn }, set: { audio.settings.masterHpfOn = $0 }))
        }
    }
}

struct HeadphonesPanel: View {
    let audio: AudioController
    var body: some View {
        let m = audio.settings.monitor
        Panel(title: "Headphones", icon: "headphones", trailing: {
            Toggle("", isOn: Binding(get: { m.enabled }, set: { audio.settings.monitor.enabled = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }) {
            Picker("Output", selection: Binding(get: { m.deviceUID ?? "" }, set: { audio.settings.monitor.deviceUID = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(audio.outputDevices) { Text($0.isBuiltInSpeaker ? "\($0.label), speakers" : $0.label).tag($0.uid) }
            }.labelsHidden()
            LabeledSlider(label: "Monitor level", value: Binding(get: { m.levelDb }, set: { audio.settings.monitor.levelDb = $0 }), range: -40...6, step: 1, unit: "dB")
            Toggle("Sidetone (hear my own voice live)", isOn: Binding(get: { m.sidetoneOn }, set: { audio.settings.monitor.sidetoneOn = $0 }))
            LabeledSlider(label: "Sidetone level", value: Binding(get: { m.sidetoneDb }, set: { audio.settings.monitor.sidetoneDb = $0 }), range: -40...6, step: 1, unit: "dB")
                .disabled(!m.sidetoneOn).opacity(m.sidetoneOn ? 1 : 0.4)
            Toggle("Headphones only (never use speakers)", isOn: Binding(get: { m.headphonesOnly }, set: { audio.settings.monitor.headphonesOnly = $0 }))
            Text("Hear the program mix. Solo (S) on a strip sends only that channel to your headphones. Never affects the broadcast.")
                .font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Compact mixer (Studio inspector)

struct CompactMixerPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let audio = model.services.audio { CompactMixerBody(audio: audio) }
        else { EmptyState(icon: "speaker.slash", title: "Audio is not available", message: "Needs the real studio backend.") }
    }
}

struct CompactMixerBody: View {
    @Environment(AppModel.self) var model
    let audio: AudioController
    var body: some View {
        Panel(title: "Mixer", icon: "slider.vertical.3", trailing: {
            Button { NotificationCenter.default.post(name: .studioNavigate, object: StudioPage.audio.rawValue) } label: { Text("Open") }.buttonStyle(.studio(.ghost, height: 22))
        }) {
            AudioAlertsCompact(audio: audio)
            TalkButton(audio: audio, compact: true)
            row(AudioMixer.micID, "Mic", "mic.fill")
            ForEach(model.devices) { d in row("device:\(d.id)", d.name, "iphone.gen3") }
            masterRow
            Divider().overlay(Theme.stroke)
            Toggle("Duck game audio when I talk", isOn: Binding(get: { audio.settings.duck.enabled }, set: { audio.settings.duck.enabled = $0 }))
            Toggle("Headphone monitor", isOn: Binding(get: { audio.settings.monitor.enabled }, set: { audio.settings.monitor.enabled = $0 }))
        }
        .toggleStyle(StudioToggleStyle())
    }
    func row(_ id: String, _ name: String, _ icon: String) -> some View {
        let ch = audio.channel(id)
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 14)
                Text(name).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(dbText(ch.gainDb)).font(Theme.Font.mono(10)).foregroundStyle(Theme.muted)
                SmallToggleButton(title: "M", on: ch.mute, color: Theme.program, help: "Mute \(name)") { audio.update(id) { $0.mute.toggle() } }.frame(width: 24)
            }
            HStack(spacing: 6) {
                Slider(value: Binding(get: { AudioMath.faderPosition(db: audio.channel(id).gainDb) }, set: { p in audio.update(id) { $0.gainDb = AudioMath.faderDb(position: p) } }), in: 0...1)
                    .controlSize(.mini).accessibilityLabel("\(name) level")
                HMeter(audio: audio, id: id)
            }
        }
    }
    var masterRow: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 14)
                Text("Master").font(Theme.Font.caption).foregroundStyle(Theme.text)
                Spacer()
                Text(dbText(audio.settings.masterDb)).font(Theme.Font.mono(10)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 6) {
                Slider(value: Binding(get: { AudioMath.faderPosition(db: audio.settings.masterDb) }, set: { audio.settings.masterDb = AudioMath.faderDb(position: $0) }), in: 0...1)
                    .controlSize(.mini).accessibilityLabel("Master level")
                HMeter(audio: audio, id: nil)
            }
        }
    }
}

struct HMeter: View {
    let audio: AudioController
    let id: String?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
            let m = audio.meters()
            let c = id.map { m.channels[$0] ?? ChannelMeter() } ?? m.master
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                    RoundedRectangle(cornerRadius: 2).fill(c.peak > 0.9 ? Theme.program : c.peak > 0.5 ? Theme.warn : Theme.ok)
                        .frame(width: g.size.width * LevelMeter.pos(c.peak))
                }
            }.frame(width: 60, height: 6)
        }
    }
}

struct AudioAlertsCompact: View {
    let audio: AudioController
    var body: some View {
        if audio.settings.micEnabled, !audio.settings.mic.mute, !audio.micStatus.isRunning {
            Pill(text: audio.micStatus == .denied ? "Mic access blocked" : "Mic not capturing", color: Theme.warn, icon: "exclamationmark.triangle.fill")
        }
        if audio.feedbackWarning != nil { Pill(text: "Feedback risk: use headphones", color: Theme.warn, icon: "exclamationmark.triangle.fill") }
    }
}
