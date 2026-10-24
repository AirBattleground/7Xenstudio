import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "New scene" in two clicks: pick what the scene shows (a video/picture, a phone, the webcam or a template), name it,
/// done. The scene fills the whole screen with that one thing and is put on Preview (NEXT), ready for TAKE.
/// The full layer editor is still there for anything fancier ("Empty scene - design it myself").
struct NewSceneSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    enum Step { case choose, media, phone, template }
    @State private var step: Step = .choose
    @State private var name = ""
    @State private var pickedProp: String?
    @State private var dropHover = false
    @State private var uploading = false
    @State private var waitingForUpload: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch step {
            case .choose: chooser
            case .media: mediaPicker
            case .phone: phonePicker
            case .template: templatePicker
            }
        }
        .padding(24)
        .frame(width: 720, height: 560, alignment: .topLeading)
        .background(Theme.panel)
        .onChange(of: model.props.map(\.id)) { _, ids in selectNewUpload(ids) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            if step != .choose {
                Button { step = .choose; pickedProp = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.studio(.ghost, height: 28))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.title)
                Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.studio(.secondary, height: 28)).keyboardShortcut(.cancelAction)
        }
    }
    private var title: String {
        switch step {
        case .choose: "New scene"
        case .media: "Pick a video or picture"
        case .phone: "Pick a phone"
        case .template: "Pick a template"
        }
    }
    private var subtitle: String {
        switch step {
        case .choose: "What should this scene show? It fills the whole screen."
        case .media: "Choose one you uploaded, or upload a new one. Videos loop and play their sound on air."
        case .phone: "The phone's camera or screen fills the whole screen."
        case .template: "A ready-made design. You can change it later in the editor."
        }
    }

    // MARK: step 1

    private var chooser: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                tile("film", "Video or picture", "Countdowns, intros, posters, your uploads") { step = .media }
                tile("iphone", "Phone", model.devices.isEmpty ? "No phones paired yet" : "\(model.devices.count) paired") { step = .phone }
                    .disabled(model.devices.isEmpty).opacity(model.devices.isEmpty ? 0.45 : 1)
            }
            HStack(spacing: 12) {
                tile("web.camera", "Mac webcam", "This Mac's camera, full screen") { create(name: "Webcam", layer: .source("Webcam", .camera, x: 0, y: 0, w: 1920, h: 1080)) }
                tile("square.grid.2x2", "Template", "Ready-made esports designs") { step = .template }
                tile("list.number", "Team status board", "Live alive / knocked / eliminated board for every team") {
                    create(scene: Self.teamBoardScene())
                }
            }
            Button {
                dismiss()
                SceneBuilderActions.newScene(model, from: LayerScene(name: "Scene", background: .solid(RGBA(hex: 0x06090C))), name: "Scene \(model.scenes.count + 1)")
            } label: {
                Label("Empty scene - design it myself in the editor", systemImage: "square.dashed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.studio(.ghost, height: 34))
        }
    }

    private func tile(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(sub).font(Theme.Font.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).stroke(Theme.strokeStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: video / picture

    private var mediaPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    uploadTile
                    ForEach(model.props) { p in propTile(p) }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)
            if let id = pickedProp, let p = model.props.first(where: { $0.id == id }) {
                finishBar(defaultName: p.name) {
                    create(name: name, layer: .source(p.name, .prop(id: p.id), x: 0, y: 0, w: 1920, h: 1080, fit: .fill))
                }
            } else {
                Text("Tip: you can also drag a video or picture from Finder onto this window.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.faint)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { upload([url]) } }
                }
            }
            return true
        }
        .overlay(dropHover ? RoundedRectangle(cornerRadius: Theme.Radius.l).stroke(Theme.accent, lineWidth: 2) : nil)
    }

    private var uploadTile: some View {
        Button { pickFiles() } label: {
            VStack(spacing: 8) {
                Image(systemName: uploading ? "hourglass" : "square.and.arrow.up").font(.system(size: 26))
                Text(uploading ? "Uploading..." : "Upload new").font(Theme.Font.bodyBold)
                Text("MP4, MOV, PNG, JPG").font(Theme.Font.caption).foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(uploading)
    }

    private func propTile(_ p: PropInfo) -> some View {
        let selected = pickedProp == p.id
        return Button { pickedProp = p.id; name = p.name } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let cg = model.services.propThumbnail(id: p.id) {
                            Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Theme.well.overlay(Image(systemName: p.isVideo ? "film" : "photo").foregroundStyle(Theme.faint))
                        }
                    }
                    .frame(height: 84).frame(maxWidth: .infinity).clipped()
                    Text(p.isVideo ? "VIDEO" : "PICTURE").font(Theme.Font.label).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s))
                Text(p.name).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(2, reservesSpace: true)
            }
            .padding(6)
            .background(selected ? Theme.accent.opacity(0.18) : Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            create(name: p.name, layer: .source(p.name, .prop(id: p.id), x: 0, y: 0, w: 1920, h: 1080, fit: .fill))
        })
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .png, .jpeg, .gif, .webP]
        panel.message = "Choose a video or picture for this scene"
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploading = true
        waitingForUpload = Set(model.props.map(\.id))
        model.addProps(urls)
    }
    /// When an upload lands, select it so the next click is "Create scene".
    private func selectNewUpload(_ ids: [String]) {
        guard uploading else { return }
        if let new = ids.first(where: { !waitingForUpload.contains($0) }), let p = model.props.first(where: { $0.id == new }) {
            pickedProp = p.id; name = p.name
        }
        uploading = false
    }

    // MARK: phone / template

    private var phonePicker: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.devices) { d in
                    Button { create(name: d.name, layer: .source(d.name, .device(id: d.id), x: 0, y: 0, w: 1920, h: 1080, fit: .fill)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(Theme.Font.bodyBold)
                                Text(d.streaming ? "Live now" : (d.online ? "Online, not streaming yet" : "Offline - it will show when it starts streaming"))
                                    .font(Theme.Font.caption).foregroundStyle(d.streaming ? Theme.ok : Theme.muted)
                            }
                            Spacer()
                            Text("Create scene").font(Theme.Font.bodyBold).foregroundStyle(Theme.accent)
                        }
                        .padding(14).frame(maxWidth: .infinity)
                        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var templatePicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(Templates.all) { t in
                    Button {
                        guard var s = Templates.make(t.id) else { return }
                        s.name = t.name
                        create(scene: s)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.name).font(Theme.Font.bodyBold).foregroundStyle(Theme.text)
                            Text(t.summary).font(Theme.Font.caption).foregroundStyle(Theme.muted).lineLimit(2, reservesSpace: true)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: finish

    private func finishBar(defaultName: String, onCreate: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text("Scene name").font(Theme.Font.bodyBold)
            TextField(defaultName, text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Spacer()
            Button(action: onCreate) { Label("Create scene", systemImage: "checkmark") }
                .buttonStyle(.studio(.primary(Theme.accent), height: 32)).keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
    }

    /// Black background with the dynamic Team Status board on the right side at full height.
    static func teamBoardScene(name: String = "Team Status") -> LayerScene {
        LayerScene(name: name, background: .solid(RGBA(hex: 0x000000)), layers: [LayerFactory.teamBoard(canvas: CanvasSize())])
    }
    private func create(name n: String, layer: Layer) {
        var l = layer; l.locked = false
        create(scene: LayerScene(name: n, background: .solid(RGBA(hex: 0x000000)), layers: [l]))
    }
    private func create(scene: LayerScene) {
        var s = scene
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        s.id = UUID().uuidString
        if step == .media, !trimmed.isEmpty { s.name = String(trimmed.prefix(60)) }
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = "Scene \(model.scenes.count + 1)" }
        model.createScene(s)
        dismiss()
    }
}
