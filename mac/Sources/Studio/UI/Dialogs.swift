import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

func qrImage(_ s: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator(); f.message = Data(s.utf8); f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let rep = NSCIImageRep(ciImage: out); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
}

struct AddPhoneDialog: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var name = ""
    @State var created: PairingInfo?
    @State var copied = false
    @State var working = false
    @State var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let c = created {
                Text("Connect \(c.device.name)").font(.title2.bold())
                Text("The phone must be on the same Wi-Fi as this Mac.").foregroundStyle(Theme.muted)
                HStack { Spacer()
                    if let img = qrImage(c.pairURL) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer() }
                ForEach(Array(["Open 7XEN Stream on the phone", "Tap Scan QR and point it at this code", "Tap Start streaming"].enumerated()), id: \.offset) { i, s in
                    HStack { Text("\(i + 1)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22).background(Theme.accent.opacity(0.25), in: Circle()); Text(s) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't scan? Type this pairing code in the app. It's shown only once.").font(.caption).foregroundStyle(Theme.muted)
                    HStack {
                        Text(c.key).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.key, forType: .string); copied = true } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }.controlSize(.small)
                    }
                }.padding(10).background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8))
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Add a phone").font(.title2.bold())
                Text("Give it a name you'll recognise, like \"Player cam 1\" or \"Desk phone\".").foregroundStyle(Theme.muted)
                TextField("Player cam 1", text: $name).textFieldStyle(.roundedBorder).onSubmit(submit)
                if let e = error { Text(e).font(.caption).foregroundStyle(Theme.program) }
                HStack { Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button { submit() } label: { Label(working ? "Adding…" : "Add phone", systemImage: "iphone") }
                        .keyboardShortcut(.defaultAction).disabled(working || name.trimmingCharacters(in: .whitespaces).count < 2) }
            }
        }.padding(20).frame(width: 420)
    }
    func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.count >= 2, !working else { error = n.count < 2 ? "At least 2 characters" : nil; return }
        working = true
        Task {
            do { created = try await model.services.createDevice(name: n); model.refresh() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct StreamKeyDialog: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var kind: Destination.Kind = .youtube
    @State var name = "My YouTube"
    @State var url = "rtmp://a.rtmp.youtube.com/live2"
    @State var key = ""
    static func preset(_ k: Destination.Kind) -> (label: String, url: String) {
        switch k { case .youtube: ("YouTube", "rtmp://a.rtmp.youtube.com/live2"); case .facebook: ("Facebook", "rtmps://live-api-s.facebook.com:443/rtmp/"); case .custom: ("Custom RTMP", "") }
    }
    var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && !key.trimmingCharacters(in: .whitespaces).isEmpty && url.lowercased().hasPrefix("rtmp") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a stream key").font(.title2.bold())
            Text(kind == .youtube ? "In YouTube Studio open Go live → Stream, copy the stream key and paste it here."
                 : kind == .facebook ? "In Facebook Live Producer choose Streaming software, copy the stream key and paste it here."
                 : "Paste the server URL and stream key from your platform.").foregroundStyle(Theme.muted)
            Picker("Platform", selection: $kind) {
                ForEach([Destination.Kind.youtube, .facebook, .custom], id: \.self) { Text(Self.preset($0).label).tag($0) }
            }.onChange(of: kind) { _, k in url = Self.preset(k).url; name = k == .custom ? "My channel" : "My \(Self.preset(k).label)" }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if kind != .youtube { TextField("rtmp://…", text: $url).textFieldStyle(.roundedBorder) }
            SecureField("Stream key  xxxx-xxxx-xxxx-xxxx", text: $key).textFieldStyle(.roundedBorder)
            Text("Kept on this Mac. Only used to send your show there.").font(.caption).foregroundStyle(Theme.muted)
            HStack { Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save stream key") {
                    model.saveDestination(Destination(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces), kind: kind, url: url.trimmingCharacters(in: .whitespaces), key: key.trimmingCharacters(in: .whitespaces)))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid) }
        }.padding(20).frame(width: 460)
    }
}
