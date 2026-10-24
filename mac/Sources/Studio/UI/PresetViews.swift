// Studio presets (switcher, manage, choose scenes), the Match journey bar, the Match data chip and the auto-switch toast.
import SwiftUI
import AppKit

// MARK: - Preset switcher

struct PresetSwitcher: View {
    @Environment(AppModel.self) var model
    enum NameMode: Identifiable { case new, duplicate, rename; var id: Self { self } }
    @State private var nameMode: NameMode?
    @State private var nameText = ""
    @State private var confirmDelete = false
    @State private var chooseScenes = false

    var body: some View {
        let active = model.activePreset
        label(active)
            // macOS flattens custom Menu labels: draw our own and lay an invisible menu on top
            .overlay { Menu { items(active) } label: { Color.clear }.menuStyle(.borderlessButton).menuIndicator(.hidden).opacity(0.011) }
            .help("The active preset is what you stream with: its scenes fill the strip, ⌘1-9 and the match journey.")
            .accessibilityLabel("Active preset, \(active?.name ?? "none")")
            .alert(nameMode == .rename ? "Rename preset" : nameMode == .duplicate ? "Duplicate preset" : "New preset", isPresented: Binding(get: { nameMode != nil }, set: { if !$0 { nameMode = nil } })) {
                TextField("Preset name", text: $nameText)
                Button(nameMode == .rename ? "Rename" : "Create") {
                    switch nameMode {
                    case .new: model.createPreset(name: nameText, duplicateActive: false)
                    case .duplicate: model.createPreset(name: nameText, duplicateActive: true)
                    case .rename: if let id = active?.id { model.renamePreset(id, to: nameText) }
                    case nil: break
                    }
                    nameMode = nil
                }
                Button("Cancel", role: .cancel) { nameMode = nil }
            } message: {
                Text(nameMode == .new ? "An empty preset. Add scenes with “Choose scenes”, or create new scenes while it is active."
                     : nameMode == .duplicate ? "A copy of the scenes, order, journey and overlays of “\(active?.name ?? "")”." : "")
            }
            .alert("Delete “\(active?.name ?? "")”?", isPresented: $confirmDelete) {
                Button("Delete preset", role: .destructive) { if let id = active?.id { model.deletePreset(id) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Only the preset is deleted. Its scenes stay in the studio (Scenes page).") }
            .sheet(isPresented: $chooseScenes) { if let id = active?.id { PresetScenesSheet(presetId: id).environment(model) } }
    }

    @ViewBuilder private func items(_ active: StudioPreset?) -> some View {
        Section("Stream with") {
            ForEach(model.presetBook.presets) { p in
                Button { model.setActivePreset(p.id) } label: {
                    if p.id == active?.id { Label("\(p.name)  (\(p.sceneIds.count))", systemImage: "checkmark") } else { Text("\(p.name)  (\(p.sceneIds.count))") }
                }
            }
        }
        Divider()
        Button("New empty preset…") { nameText = "New preset"; nameMode = .new }
        if let a = active {
            Button("Duplicate “\(a.name)”…") { nameText = a.name + " copy"; nameMode = .duplicate }
            Button("Rename “\(a.name)”…") { nameText = a.name; nameMode = .rename }
            Button("Choose scenes in “\(a.name)”…") { chooseScenes = true }
            Menu("Default overlays") {
                Button("Use the current overlays for this preset") { model.saveOverlaysToActivePreset() }
                Button("Don't change overlays when switching") { model.clearActivePresetOverlays() }.disabled(a.overlays == nil)
            }
            if a.builtin == StudioPreset.builtinAdvanced {
                Button("Reinstall built-in scenes") { model.reinstallAdvancedScenes() }
            }
            Divider()
            Button("Delete “\(a.name)”…", role: .destructive) { confirmDelete = true }.disabled(model.presetBook.presets.count <= 1)
        }
    }

    private func label(_ active: StudioPreset?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("PRESET").font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(Theme.faint)
                Text(active?.name ?? "No preset").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
        .contentShape(Rectangle())
        .fixedSize()
    }
}

/// Choose which scenes are in a preset, and their order.
struct PresetScenesSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let presetId: String
    var body: some View {
        let preset = model.presetBook.preset(presetId)
        let members = model.presetBook.scenes(model.allScenes, presetId: presetId)
        let memberIds = Set(members.map(\.id))
        let others = model.allScenes.filter { !memberIds.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scenes in “\(preset?.name ?? "")”").font(Theme.Font.title)
                    Text("A scene can be in several presets. Order = Studio strip order and hotkeys 1-9.").font(Theme.Font.body).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.studio(.primary(Theme.accent), height: 28)).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(text: "In this preset (\(members.count))")
                    if members.isEmpty { Text("No scenes yet. Add some below.").font(Theme.Font.caption).foregroundStyle(Theme.faint).padding(.vertical, 6) }
                    ForEach(Array(members.enumerated()), id: \.element.id) { i, s in
                        row(s, index: i) {
                            IconButton(systemName: "chevron.up", label: "Move up", size: 24) { model.moveScene(s.id, inPreset: presetId, to: i - 1) }.disabled(i == 0)
                            IconButton(systemName: "chevron.down", label: "Move down", size: 24) { model.moveScene(s.id, inPreset: presetId, to: i + 1) }.disabled(i == members.count - 1)
                            Button { model.setScene(s.id, inPreset: presetId, false) } label: { Label("Remove", systemImage: "minus.circle") }
                                .buttonStyle(.studio(.secondary, height: 24))
                        }
                    }
                    if !others.isEmpty {
                        SectionHeader(text: "Other scenes in the studio").padding(.top, 10)
                        ForEach(others) { s in
                            row(s, index: nil) {
                                Button { model.setScene(s.id, inPreset: presetId, true) } label: { Label("Add", systemImage: "plus.circle") }
                                    .buttonStyle(.studio(.secondary, height: 24))
                            }
                        }
                    }
                }.padding(2)
            }
        }
        .padding(22).frame(width: 600, height: 560).background(Theme.panel)
    }
    private func row<Trailing: View>(_ s: Scene, index: Int?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(index.map { "\($0 + 1)" } ?? "").font(Theme.Font.mono(11, .bold)).foregroundStyle(Theme.faint).frame(width: 20)
            LayerSceneThumb(scene: s).frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(Theme.Font.bodyBold).foregroundStyle(Theme.text).lineLimit(1)
                let others = model.presetBook.presets(containing: s.id).filter { $0.id != presetId }.map(\.name)
                if !others.isEmpty { Text("Also in " + others.joined(separator: ", ")).font(Theme.Font.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer()
            trailing()
        }
        .padding(8).background(Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
    }
}

// MARK: - Match journey

struct JourneyBar: View {
    @Environment(AppModel.self) var model
    static let height: CGFloat = 66
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(JourneyStage.allCases.enumerated()), id: \.element) { i, stage in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint) }
                StageCard(stage: stage, number: i + 1)
            }
        }
        .padding(5)
        .frame(height: Self.height)
        .card(fill: Theme.panel.opacity(0.7), radius: Theme.Radius.m)
    }
}

/// "Auto-follow match" switch + AUTO badge + what the match is doing (Studio page header).
struct AutoFollowControl: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 7) {
            Toggle(isOn: Binding(get: { model.journey.enabled }, set: { model.setAutoFollow($0) })) {
                Text("Auto-follow match").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text).fixedSize()
            }
            .toggleStyle(.switch).controlSize(.mini)
            if model.journey.enabled {
                Pill(text: model.journey.paused ? "AUTO PAUSED" : "AUTO", color: model.journey.paused ? Theme.warn : Theme.accent, filled: !model.journey.paused)
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.panelHi.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(model.journey.enabled ? Theme.accent.opacity(0.6) : Theme.stroke))
        .help(model.journey.paused ? "Paused after a manual take: resumes at the next match state change."
              : "Takes the journey stage's scene to Program when the AirBattleground match state changes (after a 3 s toast you can cancel).")
    }
}

struct StageCard: View {
    @Environment(AppModel.self) var model
    let stage: JourneyStage
    let number: Int
    @State private var hover = false
    var body: some View {
        let scene = model.scene(for: stage)
        let onAir = scene != nil && scene?.id == model.programID
        let next = scene != nil && scene?.id == model.previewID && !onAir
        let isMatch = model.matchStage == stage
        let tally: Color? = onAir ? Theme.program : next ? Theme.preview : nil
        HStack(spacing: 7) {
            ZStack {
                if let scene { SceneThumbnail(scene: scene, live: onAir ? .program : next ? .preview : nil) }
                else { Rectangle().fill(Theme.well).overlay(Image(systemName: "plus").foregroundStyle(Theme.faint)) }
            }
            .frame(width: 86, height: 48).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if onAir { tag("PGM", Theme.program) } else if next { tag("PVW", Theme.preview) }
            }
            .overlay(alignment: .topLeading) {
                if model.autoTakenStage == stage && onAir { tag("AUTO", Theme.accent) }
            }
            .overlay {
                if hover, scene != nil, !onAir {
                    Button { model.takeStage(stage) } label: {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Theme.program, in: Circle())
                    }.buttonStyle(.plain).help("TAKE: put \(stage.title) on Program now")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text("\(number)").font(Theme.Font.mono(9, .bold)).foregroundStyle(Theme.faint)
                    Text(stage.title.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.4)
                        .foregroundStyle(onAir ? Theme.program : isMatch ? Theme.accent : Theme.muted).lineLimit(1).minimumScaleFactor(0.75)
                }
                HStack(spacing: 2) {
                    Text(scene?.name ?? "Pick a scene").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(scene == nil ? Theme.faint : Theme.text).lineLimit(1)
                    StageMappingMenu(stage: stage)
                }
                if isMatch {
                    Text("● MATCH IS HERE").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hover ? Theme.panelHi : Theme.panelHi.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(tally ?? (isMatch ? Theme.accent.opacity(0.7) : hover ? Theme.strokeStrong : Theme.stroke), lineWidth: tally != nil || isMatch ? 2 : 1))
        .shadow(color: (tally ?? .clear).opacity(0.35), radius: 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) { model.takeStage(stage) } else { model.previewStage(stage) }
        }
        .contextMenu {
            Button("Preview") { model.previewStage(stage) }.disabled(scene == nil)
            Button("Take to Program") { model.takeStage(stage) }.disabled(scene == nil || onAir)
            Divider()
            StageMappingItems(stage: stage)
        }
        .help(scene == nil ? "Choose the scene for \(stage.title) (▾)" : "Click: preview \(scene!.name). Shift-click or ▶: take to Program. ▾: change the scene.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title): \(scene?.name ?? "no scene")\(onAir ? ", on air" : "")")
        .accessibilityAddTraits(.isButton)
    }
    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 4).frame(height: 13)
            .background(c, in: RoundedRectangle(cornerRadius: 3)).padding(2)
    }
}

struct StageMappingMenu: View {
    let stage: JourneyStage
    var body: some View {
        Image(systemName: "chevron.down.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
            .frame(width: 16, height: 16).contentShape(Rectangle())
            .overlay { Menu { StageMappingItems(stage: stage) } label: { Color.clear }.menuStyle(.borderlessButton).menuIndicator(.hidden).opacity(0.011) }
            .help("Choose the scene for \(stage.title)")
    }
}

struct StageMappingItems: View {
    @Environment(AppModel.self) var model
    let stage: JourneyStage
    var body: some View {
        let current = model.sceneId(for: stage)
        Button("Use current Preview scene\(model.preview.map { " (\($0.name))" } ?? "")") { model.mapStage(stage, to: model.previewID) }
            .disabled(model.previewID == nil)
        Divider()
        Section("\(stage.title) scene") {
            ForEach(model.scenes) { s in
                Button { model.mapStage(stage, to: s.id) } label: {
                    if s.id == current { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
        }
        let mine = Set(model.scenes.map(\.id))
        let others = model.allScenes.filter { !mine.contains($0.id) }
        if !others.isEmpty {
            Menu("Other scenes (adds to the preset)") {
                ForEach(others) { s in Button(s.name) { model.mapStage(stage, to: s.id) } }
            }
        }
        if current != nil {
            Divider()
            Button("No scene for this stage") { model.mapStage(stage, to: nil) }
        }
    }
}

// MARK: - Match data

struct MatchDataChip: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let st = model.matchStatus
        HStack(spacing: 8) {
            StatusDot(color: color(st.connection), pulse: st.connection == .connecting || st.connection == .simulated)
            VStack(alignment: .leading, spacing: 0) {
                Text("MATCH DATA").font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(Theme.faint)
                HStack(spacing: 5) {
                    Text(title(st)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ago(st, ctx.date)).font(Theme.Font.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
            Text(st.simulated == nil ? "Simulate" : "SIM").font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(st.simulated == nil ? Theme.muted : Theme.warn)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
                .overlay { Menu { simulateItems(st) } label: { Color.clear }.menuStyle(.borderlessButton).menuIndicator(.hidden).opacity(0.011) }
                .help("Dev: pretend the match is scheduled / live / summary / finished with sample values")
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.panelHi.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(st.simulated != nil ? Theme.warn.opacity(0.6) : Theme.stroke))
        .help(st.lastError.map { "Last error: \($0) (showing the last good data)" } ?? "GET /api/studio-link/matches/{match}/live every 3 s")
    }
    @ViewBuilder func simulateItems(_ st: MatchDataStore.Status) -> some View {
        Section("Simulate (rehearse without the server)") {
            Button { MatchDataStore.shared.simulate(nil); model.refresh() } label: {
                if st.simulated == nil { Label("Off - use server data", systemImage: "checkmark") } else { Text("Off - use server data") }
            }
            ForEach(MatchDataStore.simulatedStates, id: \.self) { s in
                Button { MatchDataStore.shared.simulate(s); model.refresh() } label: {
                    let t = "\(s) → \(JourneyStage.forMatchState(s)?.title ?? s)"
                    if st.simulated == s { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
            }
        }
    }
    func color(_ c: MatchDataStore.Connection) -> Color {
        switch c { case .ok: Theme.ok; case .error: Theme.warn; case .connecting: Theme.accent; case .simulated: Theme.warn; case .off: Theme.faint }
    }
    func title(_ st: MatchDataStore.Status) -> String {
        let state = st.state.map { s in JourneyStage.forMatchState(s)?.title ?? s }
        switch st.connection {
        case .off: return model.abg.isConnected ? "Pick a match" : "Not connected"
        case .simulated: return "Simulated · \(state ?? "")"
        case .connecting: return "Connecting…"
        case .error: return state.map { "\($0) · error" } ?? "Error"
        case .ok: return state ?? "No state yet"
        }
    }
    func ago(_ st: MatchDataStore.Status, _ now: Date) -> String {
        guard st.connection != .simulated, let t = st.lastOK else { return "" }
        let s = max(0, Int(now.timeIntervalSince(t)))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}

// MARK: - Auto switch toast

struct AutoSwitchToast: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let p = model.autoSwitch {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let left = max(0, p.deadline.timeIntervalSince(ctx.date))
                HStack(spacing: 10) {
                    Pill(text: "AUTO", color: Theme.accent, filled: true)
                    Text("Switching to \(p.stage.title)…").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(model.allScenes.first { $0.id == p.sceneId }?.name ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Text(String(format: "%.0f", left.rounded(.up))).font(Theme.Font.mono(13, .bold)).foregroundStyle(Theme.warn).frame(width: 14)
                    Button("Cancel") { model.cancelAutoSwitch() }.buttonStyle(.studio(.secondary, height: 26)).keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.82), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
                .overlay(alignment: .bottom) {
                    GeometryReader { g in
                        Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(left / PendingAutoSwitch.delay), height: 2)
                    }.frame(height: 2).padding(.horizontal, 18)
                }
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
