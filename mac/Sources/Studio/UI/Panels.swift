import SwiftUI

struct SignalBars: View {
    var level: Int   // 0...3
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < level ? (level == 3 ? Theme.ok : Theme.warn) : Color.white.opacity(0.16))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }.frame(height: 10).accessibilityLabel("Signal \(level) of 3")
    }
}

struct BatteryGlyph: View {
    var percent: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: percent > 75 ? "battery.100" : percent > 50 ? "battery.75" : percent > 25 ? "battery.50" : "battery.25")
                .font(.system(size: 12)).foregroundStyle(percent <= 20 ? Theme.program : Theme.muted)
            Text("\(percent)%").font(Theme.Font.mono(10)).foregroundStyle(Theme.muted)
        }.accessibilityElement(children: .combine).accessibilityLabel("Battery \(percent) percent")
    }
}

/// Rotate / flip a phone's picture in the compositor (persisted per phone).
struct RotateMenu: View {
    @Environment(AppModel.self) var model
    let d: DeviceInfo
    var body: some View {
        Menu {
            Button { model.setTransform(d, rotation: nil, flip: d.flip) } label: { Label("Automatic" + (d.rotationAuto ? " ✓" : ""), systemImage: "wand.and.stars") }
            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Button { model.setTransform(d, rotation: deg, flip: d.flip) } label: { Label("\(deg)°" + (!d.rotationAuto && d.rotation == deg ? " ✓" : ""), systemImage: "rotate.right") }
            }
            Divider()
            Button { model.setTransform(d, rotation: d.rotationAuto ? nil : d.rotation, flip: !d.flip) } label: { Label("Flip horizontally" + (d.flip ? " ✓" : ""), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
        } label: { Label("Rotate" + (d.rotation != 0 || d.flip ? " (\(d.rotation)°\(d.flip ? " flip" : ""))" : ""), systemImage: "rotate.right") }
    }
}

/// Amber chip shown when a phone sends low-quality video.
struct QualityWarningChip: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.warn).padding(.horizontal, 7).padding(.vertical, 4)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.warn.opacity(0.45)))
        .accessibilityLabel("Warning: \(text)")
    }
}

struct PhoneRow: View {
    @Environment(AppModel.self) var model
    let d: DeviceInfo
    @State private var hover = false
    var state: (String, Color, Int) { d.videoReady ? ("LIVE", Theme.ok, 3) : d.online ? ("ONLINE", Theme.warn, 2) : ("OFFLINE", Theme.faint, 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.well)
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(d.videoReady ? Theme.ok.opacity(0.6) : Theme.stroke)
                Image(systemName: d.videoReady ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3").font(.system(size: 16)).foregroundStyle(d.videoReady ? Theme.ok : Theme.faint)
            }.frame(width: 64, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: state.1, pulse: d.videoReady)
                    Text(d.name).font(Theme.Font.bodyBold).foregroundStyle(Theme.text).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(state.0).font(Theme.Font.label).tracking(0.6).foregroundStyle(state.1).fixedSize()
                    if d.videoReady {
                        Text(d.qualityLabel.map { q in d.decodedFPS > 0 ? q + String(format: " · %.0f fps", d.decodedFPS) : q } ?? "\(Int(defaultFPS)) fps")
                            .font(Theme.Font.mono(10)).foregroundStyle(d.lowQuality ? Theme.warn : Theme.muted).fixedSize()
                        if d.rotation != 0 || d.flip { Text("↻\(d.rotation)°").font(Theme.Font.mono(10)).foregroundStyle(Theme.muted).fixedSize() }
                    }
                    if !d.videoReady, let m = d.model { Text(m).font(Theme.Font.caption).foregroundStyle(Theme.faint).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                SignalBars(level: state.2)
                if let b = d.battery { BatteryGlyph(percent: b) }
            }
        }
            if let w = d.qualityWarning { QualityWarningChip(text: w) }
            else if let h = d.ingestHint { QualityWarningChip(text: h) }
        }
        .padding(8)
        .background(Color.white.opacity(hover ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            RotateMenu(d: d)
            Divider()
            Button("Remove phone", role: .destructive) { model.removeDevice(d) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name), \(state.0.lowercased())")
    }
}

struct PhonesPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Panel(title: "Phones", icon: "iphone", trailing: {
            Button { model.showAddPhone = true } label: { Label("Add", systemImage: "plus") }.buttonStyle(.studio(.secondary, height: 22))
        }) {
            if model.devices.isEmpty {
                EmptyState(icon: "iphone.badge.plus", title: "No phones yet", message: "Tap Add, then scan the QR code with the 7XEN Stream app.")
            }
            ForEach(model.devices) { PhoneRow(d: $0) }
        }
    }
}

struct OutputsPanel: View {
    @Environment(AppModel.self) var model
    @State private var removing: Destination?
    var body: some View {
        @Bindable var m = model
        Panel(title: "Outputs", icon: "dot.radiowaves.left.and.right") {
            Toggle(isOn: $m.recordOn) { Label("Record on this Mac", systemImage: "record.circle").fontWeight(.semibold) }.disabled(model.isLive)
            VideoQualityControls().disabled(model.isLive)
            Divider().overlay(Theme.stroke)
            SectionHeader(text: "Destinations")
            if model.destinations.isEmpty { Text("No stream keys yet.").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
            ForEach(model.destinations) { d in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { model.selectedDestinations.contains(d.id) }, set: { on in
                        if on { model.selectedDestinations.insert(d.id) } else { model.selectedDestinations.remove(d.id) } })) {
                        Label(d.name, systemImage: d.kind == .youtube ? "play.rectangle.fill" : "antenna.radiowaves.left.and.right")
                    }.disabled(model.isLive)
                    if !model.isLive {
                        IconButton(systemName: "trash", label: "Remove \(d.name)") { removing = d }
                    }
                }
            }
            if !model.isLive {
                Button { model.showStreamKey = true } label: { Label("Add Stream Key", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.studio(.secondary, height: 26))
            } else { Text("End the show to change outputs.").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
        }
        .toggleStyle(StudioToggleStyle())
        .confirmationDialog("Remove \(removing?.name ?? "this stream key")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let d = removing { model.removeDestination(d) } }
        } message: { Text("You can add the key again any time.") }
    }
}

/// Live health of each active destination (used on the Outputs page).
struct OutputHealthPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let s = model.stats
        Panel(title: "Status", icon: "waveform.path.ecg") {
            if !s.live { Text("Off air. Start the show to see output health.").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
            else {
                ForEach(s.outputs) { o in
                    HStack { StatusDot(color: o.ok ? Theme.ok : Theme.program); Text(o.name).font(Theme.Font.body)
                        Spacer(); Text(o.error ?? "OK").font(Theme.Font.caption).foregroundStyle(o.ok ? Theme.muted : Theme.program).lineLimit(1) }
                }
                if let f = s.recordingFile { HStack { StatusDot(color: Theme.program, pulse: true); Text("Recording").font(Theme.Font.body); Spacer(); Text(f).font(Theme.Font.mono(10)).foregroundStyle(Theme.muted).lineLimit(1) } }
            }
            if let e = s.error { Pill(text: e, color: Theme.program) }
        }
    }
}

/// Bitrate presets + recording codec (shared by the Outputs panel and Settings).
struct VideoQualityControls: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 6) {
            Picker("Video bitrate", selection: $m.videoKbps) {
                ForEach(videoBitratePresets, id: \.kbps) { Text($0.name).tag($0.kbps) }
                if !videoBitratePresets.contains(where: { $0.kbps == model.videoKbps }) { Text("\(model.videoKbps / 1000) Mbps").tag(model.videoKbps) }
            }
            Picker("Recording quality", selection: $m.recordHEVC) {
                Text("H.264 High").tag(false)
                Text("HEVC High (cleaner, same bitrate)").tag(true)
            }
            Text("Live streams are always H.264 High 1080p60 (YouTube). HEVC only changes the recording on this Mac.").font(Theme.Font.caption).foregroundStyle(Theme.muted)
        }
    }
}
