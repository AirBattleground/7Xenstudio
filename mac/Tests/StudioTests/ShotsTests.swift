import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Studio

/// Dev-only: SHOTS=1 renders every template in every theme to /tmp/scene-shots (and a contact sheet per theme).
struct ShotsTests {
    static func writePNG(_ img: CGImage, _ path: String) {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
    @Test func renderAllTemplates() {
        guard ProcessInfo.processInfo.environment["SHOTS"] != nil else { return }
        let e = StudioEngine()
        let only = ProcessInfo.processInfo.environment["SHOTS_THEME"]
        for th in PropTheme.all where only == nil || only == th.id {
            for t in Templates.all {
                guard let s = Templates.make(t.id, theme: th) else { continue }
                let vars = SceneVariables(Templates.defaultVariables)
                if let img = e.renderStill(s, size: CGSize(width: 1280, height: 720), variables: vars, time: 4) {
                    Self.writePNG(img, "/tmp/scene-shots/\(t.id)-\(th.id).png")
                }
            }
        }
    }
}
