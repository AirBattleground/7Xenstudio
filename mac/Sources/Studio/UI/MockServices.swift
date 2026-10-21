import Foundation
import AppKit
import CoreText

/// Standalone fake backend so the UI runs without the other modules.
@MainActor
final class MockServices: StudioServices {
    var studioName = "7XEN Studio"
    var lanURL = "http://192.168.1.20:8080"
    private var devs: [DeviceInfo] = [
        DeviceInfo(id: "d1", name: "Player cam 1", online: true, streaming: true, videoReady: true, battery: 82, model: "iPhone 15"),
        DeviceInfo(id: "d2", name: "Desk phone", online: true, streaming: false, videoReady: false, battery: 55, model: "Pixel 8"),
    ]
    private var sc: [Scene] = [
        Scene(id: "s1", name: "Intro", layout: .full, slots: [.slate]),
        Scene(id: "s2", name: "Game + Host", layout: .desk, slots: [.device(id: "d1"), .device(id: "d2")]),
        Scene(id: "s3", name: "Side by side", layout: .side, slots: [.device(id: "d1"), .device(id: "d2")]),
        Scene(id: "s4", name: "PiP", layout: .pip, slots: [.device(id: "d1"), .device(id: "d2")]),
    ]
    var programSceneID: String? = "s1"
    var previewSceneID: String? = "s2"
    var overlays = Overlays()
    private var dests: [Destination] = []
    private var live = false, liveSince: Date?
    private var recs: [RecordingInfo] = []

    func setStudioName(_ n: String) async throws { studioName = n }
    func devices() -> [DeviceInfo] { devs }
    func createDevice(name: String) async throws -> PairingInfo {
        let d = DeviceInfo(id: UUID().uuidString, name: name, online: false)
        devs.append(d)
        let key = String(UUID().uuidString.prefix(12)).lowercased()
        return PairingInfo(device: d, pairURL: "7xen://pair?host=\(lanURL)&key=\(key)&name=\(studioName)", key: key)
    }
    func deleteDevice(id: String) async { devs.removeAll { $0.id == id } }
    func scenes() -> [Scene] { sc }
    func saveScene(_ s: Scene) async { if let i = sc.firstIndex(where: { $0.id == s.id }) { sc[i] = s } else { sc.append(s) } }
    func deleteScene(id: String) async { sc.removeAll { $0.id == id } }
    func setPreview(sceneID: String) { previewSceneID = sceneID }
    func take(_ t: TransitionKind) { programSceneID = previewSceneID }
    func destinations() -> [Destination] { dests }
    func saveDestination(_ d: Destination) async { if let i = dests.firstIndex(where: { $0.id == d.id }) { dests[i] = d } else { dests.append(d) } }
    func deleteDestination(id: String) async { dests.removeAll { $0.id == id } }
    func goLive(record: Bool, destinationIDs: [String]) async throws { live = true; liveSince = Date() }
    func stopLive() async { live = false; liveSince = nil }
    func stats() -> StudioStats {
        StudioStats(fps: live ? 59.8 : 0, kbps: live ? 11_800 : 0, dropped: 0, live: live, liveSince: liveSince,
                    outputs: live ? dests.map { OutputHealth(id: $0.id, name: $0.name, ok: true) } : [])
    }
    func recordings() -> [RecordingInfo] { recs }
    func disk() -> DiskInfo { DiskInfo(freeBytes: 240 << 30, totalBytes: 500 << 30) }
    func deleteRecording(file: String) async { recs.removeAll { $0.file == file } }
    func shutdown() async {}

    func frame(_ m: MonitorKind) -> MonitorFrame? {
        let id = m == .program ? programSceneID : previewSceneID
        guard let s = sc.first(where: { $0.id == id }) else { return nil }
        let w = 640, h = 360
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let t = Date().timeIntervalSinceReferenceDate
        ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let n = max(s.slots.count, 1)
        let rects: [CGRect]
        switch s.layout {
        case .full: rects = [CGRect(x: 0, y: 0, width: w, height: h)]
        case .side: rects = [CGRect(x: 10, y: 80, width: 305, height: 200), CGRect(x: 325, y: 80, width: 305, height: 200)]
        case .pip: rects = [CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: 440, y: 20, width: 180, height: 100)]
        case .desk: rects = [CGRect(x: 10, y: 150, width: 440, height: 200), CGRect(x: 460, y: 150, width: 170, height: 200)]
        case .trio: rects = [CGRect(x: 10, y: 10, width: 420, height: 340), CGRect(x: 440, y: 185, width: 190, height: 165), CGRect(x: 440, y: 10, width: 190, height: 165)]
        }
        for (i, r) in rects.prefix(n).enumerated() {
            let hue = (Double(i) * 0.23 + 0.55 + sin(t / 3) * 0.05).truncatingRemainder(dividingBy: 1)
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.5, alpha: 1).cgColor); ctx.fill(r)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3)); ctx.stroke(r)
            let bx = r.minX + (r.width - 20) * (0.5 + 0.5 * sin(t * 1.5 + Double(i)))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.8)); ctx.fillEllipse(in: CGRect(x: bx, y: r.midY - 10, width: 20, height: 20))
        }
        let str = NSAttributedString(string: s.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white])
        ctx.textPosition = CGPoint(x: 16, y: 16)
        CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
        return ctx.makeImage().map { .image($0) }
    }
}
