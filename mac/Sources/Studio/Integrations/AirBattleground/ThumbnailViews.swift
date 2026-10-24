// YouTube thumbnail panel: Go Live sheet (Admin YouTube) and the Outputs page.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Preview, source picker, "Set automatically when going live", "Update thumbnail now" (live), "Save thumbnail…", status.
struct ThumbnailPanelContent: View {
    @Environment(AppModel.self) var model
    /// Go Live sheet: smaller preview, no live-only controls
    var compact = false
    @State private var saving = false

    private enum Pick: Hashable { case builtin, scene(String), file, upload }

    var body: some View {
        let t = model.thumbnail
        HStack(alignment: .top, spacing: 12) {
            preview(t).frame(width: compact ? 144 : 240, height: compact ? 81 : 135)
            VStack(alignment: .leading, spacing: 6) {
                Picker("Picture", selection: pickBinding(t)) {
                    Text("\(AdvancedStudioPreset.thumbnailName) (default)").tag(Pick.builtin)
                    if !t.pickableScenes.isEmpty {
                        Divider()
                        ForEach(t.pickableScenes) { s in Text(s.name).tag(Pick.scene(s.id)) }
                    }
                    Divider()
                    if case .file(let p) = t.settings.source { Text(URL(fileURLWithPath: p).lastPathComponent).tag(Pick.file) }
                    Text("Upload image…").tag(Pick.upload)
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: compact ? 220 : 260)
                Toggle("Set automatically when going live", isOn: Binding(get: { t.settings.autoSet }, set: { t.settings.autoSet = $0 }))
                    .toggleStyle(.checkbox).font(Theme.Font.caption)
                HStack(spacing: 6) {
                    if !compact && t.isLive {
                        Button { Task { await t.updateNow() } } label: { Label(t.uploading ? "Updating…" : "Update thumbnail now", systemImage: "arrow.up.circle") }
                            .controlSize(.small).disabled(t.uploading)
                    }
                    Button { save(t) } label: { Label("Save thumbnail…", systemImage: "square.and.arrow.down") }
                        .controlSize(.small).disabled(saving)
                        .help("Export the 1280x720 JPEG to upload it yourself in YouTube Studio")
                }
                statusLine(t)
            }
            Spacer(minLength: 0)
        }
        .task(id: t.settings.source) { await t.refreshPreview() }
        .onChange(of: model.sceneRevision) { _, _ in Task { await t.refreshPreview() } }
    }

    @ViewBuilder private func preview(_ t: ThumbnailController) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black)
            if let img = t.preview {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let e = t.previewError {
                Text(e).font(Theme.Font.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.center).padding(6)
            }
            if t.rendering { ProgressView().controlSize(.small) }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
        .overlay(alignment: .topTrailing) {
            Button { Task { await t.refreshPreview() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).padding(4).background(.black.opacity(0.55), in: Circle()).padding(4)
                .help("Re-render with the current match data")
        }
        .accessibilityLabel("YouTube thumbnail preview")
    }

    @ViewBuilder private func statusLine(_ t: ThumbnailController) -> some View {
        switch t.status {
        case .idle:
            if let b = t.previewBytes {
                Text("1280x720 JPEG · \(formatBytes(Int64(b)))").font(Theme.Font.caption).foregroundStyle(Theme.faint)
            }
        case .working(let s):
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(s) }.font(Theme.Font.caption).foregroundStyle(Theme.muted)
        case .set(let url, _):
            Label("Thumbnail set ✓", systemImage: "checkmark.circle.fill").font(Theme.Font.caption).foregroundStyle(Theme.ok)
                .help(url ?? "YouTube thumbnail set")
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        case .unsupported:
            Text(ThumbnailReply.unsupported.message).font(Theme.Font.caption).foregroundStyle(Theme.muted)
        }
    }

    private func pickBinding(_ t: ThumbnailController) -> Binding<Pick> {
        Binding(get: {
            switch t.settings.source {
            case .builtin: .builtin
            case .scene(let id): .scene(id)
            case .file: .file
            }
        }, set: { p in
            switch p {
            case .builtin: t.settings.source = .builtin
            case .scene(let id): t.settings.source = .scene(id)
            case .file: break
            case .upload: chooseFile(t)
            }
        })
    }

    private func chooseFile(_ t: ThumbnailController) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg]
        p.allowsMultipleSelection = false
        p.message = "Choose a PNG or JPG (it is scaled / cropped to 1280x720)"
        if p.runModal() == .OK, let url = p.url { t.useFile(url) }
    }

    private func save(_ t: ThumbnailController) {
        saving = true
        Task {
            defer { saving = false }
            guard let data = await t.jpegForSave() else { model.errorMessage = "Couldn't make the thumbnail image."; return }
            let p = NSSavePanel()
            p.allowedContentTypes = [.jpeg]
            p.nameFieldStringValue = Self.filename(model.abg.link?.eventTitle)
            p.message = "Upload this in YouTube Studio if AirBattleground can't set it."
            guard p.runModal() == .OK, let url = p.url else { return }
            do { try data.write(to: url) } catch { model.errorMessage = "Couldn't save the thumbnail: \(error.localizedDescription)" }
        }
    }
    static func filename(_ title: String?) -> String {
        let base = (title ?? "").components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return (base.isEmpty ? "youtube-thumbnail" : "\(base)-thumbnail") + ".jpg"
    }
}

/// Outputs page panel.
struct ThumbnailPanel: View {
    var body: some View {
        Panel(title: "YouTube thumbnail", icon: "photo") {
            Text("Set on the admin's YouTube broadcast through AirBattleground when you go live with Admin YouTube.")
                .font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ThumbnailPanelContent()
        }
    }
}
