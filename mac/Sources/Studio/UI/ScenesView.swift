import SwiftUI
struct SceneCard: View {
    @Environment(AppModel.self) var model
    let scene: Scene; let index: Int
    /// false = shown under "Other scenes" on the Scenes page (not in the active preset): no hotkey, dimmed
    var inActivePreset = true
    @State private var hover = false
    @State private var confirmDelete = false
    var onAir: Bool { model.programID == scene.id }
    var selected: Bool { model.previewID == scene.id }
    var tally: Color? { onAir ? Theme.program : selected ? Theme.preview : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SceneThumbnail(scene: scene, live: onAir ? .program : selected ? .preview : nil)
                .overlay(alignment: .topLeading) { if inActivePreset && index < 9 { KeyCap(text: "\(index + 1)").padding(6) } }
                .overlay(alignment: .topTrailing) {
                    if hover {
                        HStack(spacing: 4) {
                            IconButton(systemName: "pencil", label: "Edit scene", size: 22, tint: .white) { model.editingScene = scene }
                                .background(.black.opacity(0.6), in: Circle())
                            IconButton(systemName: "plus.square.on.square", label: "Duplicate scene", size: 22, tint: .white) { model.duplicateScene(scene) }
                                .background(.black.opacity(0.6), in: Circle())
                            IconButton(systemName: "trash", label: "Delete scene", size: 22, tint: Color(red: 1, green: 0.55, blue: 0.55)) { confirmDelete = true }
                                .background(.black.opacity(0.6), in: Circle())
                        }.padding(5).transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if onAir { Pill(text: "PGM", color: Theme.program, filled: true).padding(6) }
                    else if selected { Pill(text: "PVW", color: Theme.preview, filled: true).padding(6) }
                }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(scene.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(summary).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 9).padding(.vertical, 7)
        }
        .opacity(inActivePreset ? 1 : 0.6)
        .background(hover ? Theme.panelHi.opacity(1) : Theme.panelHi.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(tally ?? (hover ? Theme.strokeStrong : Theme.stroke), lineWidth: tally == nil ? 1 : 2.5))
        .shadow(color: (tally ?? .clear).opacity(0.35), radius: 8)
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.2), value: tally)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.takeScene(scene) }
        .onTapGesture { model.select(scene) }
        .contextMenu {
            Button("Preview") { model.select(scene) }
            Button("Take to Program") { model.takeScene(scene) }
            Divider()
            Button("Edit…") { model.editingScene = scene }
            Button { model.duplicateScene(scene) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if inActivePreset {
                Button("Move left") { model.moveSceneInActivePreset(scene.id, to: index - 1) }.disabled(index == 0)
                Button("Move right") { model.moveSceneInActivePreset(scene.id, to: index + 1) }.disabled(index >= model.scenes.count - 1)
            }
            Divider()
            if let a = model.activePreset {
                if inActivePreset { Button("Remove from “\(a.name)”") { model.removeFromActivePreset(scene) } }
                else { Button("Add to “\(a.name)”") { model.setScene(scene.id, inPreset: a.id, true) } }
            }
            Menu("Presets") {
                ForEach(model.presetBook.presets) { p in
                    let member = p.sceneIds.contains(scene.id)
                    Button { model.setScene(scene.id, inPreset: p.id, !member) } label: {
                        if member { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete scene…", systemImage: "trash") }
            Divider()
            if model.capture.live.running && model.capture.live.sceneId == scene.id {
                Button { model.capture.live.stop() } label: { Label("Stop auto capture", systemImage: "stop.circle") }
            } else {
                Button { model.capture.autoCapture(sceneId: scene.id) } label: { Label("Auto capture this scene", systemImage: "camera.viewfinder") }
            }
        }
        .modifier(SceneDeleteConfirm(scene: scene, isPresented: $confirmDelete))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scene \(index + 1), \(scene.name)\(onAir ? ", on air" : selected ? ", in preview" : "")")
        .accessibilityHint("Click to preview, double-click to take")
        .accessibilityAddTraits(.isButton)
    }
    /// What the scene shows, from its layers (the old slot list is empty for layer scenes, which read as "Empty").
    var summary: String {
        guard let ls = model.services.layerScenes().first(where: { $0.id == scene.id }) else { return "Empty" }
        if ls.layers.isEmpty { return "Empty - click ✎ to add something" }
        var parts: [String] = []
        for l in ls.layers.reversed() {
            switch l.kind {
            case .source(let r, _):
                if case .prop(let id) = r, let p = model.props.first(where: { $0.id == id }) { parts.append(p.isVideo ? "Video" : "Picture") } else { parts.append(label(r)) }
            case .image(let spec):
                if let id = spec.propId, let p = model.props.first(where: { $0.id == id }) { parts.append(p.isVideo ? "Video" : "Picture") } else { parts.append("Art") }
            case .text: parts.append("Text")
            default: break
            }
        }
        var seen = Set<String>(); let uniq = parts.filter { seen.insert($0).inserted }
        return uniq.isEmpty ? "\(ls.layers.count) layer\(ls.layers.count == 1 ? "" : "s")" : uniq.prefix(3).joined(separator: " · ")
    }
    func label(_ s: SourceRef?) -> String {
        var t = sourceLabel(s, model.devices)
        if case .device(let id)? = s, let d = model.devices.first(where: { $0.id == id }), d.videoReady, let q = d.qualityLabel?.split(separator: " ").first { t += (d.lowQuality ? " ⚠ " : " ") + q }
        return t
    }
}

/// Delete confirmation for a scene card. The on-air scene is blocked: the operator must confirm "Cut to black & delete".
struct SceneDeleteConfirm: ViewModifier {
    @Environment(AppModel.self) var model
    let scene: Scene
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        let onAir = model.deleteBlock(scene) == .onAir
        let presets = model.presetBook.presets(containing: scene.id).map(\.name)
        content.alert(onAir ? "“\(scene.name)” is on air" : "Delete “\(scene.name)”?", isPresented: $isPresented) {
            if onAir {
                Button("Cut to black & delete", role: .destructive) { model.deleteScene(scene, cutToBlack: true) }
            } else {
                Button("Delete scene", role: .destructive) { model.deleteScene(scene) }
            }
            if model.activePreset.map({ $0.sceneIds.contains(scene.id) }) == true && presets.count > 1 {
                Button("Only remove from “\(model.activePreset?.name ?? "")”") { model.removeFromActivePreset(scene) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if onAir {
                Text("It is on Program right now, so it can't just be deleted. Take another scene first, or cut the program to black and delete it.")
            } else {
                Text(presets.count > 1 ? "It is removed from the studio and from \(presets.count) presets: \(presets.joined(separator: ", ")). This can't be undone."
                     : "The scene is removed from the studio. This can't be undone.")
            }
        }
    }
}

/// Live mini-monitor when the scene is on program/preview, otherwise a generated layout glyph.
struct SceneThumbnail: View {
    @Environment(AppModel.self) var model
    let scene: Scene; var live: MonitorKind?
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.well)
            if let live {
                let services = model.services
                MonitorSurface(provider: { services.frame(live) }, serial: { services.frameSerial(live) }, fps: 15)
            } else {
                LayerSceneThumb(scene: scene)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
    }
    func icon(_ s: SourceRef?) -> String {
        switch s { case nil: "plus"; case .device?: "iphone"; case .camera?: "web.camera"; case .slate?: "text.below.photo"; case .prop?: "film"; case .image?: "photo"; case .web?: "globe" }
    }
    func color(_ s: SourceRef?) -> Color {
        switch s { case nil: .gray; case .device?: Theme.accent; case .camera?: .teal; case .slate?: .indigo; case .prop?: .purple; case .image?: .pink; case .web?: .orange }
    }
}

func sourceLabel(_ s: SourceRef?, _ devices: [DeviceInfo]) -> String {
    guard let s else { return "Empty" }
    switch s {
    case .device(let id): return devices.first { $0.id == id }?.name ?? "Removed phone"
    case .camera: return "Webcam"
    case .slate: return "Slate"
    case .prop: return "Video"
    case .image: return "Image"
    case .web: return "Web image"
    }
}

struct ScenesStrip: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionHeader(text: "Scenes")
                Text("⌘1-9 select  ·  Space takes  ·  double-click takes").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                Spacer()
                Button { model.newScene() } label: { Label("New Scene", systemImage: "plus") }.buttonStyle(.studio(.secondary, height: 24))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)], spacing: 12) {
                    ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, s in SceneCard(scene: s, index: i) }
                }.padding(.vertical, 4).padding(.horizontal, 3)
            }
        }
    }
}

struct SceneEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var draft: Scene
    @State var confirmDelete = false
    var isNew: Bool { !model.allScenes.contains { $0.id == draft.id } }

    func setLayout(_ l: LayoutKind) {
        draft.layout = l
        draft.slots = (0..<l.slotNames.count).map { $0 < draft.slots.count ? draft.slots[$0] : nil }
    }
    var badWeb: Bool {
        draft.slots.contains { if case .web(let u)? = $0 { return !(u.hasPrefix("http://") || u.hasPrefix("https://")) }; return false }
    }
    func tag(_ s: SourceRef?) -> String {
        switch s { case nil: "none"; case .device(let id)?: "device:\(id)"; case .camera?: "camera"; case .slate?: "slate"; case .prop(let i)?: "prop:\(i)"; case .image(let i)?: "image:\(i)"; case .web?: "web" }
    }
    func binding(_ i: Int) -> Binding<String> {
        Binding(get: { tag(i < draft.slots.count ? draft.slots[i] : nil) }, set: { v in
            while draft.slots.count <= i { draft.slots.append(nil) }
            let old = draft.slots[i]
            if v == "none" { draft.slots[i] = nil }
            else if v == "camera" { draft.slots[i] = .camera }
            else if v == "slate" { draft.slots[i] = .slate }
            else if v.hasPrefix("prop:") { draft.slots[i] = .prop(id: String(v.dropFirst(5))) }
            else if v.hasPrefix("image:") { draft.slots[i] = .image(id: String(v.dropFirst(6))) }
            else if v == "web" { if case .web? = old {} else { draft.slots[i] = .web(url: "") } }
            else if v.hasPrefix("device:") { draft.slots[i] = .device(id: String(v.dropFirst(7))) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New scene" : "Edit scene").font(.title2.bold())
            Text("Pick a frame, then what goes in each part of it.").foregroundStyle(Theme.muted)
            TextField("Scene name", text: $draft.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(LayoutKind.allCases, id: \.self) { k in
                    Button { setLayout(k) } label: {
                        VStack(spacing: 3) { LayoutIcon(layout: k); Text(k.label).font(.system(size: 10)).lineLimit(1) }
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(draft.layout == k ? Theme.accent : Theme.stroke, lineWidth: draft.layout == k ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
            ForEach(Array(draft.layout.slotNames.enumerated()), id: \.offset) { i, name in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(name, selection: binding(i)) {
                        Text("Empty").tag("none")
                        if !model.devices.isEmpty { Section("Phones") { ForEach(model.devices) { Text($0.name).tag("device:\($0.id)") } } }
                        Section("This Mac") { Text("Webcam").tag("camera"); Text("Slate (text, or the intro video)").tag("slate") }
                        if !model.props.isEmpty {
                            Section("Props") { ForEach(model.props) { Text($0.name).tag(($0.isVideo ? "prop:" : "image:") + $0.id) } }
                        }
                        Section("Web") { Text("Image from a web address").tag("web") }
                    }
                    if i < draft.slots.count, case .device(let did)? = draft.slots[i], let dev = model.devices.first(where: { $0.id == did }) {
                        HStack(spacing: 10) {
                            if let q = dev.qualityLabel { Text(q).font(Theme.Font.mono(10)).foregroundStyle(dev.lowQuality ? Theme.warn : Theme.muted) }
                            Spacer()
                            RotateMenu(d: dev).menuStyle(.borderlessButton).fixedSize()
                        }
                        if let w = dev.qualityWarning { QualityWarningChip(text: w) }
                    }
                    if i < draft.slots.count, draft.slots[i] != nil, draft.slots[i] != .slate {
                        Picker("Picture", selection: Binding(get: { draft.fit(i) }, set: { draft.setFit(i, $0) })) {
                            Text("Fill (crop to cover)").tag(false); Text("Fit (show everything)").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if i < draft.slots.count, case .web(let url)? = draft.slots[i] {
                        TextField("https://… (an image that updates)", text: Binding(get: { url }, set: { draft.slots[i] = .web(url: $0.trimmingCharacters(in: .whitespaces)) })).textFieldStyle(.roundedBorder)
                        Text("Refreshed every 2 seconds. Must be an image, not a web page.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            HStack {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete scene", systemImage: "trash") }.disabled(isNew || model.allScenes.count <= 1 || model.programID == draft.id)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { var s = draft; s.name = s.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Scene" : s.name; model.save(s); dismiss() } label: { Label("Save scene", systemImage: "checkmark") }
                    .keyboardShortcut(.defaultAction).disabled(badWeb)
            }
        }
        .padding(20).frame(width: 520)
        .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete) {
            Button("Delete scene", role: .destructive) { model.delete(draft); dismiss() }
        } message: { Text("The scene is removed from the show.") }
    }
}
