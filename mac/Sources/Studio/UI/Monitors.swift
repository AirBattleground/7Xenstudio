import SwiftUI
import AppKit
import CoreImage

/// Layer-backed monitor that owns its drawing: a display link pulls the newest frame and assigns the IOSurface
/// straight to layer.contents (zero copy). SwiftUI never re-renders per frame.
final class MonitorNSView: NSView {
    var provider: (() -> MonitorFrame?)?
    var serial: (() -> UInt64)?
    /// When set, the display link asks for the frame belonging to its vsync (CADisplayLink.targetTimestamp) instead of the newest one.
    var paced: ((Double, inout Int64?) -> (frame: MonitorFrame, id: Int64)?)?
    private var pacedCursor: Int64?, lastPacedID: Int64 = .min
    var fps: Double = 60
    private var link: CADisplayLink?
    private var lastSerial: UInt64 = .max
    private var lastShown = 0.0
    private let ci = CIContext()
    // cadence log (STUDIO_MONITOR_LOG=1)
    private let logOn = ProcessInfo.processInfo.environment["STUDIO_MONITOR_LOG"] != nil
    private var logStart = 0.0, shown = 0, maxGap = 0.0, lastStamp = 0.0
    var logName = ""
    /// Optional per-displayed-frame hook (CACurrentMediaTime) used by the stress harness.
    var onShow: ((Double) -> Void)?
    nonisolated(unsafe) static var globalShow: ((String, Double) -> Void)?
    nonisolated(unsafe) static var globalTick: ((String, Double) -> Void)?   // every display-link callback with its targetTimestamp

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.drawsAsynchronously = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        let hz = Float(fps)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        l.add(to: .main, forMode: .common)
        link = l
    }
    deinit { link?.invalidate() }

    @objc private func tick(_ l: CADisplayLink) {
        if let g = Self.globalTick { g(logName, l.targetTimestamp) }
        let f: MonitorFrame
        if let pf = paced {
            guard let r = pf(l.targetTimestamp, &pacedCursor) else { return }
            if r.id == lastPacedID { return }
            lastPacedID = r.id
            f = r.frame
        } else {
            if let s = serial?(), s != 0 { if s == lastSerial { return }; lastSerial = s }
            guard let pfr = provider?() else { return }
            f = pfr
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch f {
        case .image(let img): layer?.contents = img
        case .pixels(let pb):
            if let s = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() { layer?.contents = s }
            else if let img = ci.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))) { layer?.contents = img }
        }
        CATransaction.commit()
        if let h = onShow { h(CACurrentMediaTime()) }
        if let g = Self.globalShow { g(logName, CACurrentMediaTime()) }
        if logOn {
            let now = CACurrentMediaTime()
            if lastStamp > 0 { maxGap = max(maxGap, now - lastStamp) }
            lastStamp = now; shown += 1
            if logStart == 0 { logStart = now }
            if now - logStart >= 1 {
                NSLog("MONITOR %@ shown=%.1f/s maxGap=%.1fms", logName, Double(shown) / (now - logStart), maxGap * 1000)
                shown = 0; maxGap = 0; logStart = now
            }
        }
    }
}

struct MonitorSurface: NSViewRepresentable {
    var provider: () -> MonitorFrame?
    var serial: (() -> UInt64)? = nil
    var fps: Double = 60
    var tag = ""
    var paced: ((Double, inout Int64?) -> (frame: MonitorFrame, id: Int64)?)? = nil
    func makeNSView(context: Context) -> MonitorNSView { let v = MonitorNSView(frame: .zero); v.fps = fps; v.logName = tag; v.provider = provider; v.serial = serial; v.paced = paced; return v }
    func updateNSView(_ v: MonitorNSView, context: Context) { v.provider = provider; v.serial = serial; v.paced = paced }
}

/// Broadcast timecode HH:MM:SS:FF counted from the moment the show went live. An AppKit label on its own 25 Hz timer: a SwiftUI
/// TimelineView(.animation) re-evaluated the surrounding view graph 25 times a second on the main thread.
struct Timecode: View {
    var since: Date?
    var size: CGFloat = 20
    var body: some View {
        TimecodeLabel(since: since, size: size, color: since == nil ? Theme.faint : Theme.text)
            .fixedSize()
            .accessibilityLabel("Timecode")
    }
}

private struct TimecodeLabel: NSViewRepresentable {
    var since: Date?, size: CGFloat, color: Color
    final class Label: NSTextField {
        var since: Date?
        private var timer: Timer?
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(CGFloat(11) * font!.maximumAdvancement.width), height: ceil(font!.boundingRectForFont.height)) }
        func tickNow() {
            let t = since.map { max(0, Date().timeIntervalSince($0)) } ?? 0
            let s = Int(t), f = Int((t - Double(s)) * 25)
            let str = String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f)
            if stringValue != str { stringValue = str }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate(); timer = nil
            guard window != nil else { return }
            let t = Timer(timeInterval: 1.0 / 25, repeats: true) { [weak self] _ in self?.tickNow() }
            t.tolerance = 0.004
            RunLoop.main.add(t, forMode: .common); timer = t; tickNow()
        }
        deinit { timer?.invalidate() }
    }
    func makeNSView(context: Context) -> Label {
        let l = Label(labelWithString: "00:00:00:00")
        l.isBordered = false; l.drawsBackground = false; l.isEditable = false; l.isSelectable = false
        l.alignment = .left; l.lineBreakMode = .byClipping
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }
    func updateNSView(_ l: Label, context: Context) {
        l.font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        l.textColor = NSColor(color)
        l.since = since
        l.tickNow()
        l.invalidateIntrinsicContentSize()
    }
}

/// Title-safe (90%) and action-safe (93%) guides.
struct SafeAreaGuides: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: g.size.width * 0.93, height: g.size.height * 0.93)
                RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.5), lineWidth: 1)
                    .frame(width: g.size.width * 0.90, height: g.size.height * 0.90)
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2 - 8, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width / 2 + 8, y: g.size.height / 2))
                    p.move(to: CGPoint(x: g.size.width / 2, y: g.size.height / 2 - 8)); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height / 2 + 8))
                }.stroke(.white.opacity(0.5), lineWidth: 1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.allowsHitTesting(false)
    }
}

struct Monitor: View {
    @Environment(AppModel.self) var model
    let kind: MonitorKind
    @State private var safe = false
    var isProgram: Bool { kind == .program }
    var scene: Scene? { isProgram ? model.program : model.preview }
    var tally: Color { isProgram ? Theme.program : Theme.preview }
    var hot: Bool { isProgram ? true : true }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(tally).frame(width: 9, height: 9).shadow(color: tally.opacity(0.9), radius: 4)
                    Text(isProgram ? "PROGRAM" : "PREVIEW").font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(tally).fixedSize()
                }
                Text(scene?.name ?? "No scene").font(Theme.Font.bodyBold).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                IconButton(systemName: "viewfinder", label: safe ? "Hide safe areas" : "Show safe areas", tint: safe ? Theme.accent : Theme.muted) { safe.toggle() }
            }
            ZStack {
                let services = model.services
                MonitorSurface(provider: { services.frame(kind) }, serial: { services.frameSerial(kind) }, fps: isProgram ? 60 : 30, tag: isProgram ? "program" : "preview")
                if safe { SafeAreaGuides() }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(.black)
            .overlay(alignment: .topLeading) { if isProgram { OnAirBadge().padding(10) } }
            .overlay(alignment: .bottomLeading) {
                if isProgram { Timecode(since: model.liveSince, size: 13).padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3)).padding(8) }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("1080p").font(Theme.Font.mono(10, .semibold)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3)).padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tally.opacity(isProgram && !model.isLive ? 0.7 : 1), lineWidth: isProgram ? 3 : 2))
            .shadow(color: tally.opacity(isProgram ? (model.isLive ? 0.55 : 0.15) : 0.18), radius: 16)
            .animation(.easeInOut(duration: 0.3), value: model.isLive)
            .padding(.trailing, 22)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    MeterBar(level: isProgram ? model.audioPeak : 0, segments: 28)
                    MeterBar(level: isProgram ? model.audioPeak : 0, segments: 28)
                }.frame(width: 14)
            }
            .accessibilityLabel("\(isProgram ? "Program" : "Preview") monitor, \(scene?.name ?? "no scene")")
        }
    }
}

/// Large LIVE / REC indicator burned into the program monitor.
struct OnAirBadge: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 6) {
            if model.isLive {
                HStack(spacing: 6) { StatusDot(color: .white, pulse: true); Text("LIVE").font(.system(size: 13, weight: .heavy)).tracking(1.5) }
                    .padding(.horizontal, 10).frame(height: 24).foregroundStyle(.white)
                    .background(Theme.program, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                if model.recordingFile != nil {
                    HStack(spacing: 5) { Circle().fill(Theme.program).frame(width: 7, height: 7); Text("REC").font(.system(size: 11, weight: .heavy)).tracking(1) }
                        .padding(.horizontal, 8).frame(height: 24).foregroundStyle(.white)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else {
                Text("OFF AIR").font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.isLive ? "Live" : "Off air")
    }
}
