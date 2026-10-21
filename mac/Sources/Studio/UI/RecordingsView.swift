import SwiftUI
import AVKit

struct RecordingsView: View {
    @Environment(AppModel.self) var model
    @State var playing: RecordingInfo?
    @State var deleting: RecordingInfo?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recordings").font(.title.bold())
                Text("Every show recorded on this Mac. Play, reveal or delete them here.").foregroundStyle(Theme.muted)
                let d = model.disk
                if d.totalBytes > 0 {
                    let used = Double(d.totalBytes - d.freeBytes) / Double(d.totalBytes)
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text("\(formatBytes(d.freeBytes)) free of \(formatBytes(d.totalBytes))").font(.system(size: 13, weight: .semibold))
                            ProgressView(value: used)
                        }
                        if d.freeBytes < 10 << 30 { Chip(text: "Low on space", color: Theme.warn) }
                    }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                if model.recordings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(Theme.muted)
                        Text("No recordings yet").font(.headline)
                        Text("Turn on \"Record on this Mac\" in Outputs, then Go Live.").foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity).padding(40)
                }
                ForEach(model.recordings) { r in
                    HStack(spacing: 12) {
                        Image(systemName: "film").frame(width: 40, height: 40).background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(r.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                            Text("\(r.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(r.duration)) · \(formatBytes(r.sizeBytes))").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if r.isRecording { Chip(text: "● Recording now", color: Theme.program, filled: true) }
                        Button { playing = r } label: { Label("Play", systemImage: "play.fill") }.controlSize(.small)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([r.url]) } label: { Label("Reveal", systemImage: "folder") }.controlSize(.small)
                        Button { deleting = r } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(r.isRecording)
                    }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(20)
        }
        .sheet(item: $playing) { r in
            VStack(alignment: .trailing) {
                RecordingPlayer(url: r.url).frame(width: 840, height: 473)
                Button("Close") { playing = nil }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete recording", role: .destructive) { if let r = deleting { model.deleteRecording(r) } }
        } message: { Text("\(deleting?.title ?? "") (\(formatBytes(deleting?.sizeBytes ?? 0))) is removed from this Mac for good.") }
    }
}

/// AppKit AVPlayerView (the SwiftUI VideoPlayer crashes at view construction); the player is created once and torn down on dismiss.
struct RecordingPlayer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        let p = AVPlayer(url: url)
        v.player = p
        p.play()
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause(); v.player?.replaceCurrentItem(with: nil); v.player = nil
    }
}
