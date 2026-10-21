import SwiftUI
import AppKit

// MARK: - Fullscreen / large monitor

/// Container that forwards double-click to a handler while the MonitorNSView keeps owning its layer.
final class FullscreenHostView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { if event.clickCount >= 2 { onDoubleClick?() } else { super.mouseDown(with: event) } }
}

@MainActor
final class MonitorFullscreen: NSObject, NSWindowDelegate {
    static let shared = MonitorFullscreen()
    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    func toggle(services: StudioServices) {
        if let w = window { w.close(); return }
        let monitor = MonitorNSView(frame: .zero)
        monitor.fps = 60; monitor.logName = "fullscreen"
        monitor.provider = { services.frame(.program) }
        monitor.serial = { services.frameSerial(.program) }
        let host = FullscreenHostView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        host.onDoubleClick = { [weak self] in self?.window?.close() }
        monitor.frame = host.bounds; monitor.autoresizingMask = [.width, .height]
        host.addSubview(monitor)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = host
        w.title = "7XEN Program"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        w.toggleFullScreen(nil)
    }
    func windowWillClose(_ notification: Notification) { window?.delegate = nil; window = nil }
    func windowDidExitFullScreen(_ notification: Notification) { window?.close() }
}

// MARK: - Big program player

struct ProgramPlayer: View {
    @Environment(AppModel.self) var model
    @State private var hover = false
    @State private var safe = false
    var width: CGFloat

    var body: some View {
        let services = model.services
        let live = model.isLive
        ZStack {
            MonitorSurface(provider: { services.frame(.program) }, serial: { services.frameSerial(.program) }, fps: 60, tag: "program")
            if safe { SafeAreaGuides() }
        }
        .frame(width: width, height: width * 9 / 16)
        .background(.black)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                OnAirBadge()
                if let n = model.program?.name {
                    Text(n).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                ABGMatchBadge()
            }.padding(12)
        }
        .overlay(alignment: .topTrailing) { PreviewInset(width: min(240, max(150, width * 0.22))).padding(12) }
        .overlay(alignment: .bottom) { if hover { controls.transition(.opacity) } }   // not in the tree (and no meter timeline) while hidden
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(live ? Theme.program : Theme.program.opacity(0.35), lineWidth: live ? 3 : 1.5))
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .shadow(color: Theme.program.opacity(live ? 0.35 : 0), radius: 18)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { MonitorFullscreen.shared.toggle(services: services) }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .animation(.easeInOut(duration: 0.3), value: live)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Program monitor, \(model.program?.name ?? "no scene")")
    }

    var controls: some View {
        HStack(spacing: 12) {
            if model.isLive {
                HStack(spacing: 5) { StatusDot(color: Theme.program, pulse: true); Text("LIVE").font(.system(size: 11, weight: .heavy)).tracking(1) }
                    .foregroundStyle(.white)
            } else {
                Text("OFF AIR").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(.white.opacity(0.7))
            }
            Timecode(since: model.liveSince, size: 13)
            Spacer(minLength: 0)
            Text("1080p60").font(Theme.Font.mono(10, .semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 2) {
                MeterBar(level: model.audioPeak, vertical: false, segments: 20)
                    .frame(width: 90, height: 5)
            }
            if let audio = model.services.audio { MicSwitch(audio: audio, compact: true) }
            IconButton(systemName: "viewfinder", label: safe ? "Hide safe areas" : "Show safe areas", size: 28, tint: safe ? Theme.accent : .white) { safe.toggle() }
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Fullscreen monitor", size: 28, tint: .white) {
                MonitorFullscreen.shared.toggle(services: model.services)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 8).padding(.top, 34)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom))
    }
}

/// NEXT scene picture-in-picture inset (green tally), docked in the corner of the program frame.
struct PreviewInset: View {
    @Environment(AppModel.self) var model
    var width: CGFloat
    var body: some View {
        let services = model.services
        MonitorSurface(provider: { services.frame(.preview) }, serial: { services.frameSerial(.preview) }, fps: 30, tag: "preview")
            .frame(width: width, height: width * 9 / 16)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.preview, lineWidth: 2))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Circle().fill(Theme.preview).frame(width: 6, height: 6)
                    Text("NEXT").font(.system(size: 9, weight: .heavy)).tracking(1)
                    Text(model.preview?.name ?? "none").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white).padding(.horizontal, 6).frame(height: 18)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4, style: .continuous)).padding(5)
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            .contentShape(Rectangle()).onTapGesture(count: 2) { model.take() }
            .help("Next scene (preview). Double-click to take.")
            .accessibilityLabel("Preview monitor, \(model.preview?.name ?? "no scene")")
    }
}

// MARK: - Transition bar

struct TransitionBar: View {
    @Environment(AppModel.self) var model
    @Binding var inspectorOpen: Bool
    var canTake: Bool { model.previewID != nil && model.previewID != model.programID }
    var body: some View {
        @Bindable var m = model
        HStack(spacing: 10) {
            Button { model.take() } label: {
                HStack(spacing: 8) {
                    Text("TAKE").font(.system(size: 14, weight: .heavy)).tracking(1.5)
                    Text("SPACE").font(Theme.Font.mono(9, .bold)).opacity(0.7)
                }.padding(.horizontal, 10)
            }
            .buttonStyle(.studio(.primary(Theme.program), height: 34))
            .disabled(!canTake).keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel("Take preview to program")
            modeButton("CUT", .cut); modeButton("AUTO", .fade)
            HStack(spacing: 8) {
                Text("Duration").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                Slider(value: Binding(get: { Double(m.transitionMs) }, set: { m.transitionMs = Int($0 / 100) * 100 }), in: 100...2000)
                    .controlSize(.small).frame(minWidth: 70, maxWidth: 150).disabled(model.transition == .cut)
                    .accessibilityLabel("Fade duration")
                Text(String(format: "%.1fs", Double(model.transitionMs) / 1000)).font(Theme.Font.mono(11)).foregroundStyle(Theme.text).frame(width: 34, alignment: .leading)
            }.opacity(model.transition == .cut ? 0.4 : 1)
            Spacer(minLength: 8)
            if let audio = model.services.audio { MicSwitch(audio: audio) }
            Button { m.recordOn.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.recordOn ? "record.circle.fill" : "record.circle").foregroundStyle(model.recordOn ? Theme.program : Theme.muted)
                    Text(model.recordOn ? "REC on" : "REC off")
                }
            }
            .buttonStyle(.studio(.secondary, height: 34)).disabled(model.isLive)
            .help("Record on this Mac when going live")
            .accessibilityLabel("Record").accessibilityValue(model.recordOn ? "On" : "Off")
            if model.isLive {
                Button { model.stopLive() } label: { HStack(spacing: 5) { Image(systemName: "stop.fill"); Text("End Show") } }
                    .buttonStyle(.studio(.primary(Theme.program), height: 34)).disabled(model.busy)
            } else {
                Button { model.showGoLiveConfirm = true } label: { HStack(spacing: 5) { Image(systemName: "dot.radiowaves.left.and.right"); Text("Go Live") } }
                    .buttonStyle(.studio(.primary(Theme.ok), height: 34)).disabled(model.busy)
                    .help("Start the show (asks to confirm)")
            }
            IconButton(systemName: "sidebar.right", label: inspectorOpen ? "Hide inspector" : "Show inspector", size: 30, tint: inspectorOpen ? Theme.accent : Theme.muted) {
                withAnimation(.easeOut(duration: 0.2)) { inspectorOpen.toggle() }
            }
        }
        .padding(.horizontal, 10).frame(height: 46)
        .card(fill: Theme.panel.opacity(0.7), radius: Theme.Radius.m)
    }
    func modeButton(_ title: String, _ kind: TransitionKind) -> some View {
        let sel = model.transition == kind
        return Button { model.transition = kind; if canTake { model.take() } } label: {
            Text(title).font(.system(size: 11, weight: .bold)).lineLimit(1).padding(.horizontal, 6)
        }
        .buttonStyle(.studio(sel ? .primary(Theme.accent) : .secondary, height: 34))
        .help(kind == .cut ? "Cut to preview instantly" : "Fade to preview")
    }
}

// MARK: - Scenes bar

struct ScenesBar: View {
    @Environment(AppModel.self) var model
    static let cardW: CGFloat = 164
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SectionHeader(text: "Scenes")
                Text("1-9 select  ·  Space takes  ·  double-click takes").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, s in
                        SceneCard(scene: s, index: i).frame(width: Self.cardW).fixedSize(horizontal: false, vertical: true)
                    }
                    Button { model.newScene() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                            Text("New Scene").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.muted).frame(width: Self.cardW, height: 134)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain).accessibilityLabel("New scene")
                }.padding(.vertical, 4).padding(.horizontal, 3)
            }
        }
        .frame(height: 164)
    }
}
