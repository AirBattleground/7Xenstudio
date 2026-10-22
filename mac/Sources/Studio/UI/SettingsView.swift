import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) var model
    @State var name = ""
    @State var showKeySheet = false
    var body: some View {
        @Bindable var m = model
        Form {
            Section("Studio") {
                HStack {
                    TextField("Studio name", text: $name).onSubmit { model.rename(name) }
                    Button("Save") { model.rename(name) }.disabled(name.trimmingCharacters(in: .whitespaces).count < 2 || name == model.studioName)
                }
                Text("Phones show this name when they connect.").font(.caption).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                LabeledContent("Phones connect to") {
                    HStack { Text(model.lanURL).textSelection(.enabled).monospaced()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.lanURL, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless) }
                }
                LabeledContent("Encoder", value: model.stats.encoder)
                LabeledContent("Output", value: "\(studioWidth)×\(studioHeight) @ \(defaultFPS) fps, \(model.videoKbps / 1000) Mbps, BT.709")
            }
            Section("Video quality") {
                VideoQualityControls()
                Picker("Vivid enhancement", selection: $m.vividLevel) { ForEach(VividLevel.allCases, id: \.self) { Text($0.label).tag($0) } }
                Text("Mild saturation, contrast and edge sharpening on the final picture. Useful for flat-looking screen captures; the monitors show it live.")
                    .font(.caption).foregroundStyle(.secondary)
                let services = model.services
                MonitorSurface(provider: { services.frame(.program) }, serial: { services.frameSerial(.program) }, fps: 15)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit).frame(maxWidth: 360).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Section("Slate") {
                TextField("Starting soon", text: Binding(get: { model.slateText }, set: { model.setSlateText($0) }))
                Picker("Intro video", selection: Binding(get: { model.introPropId ?? "" }, set: { model.setIntroProp($0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(model.props.filter(\.isVideo)) { Text($0.name).tag($0.id) }
                }
                Text("Add videos in the Props tab.").font(.caption).foregroundStyle(.secondary)
            }
            ABGSettingsSection()
            Section("Stream keys") {
                if model.destinations.isEmpty { Text("No stream keys yet.").foregroundStyle(.secondary) }
                ForEach(model.destinations) { d in
                    HStack {
                        Label(d.name, systemImage: "key"); Spacer()
                        Text(d.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button(role: .destructive) { model.removeDestination(d) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(model.isLive)
                    }
                }
                Button { showKeySheet = true } label: { Label("Add stream key", systemImage: "plus") }
            }
        }
        .formStyle(.grouped).frame(minWidth: 520, minHeight: 600)
        .sheet(isPresented: $showKeySheet) { StreamKeyDialog().environment(model) }
        .onAppear { name = model.studioName }
    }
}
