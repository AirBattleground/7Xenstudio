import SwiftUI
import AppKit

// MARK: - Pages

enum StudioPage: String, CaseIterable, Identifiable {
    case studio = "Studio", scenes = "Scenes", phones = "Phones", props = "Props", audio = "Audio", recordings = "Recordings", outputs = "Outputs", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .studio: "rectangle.split.3x1.fill"; case .scenes: "square.3.layers.3d"; case .phones: "iphone.gen3"; case .props: "photo.on.rectangle.angled"; case .audio: "slider.vertical.3"
        case .recordings: "film.stack"; case .outputs: "dot.radiowaves.left.and.right"; case .settings: "gearshape"
        }
    }
}

struct PageScaffold<Content: View>: View {
    var title: String; var subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.title).foregroundStyle(Theme.text)
                    Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.muted)
                }
                content
            }
            .padding(Theme.Space.xl).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Studio page

struct ConsoleView: View {
    @Environment(AppModel.self) var model
    @State private var inspectorOverride: Bool?
    @State private var inspectorTab: InspectorTab = InspectorTab(rawValue: ProcessInfo.processInfo.environment["STUDIO_INSPECTOR_TAB"] ?? "") ?? .sources
    var body: some View {
        GeometryReader { g in
            let open = inspectorOverride ?? (g.size.width >= 1200)
            let inspW: CGFloat = open ? 264 : 0
            HStack(spacing: 0) {
                GeometryReader { c in
                    let pad: CGFloat = 14, gap: CGFloat = 10
                    let fixedH = 34 + 46 + JourneyBar.height + 164 + 4 * gap + 2 * pad
                    let maxH = max(180, c.size.height - fixedH)
                    let playerW = max(320, min(c.size.width - 2 * pad, maxH * 16 / 9))
                    VStack(spacing: gap) {
                        StudioPresetHeader()
                        ProgramPlayer(width: playerW).frame(maxWidth: .infinity)
                        TransitionBar(inspectorOpen: Binding(get: { open }, set: { inspectorOverride = $0 }))
                        JourneyBar()
                        Spacer(minLength: 0)
                        ScenesBar()
                    }
                    .padding(pad)
                    .overlay(alignment: .top) { AutoSwitchToast().padding(.top, pad + 34 + gap + 12).animation(.easeOut(duration: 0.2), value: model.autoSwitch) }
                }
                if open {
                    Divider().overlay(Theme.stroke)
                    InspectorView(tab: $inspectorTab).frame(width: inspW).transition(.move(edge: .trailing))
                }
            }
        }
        .onChange(of: model.capture.focusRequest) { _, _ in withAnimation(.easeOut(duration: 0.2)) { inspectorOverride = true; inspectorTab = .capture } }
    }
}

/// Top of the Studio page: the active preset (what you stream with) and the shared match data feed.
struct StudioPresetHeader: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 10) {
            PresetSwitcher()
            Text("\(model.scenes.count) scene\(model.scenes.count == 1 ? "" : "s")").font(Theme.Font.caption).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            AutoFollowControl()
            MatchDataChip()
        }
        .frame(height: 34)
    }
}

struct TransitionControls: View {
    @Environment(AppModel.self) var model
    var canTake: Bool { model.previewID != nil && model.previewID != model.programID }
    var body: some View {
        @Bindable var m = model
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            SectionHeader(text: "Transition")
            Button { model.take() } label: {
                VStack(spacing: 2) {
                    Text("TAKE").font(.system(size: 24, weight: .heavy)).tracking(2)
                    Text("SPACE").font(Theme.Font.mono(9, .bold)).opacity(0.7)
                }.frame(maxWidth: .infinity, minHeight: 74)
            }
            .buttonStyle(.studio(.primary(Theme.program), height: 74))
            .disabled(!canTake)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel("Take preview to program")
            HStack(spacing: 6) {
                modeButton("CUT", .cut)
                modeButton("AUTO", .fade)
            }
            VStack(spacing: 4) {
                HStack {
                    Text("Duration").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(String(format: "%.1fs", Double(model.transitionMs) / 1000)).font(Theme.Font.mono(11)).foregroundStyle(Theme.text)
                }
                Slider(value: Binding(get: { Double(m.transitionMs) }, set: { m.transitionMs = Int($0 / 100) * 100 }), in: 100...2000)
                    .controlSize(.small).disabled(model.transition == .cut)
                    .accessibilityLabel("Fade duration")
            }.opacity(model.transition == .cut ? 0.4 : 1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .card(fill: Theme.panel.opacity(0.6))
    }
    func modeButton(_ title: String, _ kind: TransitionKind) -> some View {
        let sel = model.transition == kind
        return Button { model.transition = kind; if canTake { model.take() } } label: {
            Text(title).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity).padding(.horizontal, -8)
        }
        .buttonStyle(.studio(sel ? .primary(Theme.accent) : .secondary, height: 34))
        .disabled(false)
        .help(kind == .cut ? "Cut to preview instantly" : "Fade to preview")
    }
}

// MARK: - Inspector

enum InspectorTab: String, CaseIterable { case sources = "Sources", triggers = "Triggers", overlays = "Overlays", audio = "Audio", outputs = "Outputs", capture = "Capture" }
extension InspectorTab {
    var icon: String {
        switch self {
        case .sources: "video"; case .triggers: "bolt"; case .overlays: "square.on.square"; case .audio: "slider.vertical.3"
        case .outputs: "dot.radiowaves.left.and.right"; case .capture: "camera.viewfinder"
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) var model
    @Binding var tab: InspectorTab
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases, id: \.self) { t in
                    Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                        Image(systemName: t.icon).font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(tab == t ? Theme.text : Theme.muted)
                            .background(tab == t ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }.buttonStyle(.plain).help(t.rawValue).accessibilityLabel(t.rawValue).accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(3).background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding([.horizontal, .top], Theme.Space.m)
            HStack { SectionHeader(text: tab.rawValue); Spacer() }.padding(.horizontal, Theme.Space.m + 2).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    switch tab {
                    case .sources: PhonesPanel(); LocalSourcesPanel()
                    case .triggers: TriggersPanel()
                    case .overlays: OverlaysPanel()
                    case .audio: CompactMixerPanel()
                    case .outputs: OutputsPanel()
                    case .capture: AutoCapturePanel()
                    }
                }.padding([.horizontal, .bottom], Theme.Space.m)
            }
        }
        .background(.ultraThinMaterial.opacity(0.5))
        .background(Theme.bg)
    }
}

struct LocalSourcesPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Panel(title: "This Mac", icon: "desktopcomputer") {
            row("web.camera", "Webcam", "Camera input")
            row("text.below.photo", "Slate", model.introPropId == nil ? model.slateText : "Intro video")
            row("photo.on.rectangle", "Props", "\(model.props.count) item\(model.props.count == 1 ? "" : "s")")
        }
    }
    func row(_ icon: String, _ name: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.muted)
            Text(name).font(Theme.Font.bodyBold).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}

// MARK: - Status bar

@MainActor @Observable
final class CPUSampler {
    var percent = 0.0
    @ObservationIgnored private var lastCPU: Double = 0
    @ObservationIgnored private var lastWall = Date()
    func sample() {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        let now = Date(); let dt = now.timeIntervalSince(lastWall)
        if dt > 0.2, lastCPU > 0 { percent = (cpu - lastCPU) / dt * 100 }
        lastCPU = cpu; lastWall = now
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) var model
    @State private var cpu = CPUSampler()
    var body: some View {
        let s = model.stats
        HStack(spacing: 0) {
            stat("FPS", s.live ? String(format: "%.1f", s.fps) : "--", s.live && s.fps < 51 ? Theme.warn : Theme.text)
            stat("BITRATE", s.live ? String(format: "%.1f Mbps", s.kbps / 1000) : "--")
            stat("DROPPED", "\(s.dropped)", s.dropped > 0 ? Theme.warn : Theme.text)
            stat("CPU", String(format: "%.0f%%", cpu.percent), cpu.percent > 400 ? Theme.warn : Theme.text)
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(Theme.ok)
                Text(s.encoder).font(Theme.Font.mono(10.5)).foregroundStyle(Theme.text)
            }.padding(.horizontal, 12)
            Spacer(minLength: 8)
            diskStat
            divider
            HStack(spacing: 6) {
                if s.live {
                    if s.outputs.isEmpty && s.recordingFile == nil { Text("Live: no destinations").foregroundStyle(Theme.warn) }
                    ForEach(s.outputs) { o in HStack(spacing: 4) { StatusDot(color: o.ok ? Theme.ok : Theme.program); Text(o.name) } }
                    if s.recordingFile != nil { HStack(spacing: 4) { StatusDot(color: Theme.program, pulse: true); Text("REC") } }
                } else {
                    let n = model.selectedDestinations.count
                    Text(n == 0 ? "No destinations armed" : "\(n) destination\(n == 1 ? "" : "s") armed").foregroundStyle(Theme.muted)
                }
                if let e = s.error { Text(e).foregroundStyle(Theme.program).lineLimit(1) }
            }.font(Theme.Font.mono(10.5)).foregroundStyle(Theme.text).padding(.horizontal, 12)
        }
        .frame(height: 26)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
        .task { while !Task.isCancelled { cpu.sample(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
        .accessibilityElement(children: .contain).accessibilityLabel("Status bar")
    }
    var divider: some View { Rectangle().fill(Theme.stroke).frame(width: 1, height: 14) }
    @ViewBuilder var diskStat: some View {
        let d = model.disk
        if d.totalBytes > 0 {
            stat("DISK", "\(formatBytes(d.freeBytes)) free", d.freeBytes < 10 << 30 ? Theme.warn : Theme.text)
        }
    }
    func stat(_ label: String, _ value: String, _ color: Color = Theme.text) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Theme.faint)
            Text(value).font(Theme.Font.mono(10.5)).foregroundStyle(color)
        }.padding(.horizontal, 12).overlay(alignment: .trailing) { divider }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) var model
    @State var page: StudioPage = StudioPage(rawValue: ProcessInfo.processInfo.environment["STUDIO_PAGE"] ?? "") ?? .studio
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        @Bindable var m = model
        NavigationSplitView(columnVisibility: $visibility) {
            List(StudioPage.allCases, selection: Binding<StudioPage?>(get: { page }, set: { if let v = $0 { page = v } })) { p in
                Label(p.rawValue, systemImage: p.icon)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 3)
                    .tag(p)
                    .accessibilityLabel(p.rawValue)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 172, max: 210)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case .studio: ConsoleView()
                    case .scenes: ScenesPage()
                    case .phones: PhonesPage()
                    case .props: PropsView()
                    case .audio: AudioMixerPage()
                    case .recordings: RecordingsView()
                    case .outputs: OutputsPage()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                StatusBar()
            }
            .navigationTitle(page.rawValue)
            .navigationSubtitle(model.studioName)
        }
        .frame(minWidth: 1280, minHeight: 800)
        .background(WindowConfigurator())
        .toolbar { StudioToolbar() }
        .sheet(isPresented: $m.showAddPhone) { AddPhoneDialog() }
        .sheet(isPresented: $m.showNewScene) { NewSceneSheet().environment(model) }
        .sheet(isPresented: $m.showStreamKey) { StreamKeyDialog() }
        .onChange(of: model.editingScene?.id) { _, id in if id != nil { page = .scenes } }
        .sheet(isPresented: $m.showGoLiveConfirm) { GoLiveSheet().environment(model) }
        .sheet(isPresented: Binding(get: { model.abg.showConnect }, set: { model.abg.showConnect = $0 })) { ABGConnectDialog().environment(model) }
        .sheet(isPresented: Binding(get: { model.abg.showMatches }, set: { model.abg.showMatches = $0 })) { ABGMatchPicker().environment(model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .studioShowRecordings)) { _ in page = .recordings }
        .onReceive(NotificationCenter.default.publisher(for: .studioShowConsole)) { _ in page = .studio }
        .onReceive(NotificationCenter.default.publisher(for: .studioNavigate)) { n in
            if let raw = n.object as? String, let p = StudioPage(rawValue: raw) { page = p }
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.stroke)
            HStack(spacing: 6) {
                StatusDot(color: model.isLive ? Theme.program : Theme.faint, pulse: model.isLive)
                Text(model.isLive ? "ON AIR" : "OFF AIR").font(Theme.Font.label).tracking(0.8).foregroundStyle(model.isLive ? Theme.program : Theme.muted)
            }
            Text(model.lanURL.isEmpty ? "No network" : model.lanURL).font(Theme.Font.mono(10)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 5) {
                StatusDot(color: model.abg.isConnected ? (model.abg.lastError == nil ? Theme.ok : Theme.warn) : Theme.faint)
                Text(model.abg.isConnected ? "AirBattleground" : "AirBattleground off").font(Theme.Font.caption).foregroundStyle(Theme.muted)
            }.help(model.abg.heartbeatError ?? model.abg.lastError ?? "AirBattleground")
        }.padding(.horizontal, 14).padding(.bottom, 10)
    }
}

struct StudioToolbar: ToolbarContent {
    @Environment(AppModel.self) var model
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                if model.isLive {
                    Pill(text: "LIVE", color: Theme.program, filled: true, icon: "circle.fill")
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(model.liveSince ?? ctx.date))).font(Theme.Font.mono(13, .semibold))
                    }
                    if model.stats.error != nil { Pill(text: "Issue", color: Theme.warn, icon: "exclamationmark.triangle.fill") }
                } else {
                    Pill(text: "OFF AIR", color: Theme.muted)
                    Text("\(model.devices.filter(\.videoReady).count)/\(model.devices.count) phones live").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            @Bindable var m = model
            ABGToolbarChip()
            Button { m.recordOn.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.recordOn ? "record.circle.fill" : "record.circle").foregroundStyle(model.recordOn ? Theme.program : Theme.muted)
                    Text("Record")
                }
            }
            .buttonStyle(.studio(.secondary, height: 26))
            .disabled(model.isLive).help("Record on this Mac when going live")
            .accessibilityLabel("Record").accessibilityValue(model.recordOn ? "On" : "Off")
            if model.isLive {
                Button { model.stopLive() } label: { HStack(spacing: 5) { Image(systemName: "stop.fill"); Text("End Show") } }
                    .buttonStyle(.studio(.primary(Theme.program), height: 26)).disabled(model.busy)
            } else {
                Button { model.showGoLiveConfirm = true } label: { HStack(spacing: 5) { Image(systemName: "dot.radiowaves.left.and.right"); Text("Go Live") } }
                    .buttonStyle(.studio(.primary(Theme.program), height: 26)).disabled(model.busy)
                    .help("Start the show (asks to confirm)")
            }
        }
    }
}

// MARK: - Window

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.appearance = NSAppearance(named: .darkAqua)
            w.setFrameAutosaveName("7XENStudioMainWindow")
            w.minSize = NSSize(width: 1280, height: 800)
            w.backgroundColor = NSColor(red: 0.067, green: 0.070, blue: 0.082, alpha: 1)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Secondary pages

struct PhonesPage: View {
    @Environment(AppModel.self) var model
    var body: some View {
        PageScaffold(title: "Phones", subtitle: "Phones running the 7XEN Stream app, connected over your local network.") {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                PhonesPanel()
                Panel(title: "Connection", icon: "wifi") {
                    Text("Phones connect to").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                    Text(model.lanURL.isEmpty ? "-" : model.lanURL).font(Theme.Font.mono(12, .semibold)).textSelection(.enabled)
                    Text("Use Add to create a pairing QR code. The phone and this Mac must share Wi-Fi.").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                }.frame(width: 280)
            }
        }
    }
}

struct OutputsPage: View {
    var body: some View {
        PageScaffold(title: "Outputs", subtitle: "Choose where the show goes: your Mac's disk and streaming destinations.") {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.l) {
                    OutputsPanel()
                    ThumbnailPanel()        // AirBattleground: YouTube thumbnail of the admin's broadcast
                }
                OutputHealthPanel().frame(width: 300)
            }
        }
    }
}

extension Notification.Name {
    static let studioShowRecordings = Notification.Name("studioShowRecordings")
    static let studioShowConsole = Notification.Name("studioShowConsole")
    static let studioNavigate = Notification.Name("studioNavigate")
}
