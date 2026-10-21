import SwiftUI
import AppKit
import UniformTypeIdentifiers

let propContentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie, .png, .jpeg, .gif, .webP].compactMap { $0 }

func openPropsPanel(_ done: @escaping ([URL]) -> Void) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true; p.canChooseDirectories = false
    p.allowedContentTypes = propContentTypes
    p.message = "Choose videos (MP4, MOV, WebM) or images (PNG, JPEG, WebP, GIF)"
    if p.runModal() == .OK { done(p.urls) }
}

struct PropThumb: View {
    @Environment(AppModel.self) var model
    let prop: PropInfo
    @State var img: CGImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let img { Image(decorative: img, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: prop.isVideo ? "film" : "photo").foregroundStyle(Theme.muted) }
        }
        .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) { if prop.isVideo { Image(systemName: "play.fill").font(.system(size: 8)).padding(3).background(.black.opacity(0.6), in: Circle()).padding(3) } }
        .task(id: prop.id) {
            for _ in 0..<40 {
                if let t = model.services.propThumbnail(id: prop.id) { img = t; return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

struct PropRow: View {
    @Environment(AppModel.self) var model
    let prop: PropInfo
    @State var name = ""
    @State var confirmDelete = false
    var body: some View {
        HStack(spacing: 12) {
            PropThumb(prop: prop)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $name).textFieldStyle(.plain).font(.system(size: 14, weight: .bold))
                    .onSubmit { model.renameProp(prop, name) }
                Text("\(prop.isVideo ? "Video" : "Image") · \(formatBytes(prop.sizeBytes))").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if model.introPropId == prop.id { Chip(text: "Intro", color: Theme.accent, filled: true) }
            if prop.isVideo {
                Button(model.introPropId == prop.id ? "Clear intro" : "Use as intro") { model.setIntroProp(model.introPropId == prop.id ? nil : prop.id) }.controlSize(.small)
            }
            Button { model.renameProp(prop, name) } label: { Image(systemName: "checkmark") }.buttonStyle(.borderless).disabled(name == prop.name || name.trimmingCharacters(in: .whitespaces).isEmpty).help("Save name")
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { name = prop.name }
        .onChange(of: prop.name) { _, n in name = n }
        .confirmationDialog("Delete \(prop.name)?", isPresented: $confirmDelete) {
            Button("Delete prop", role: .destructive) { model.deleteProp(prop) }
        } message: { Text("Scenes that use it will show an empty slot.") }
    }
}

struct PropsView: View {
    @Environment(AppModel.self) var model
    @State var targeted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Props").font(.title.bold()); Spacer()
                    Button { openPropsPanel { model.addProps($0) } } label: { Label("Add videos or images…", systemImage: "plus") }
                }
                Text("Videos and images you can put in any scene. Drop files here, or use the button. Videos loop.").foregroundStyle(Theme.muted)
                SlateSettings()
                if model.props.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(Theme.muted)
                        Text("No props yet").font(.headline)
                        Text("Drag a video or image onto this window.").foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity).padding(40)
                }
                ForEach(model.props) { PropRow(prop: $0) }
            }.padding(20)
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(8).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in model.addProps(urls.filter { $0.isFileURL }); return true } isTargeted: { targeted = $0 }
    }
}

/// Slate text + intro prop (also shown in Settings).
struct SlateSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Slate", systemImage: "text.below.photo").font(.system(size: 12, weight: .bold))
            TextField("Starting soon", text: Binding(get: { model.slateText }, set: { model.setSlateText($0) })).textFieldStyle(.roundedBorder)
            Picker("Intro video", selection: Binding(get: { model.introPropId ?? "" }, set: { model.setIntroProp($0.isEmpty ? nil : $0) })) {
                Text("None (show the slate text)").tag("")
                ForEach(model.props.filter(\.isVideo)) { Text($0.name).tag($0.id) }
            }
            Text("Scenes with a Slate slot show this text, or play the intro video instead when one is picked.").font(.caption).foregroundStyle(Theme.muted)
        }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
