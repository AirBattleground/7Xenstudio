import SwiftUI

// MARK: - Inspector tab "Capture"

/// Studio page -> inspector -> Capture. Operator flow: pick the match (countdown until it unlocks) -> Auto capture on during the lobby
/// -> Start when the game begins -> Stop when it ends -> Send screenshot on the results screen (one per page) -> the manager publishes.
struct AutoCapturePanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let abg = model.abg
        VStack(spacing: Theme.Space.m) {
            if !abg.isConnected {
                CaptureNotice(icon: "link.badge.plus", text: "Connect AirBattleground to send screenshots to a match.",
                              button: "Connect…") { abg.showConnect = true }
            } else if !abg.hasMatch {
                CaptureNotice(icon: "sportscourt", text: "Select the AirBattleground match these screenshots belong to.",
                              button: "Select match") { abg.showMatches = true }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sportscourt.fill").font(.system(size: 10)).foregroundStyle(Theme.ok)
                    Text(abg.selectedTitle ?? "Match").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Change") { abg.showMatches = true }.buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .card(fill: Theme.panel, radius: Theme.Radius.m)
                .help("Screenshots go to this AirBattleground match")
                MatchControlCard()
                CaptureStatusStripView(compact: false)
            }
            AutoCaptureCard(session: model.capture.live)
            SendScreenshotCard(session: model.capture.live)
        }
        .overlay(alignment: .top) { CaptureToastView() }
    }
}

private struct CaptureNotice: View {
    var icon: String, text: String, button: String, action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.warn)
                Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: action) { Text(button).frame(maxWidth: .infinity) }.buttonStyle(.studio(.primary(Theme.accent), height: 28))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Theme.warn.opacity(0.08))
    }
}

// MARK: - Match control (Start / Stop driven only by control.state)

extension MatchControl.State {
    var color: Color {
        switch self { case .locked: Theme.warn; case .ready: Theme.ok; case .live: Theme.program; case .ended: Theme.warn; case .published: Theme.muted }
    }
    var icon: String {
        switch self { case .locked: "lock.fill"; case .ready: "checkmark.circle.fill"; case .live: "dot.radiowaves.left.and.right"; case .ended: "flag.checkered"; case .published: "globe" }
    }
}

/// "Locked · unlocks in 12:31" / "Ready" / … chip, ticking every second.
struct MatchControlChip: View {
    var control: MatchControl
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Pill(text: control.chip(now: ctx.date), color: control.state.color, icon: control.state.icon)
        }
        .accessibilityLabel("Match state")
    }
}

struct MatchControlCard: View {
    @Environment(AppModel.self) var model
    @State private var confirmStop = false
    var body: some View {
        let abg = model.abg
        let c = abg.selectedControl
        let title = abg.selectedTitle ?? "the match"
        Panel(title: "Match control", icon: "flag.checkered", trailing: { if let c { MatchControlChip(control: c) } }) {
            if let c, c.state == .locked {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if let s = c.secondsToUnlock(now: ctx.date), s > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Unlocks in").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                            Text(ABGTime.countdown(s)).font(Theme.Font.mono(20, .bold)).foregroundStyle(Theme.warn)
                        }
                    } else {
                        Text(c.unlocksAt == nil ? "Locked by AirBattleground" : "Unlocking… checking with AirBattleground").font(Theme.Font.caption).foregroundStyle(Theme.warn)
                    }
                }
            }
            if let r = c?.reason {
                Text(r).font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let t = c?.teamsLine { Label(t, systemImage: "person.3.fill").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
            switch abg.controlButton {
            case .start(let enabled):
                Button { Task { await abg.startMatch() } } label: {
                    HStack(spacing: 8) {
                        if abg.controlBusy { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                        Text("START MATCH").tracking(1)
                    }.font(.system(size: 15, weight: .heavy)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.studio(.primary(Theme.ok), height: 46))
                .disabled(!enabled || abg.controlBusy)
                .help(enabled ? "Tell AirBattleground the game has started" : (c?.reason ?? "The match is locked until registration closes"))
                .accessibilityLabel("Start match")
                if c?.state == .ready { AutoStartRow() }
            case .stop:
                Button { confirmStop = true } label: {
                    HStack(spacing: 8) {
                        if abg.controlBusy { ProgressView().controlSize(.small) } else { Image(systemName: "stop.fill") }
                        Text("STOP MATCH").tracking(1)
                    }.font(.system(size: 15, weight: .heavy)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.studio(.primary(Theme.program), height: 46))
                .disabled(abg.controlBusy)
                .help("End the match on AirBattleground; then send the results screenshot(s)")
                .accessibilityLabel("Stop match")
            case .none:
                if c?.state == .published {
                    Label("Published on AirBattleground. Read-only.", systemImage: "lock.doc").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                }
            }
            if abg.awaitingResults && c?.state != .published { ResultsPrompt() }
            if let m = abg.controlMessage {
                Label(m, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.program)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if c == nil {
                Text("This AirBattleground server doesn't report match control; everything stays allowed.").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("End \(title)? You'll send the results screenshot next.", isPresented: $confirmStop) {
            Button("End match", role: .destructive) { Task { await abg.stopMatch() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// After Stop: the prominent "Send the results screenshot(s)" prompt.
private struct ResultsPrompt: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Send the results screenshot(s)", systemImage: "trophy.fill").font(Theme.Font.bodyBold).foregroundStyle(Theme.warn)
            Text("Put the results screen on the feed and send one screenshot per page. The manager publishes on AirBattleground.")
                .font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            SendScreenshotButton(session: model.capture.live, height: 36)
            ManualOutcomeLine(session: model.capture.live)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warn.opacity(0.6)))
    }
}

// MARK: - Status strip

extension CaptureStatusStrip.Tone {
    var color: Color {
        switch self { case .neutral: Theme.muted; case .ok: Theme.ok; case .live: Theme.program; case .warn: Theme.warn; case .error: Theme.program }
    }
}

/// Match state, last screenshot (time-ago + detected type), last error (red), "Paused by manager". Full on the Capture tab, compact on the
/// program monitor.
struct CaptureStatusStripView: View {
    @Environment(AppModel.self) var model
    var compact: Bool
    var body: some View {
        let abg = model.abg, s = model.capture.live
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let strip = CaptureStatusStrip.make(control: abg.selectedControl, auto: abg.liveAutoCapture, localLastAt: s.lastSentAt,
                                                localDetected: s.lastDetected, now: ctx.date)
            if compact { compactView(strip) } else { fullView(strip) }
        }
    }
    @ViewBuilder func fullView(_ st: CaptureStatusStrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(color: st.stateTone.color, pulse: st.stateTone == .live)
                Text(st.state).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if st.pausedByManager { Pill(text: "Paused by manager", color: Theme.warn, icon: "pause.fill") }
            }
            Text(st.lastShot ?? "No screenshot yet").font(Theme.Font.caption).foregroundStyle(Theme.muted)
            if let e = st.error {
                Text(e).font(Theme.Font.caption).foregroundStyle(Theme.program).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Theme.panel, radius: Theme.Radius.m)
        .accessibilityElement(children: .combine).accessibilityLabel("Match status")
    }
    @ViewBuilder func compactView(_ st: CaptureStatusStrip) -> some View {
        let toast = model.capture.toast
        HStack(spacing: 5) {
            StatusDot(color: st.stateTone.color, pulse: st.stateTone == .live)
            Text(st.state.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.6).lineLimit(1)
            if let t = toast {
                Text("· \(t.text)").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(t.tone == .error ? Theme.program : t.tone == .warn ? Theme.warn : Theme.ok)
            } else if let l = st.lastShot {
                Text("· " + l.replacingOccurrences(of: "Last screenshot ", with: "")).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if st.pausedByManager { Text("· PAUSED BY MANAGER").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Theme.warn) }
            if st.error != nil { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.program) }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8).frame(height: 22)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help([st.state, st.lastShot, st.error.map { "Error: \($0)" }, st.pausedByManager ? "Paused by manager" : nil].compactMap { $0 }.joined(separator: "\n"))
    }
}

// MARK: - Auto capture (one toggle for the whole match)

private struct AutoCaptureCard: View {
    @Environment(AppModel.self) var model
    @Bindable var session: AutoCaptureSession
    var body: some View {
        let ready = model.abg.isConnected && model.abg.hasMatch && model.abg.selectedControl?.state != .published
        Panel(title: "Auto capture", icon: "camera.viewfinder", trailing: {
            HStack(spacing: 6) {
                CaptureStateDot(session: session)
                Toggle("Auto capture", isOn: Binding(get: { model.capture.autoOn }, set: { model.capture.setAuto($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(!ready && !model.capture.autoOn)
                    .accessibilityLabel("Auto capture")
            }
        }) {
            if model.capture.armed {
                Label("Armed — starts capturing when the match starts", systemImage: "clock.badge.checkmark")
                    .font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.warn)
            }
            Toggle(isOn: Binding(get: { model.capture.startWithMatch }, set: { model.capture.startWithMatch = $0 })) {
                Text("Start when the match starts, stop when it ends").font(Theme.Font.caption)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("On: switching Auto capture on before the match waits until AirBattleground reports the match live, then captures until the match ends. Off: captures as soon as you switch it on.")
            CaptureSourcePicker(session: session)
            if let w = session.overlayWarning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CaptureIntervalPicker(session: session)
            Text("Lobby, in-game and results all go to the match; AirBattleground tells them apart.").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            CaptureStatus(session: session)
            HStack(alignment: .center, spacing: 10) {
                CaptureThumb(image: session.thumbnail)
                if let n = session.lastSize { Text("Last: \(formatBytes(Int64(n))) JPEG").font(Theme.Font.mono(9.5)).foregroundStyle(Theme.faint) }
            }
        }
    }
}

// MARK: - Send screenshot (manual, with the detection result)

private struct SendScreenshotCard: View {
    @Environment(AppModel.self) var model
    @Bindable var session: AutoCaptureSession
    var body: some View {
        Panel(title: "Send screenshot", icon: "camera.fill") {
            HStack(spacing: 8) {
                Text("Shows").font(Theme.Font.caption).foregroundStyle(Theme.muted).frame(width: 40, alignment: .leading)
                Picker("Hint", selection: Binding(get: { session.hint?.rawValue ?? "" }, set: { session.hint = CaptureHint(rawValue: $0) })) {
                    Text("None").tag("")
                    ForEach(CaptureHint.allCases) { h in Text(h.title).tag(h.rawValue) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(maxWidth: .infinity)
                .help("Optional: what the screen shows (a training label; AirBattleground still reads the picture itself)")
                .accessibilityLabel("Screenshot hint")
            }
            SendScreenshotButton(session: session, height: 36)
            ManualOutcomeLine(session: session)
        }
    }
}

struct SendScreenshotButton: View {
    @Environment(AppModel.self) var model
    var session: AutoCaptureSession
    var height: CGFloat
    var body: some View {
        let ready = model.abg.isConnected && model.abg.hasMatch && model.abg.selectedControl?.state != .published
        let busy = session.manualPending || (session.inFlight && !session.running) || session.manualOutcome?.text == "Sending…"
        Button { model.capture.sendScreenshot() } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: "camera.fill") }
                Text("Send screenshot")
            }.font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.studio(.primary(Theme.accent), height: height)).disabled(!ready || busy)
        .help("Grab the current picture once and send it to the match (one per results page)")
        .accessibilityLabel("Send screenshot")
    }
}

/// "Lobby ✓ 14 teams" / "Not a game screen. Check the scene" / red failure, for the last manual screenshot.
struct ManualOutcomeLine: View {
    var session: AutoCaptureSession
    var body: some View {
        if let o = session.manualOutcome {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    switch o.tone {
                    case .progress: ProgressView().controlSize(.mini)
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.program)
                    }
                    Text(o.text).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(o.tone.color).fixedSize(horizontal: false, vertical: true)
                }
                if let d = o.detail { Text(d).font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("Screenshot result")
        }
    }
}

extension CaptureOutcome.Tone {
    var color: Color { switch self { case .progress: Theme.muted; case .ok: Theme.ok; case .warn: Theme.warn; case .error: Theme.program } }
}

/// Toast for a manual screenshot's result (5 s).
private struct CaptureToastView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let t = model.capture.toast {
            HStack(spacing: 8) {
                Image(systemName: t.tone == .ok ? "checkmark.circle.fill" : t.tone == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(t.tone.color)
                Text(t.text).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 0)
                Button { model.capture.dismissToast() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            .padding(10)
            .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.tone.color.opacity(0.7)))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(model.capture.toastSerial)
            .accessibilityElement(children: .combine).accessibilityLabel("Screenshot result")
        }
    }
}

// MARK: - pickers / status

/// Clean phone feeds first (recommended, the default), then scenes.
private struct CaptureSourcePicker: View {
    @Environment(AppModel.self) var model
    @Bindable var session: AutoCaptureSession
    var body: some View {
        HStack(spacing: 8) {
            Text("Source").font(Theme.Font.caption).foregroundStyle(Theme.muted).frame(width: 40, alignment: .leading)
            let feeds = model.devices.map { CaptureFeed(ref: .device(id: $0.id), name: $0.name, online: $0.online && $0.videoReady) }
            Picker("Source", selection: Binding(get: { session.resolvedSource?.tag ?? "" }, set: { session.source = CaptureSource(tag: $0) })) {
                let mine = model.scenes, mineIds = Set(mine.map(\.id))
                let others = model.allScenes.filter { !mineIds.contains($0.id) }
                if feeds.isEmpty && model.allScenes.isEmpty { Text("Nothing to capture").tag("") }
                if !feeds.isEmpty {
                    Section("Clean feeds") {
                        ForEach(feeds, id: \.self) { f in Text(f.label + (f.online ? "" : "  (no video)")).tag(CaptureSource.feed(f.ref).tag) }
                    }
                }
                Section(model.activePreset?.name ?? "Scenes") {
                    ForEach(mine) { s in Text(s.id == model.programID ? "\(s.name)  (on Program)" : s.name).tag(CaptureSource.scene(s.id).tag) }
                }
                if !others.isEmpty {
                    Section("Other scenes") {
                        ForEach(others) { s in Text(s.id == model.programID ? "\(s.name)  (on Program)" : s.name).tag(CaptureSource.scene(s.id).tag) }
                    }
                }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: .infinity)
            .accessibilityLabel("What to capture")
            .help("Capture the clean game feed: the reader must not read the studio's own graphics")
        }
    }
}

private struct CaptureIntervalPicker: View {
    @Bindable var session: AutoCaptureSession
    var body: some View {
        HStack(spacing: 8) {
            Text("Every").font(Theme.Font.caption).foregroundStyle(Theme.muted).frame(width: 40, alignment: .leading)
            Picker("Interval", selection: $session.interval) {
                ForEach(AutoCaptureSession.intervals, id: \.self) { s in Text("\(Int(s))s").tag(s) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(maxWidth: .infinity)
            .accessibilityLabel("Capture interval in seconds")
            .help("AirBattleground may ask for another pace (nextIntervalSeconds); the studio follows it")
        }
    }
}

private struct CaptureStateDot: View {
    var session: AutoCaptureSession
    var body: some View {
        if session.running {
            HStack(spacing: 4) {
                StatusDot(color: session.paused || session.message != nil ? Theme.warn : Theme.ok, pulse: true)
                Text(session.paused ? "PAUSED" : "ON").font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(session.paused || session.message != nil ? Theme.warn : Theme.ok)
            }
        }
    }
}

private struct CaptureStatus: View {
    @Environment(AppModel.self) var model
    var session: AutoCaptureSession
    var body: some View {
        let color: Color = session.paused ? Theme.warn : session.isError ? Theme.program : session.running ? Theme.text : Theme.muted
        VStack(alignment: .leading, spacing: 6) {
            Text(session.statusLine).font(Theme.Font.caption).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Capture status").accessibilityValue(session.statusLine)
            switch session.fix {
            case .connect?: Button("Connect…") { model.abg.showConnect = true }.buttonStyle(.studio(.secondary, height: 24))
            case .selectMatch?: Button("Select match") { model.abg.showMatches = true }.buttonStyle(.studio(.secondary, height: 24))
            case nil: EmptyView()
            }
        }
    }
}

private struct CaptureThumb: View {
    var image: CGImage?
    var width: CGFloat = 96
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.well)
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Theme.faint) }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityLabel(image == nil ? "No capture yet" : "Last captured picture")
    }
}

// MARK: - Program monitor badge

/// On the program monitor: the compact match status strip (state, last screenshot, errors) and a pulsing "AUTO CAPTURE" pill while capturing.
/// Click opens the Capture tab.
struct AutoCaptureBadge: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let c = model.capture, s = c.live
        HStack(spacing: 8) {
            if model.abg.isConnected && model.abg.hasMatch {
                Button { c.focusRequest += 1 } label: { CaptureStatusStripView(compact: true) }.buttonStyle(.plain)
            }
            if c.anyRunning {
                let problem = s.message != nil
                Button { c.focusRequest += 1 } label: {
                    HStack(spacing: 5) {
                        StatusDot(color: problem ? Theme.warn : Theme.program, pulse: true)
                        Text("AUTO CAPTURE").font(.system(size: 10, weight: .heavy)).tracking(0.8)
                        Text("· \(AutoCaptureSession.secs(s.effectiveInterval))").font(Theme.Font.mono(10, .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder((problem ? Theme.warn : Theme.program).opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(problem ? "Auto capture has a problem: \(s.message ?? "")" : "Auto capture is sending screenshots to AirBattleground. Click for details.")
                .accessibilityLabel("Auto capture running")
            }
        }
    }
}

/// "Auto-start 72 s after the start time": on/off + the time left.
struct AutoStartRow: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.autoStartMatch }, set: { model.setAutoStartMatch($0) })) {
                Text("Auto-start \(Int(JourneyStage.autoStartDelay)) s after start time").font(Theme.Font.caption)
            }
            .toggleStyle(.switch).controlSize(.mini)
            Spacer()
            if let due = model.autoStartAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = Int(ceil(due.timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "in \(ABGTime.countdown(left))" : "starting…")
                        .font(Theme.Font.mono(12, .bold)).foregroundStyle(Theme.warn)
                }
            }
        }
        .help("If the match hasn't been started \(Int(JourneyStage.autoStartDelay)) seconds after its start time, the studio presses Start once by itself.")
    }
}
