import Testing
import Foundation
import CoreGraphics
@testable import Studio

@Suite("Props") struct PropsTests {
    @Test func catalogSize() {
        #expect(PropsCatalog.all.count >= 120)
        #expect(Set(PropsCatalog.all.map(\.id)).count == PropsCatalog.all.count)
        for c in PropCategory.allCases { #expect(!PropsCatalog.assets(in: c).isEmpty) }
    }

    @Test func everyAssetRendersNonEmpty() {
        for a in PropsCatalog.all {
            let img = a.image(scale: 1)
            #expect(img.width == Int(ceil(a.size.width)) && img.height == Int(ceil(a.size.height)), "\(a.id) size")
            // sample alpha on a coarse grid
            guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { Issue.record("\(a.id) no data"); continue }
            let bpr = img.bytesPerRow
            var opaque = 0, total = 0
            for y in stride(from: 0, to: img.height, by: max(1, img.height / 24)) {
                for x in stride(from: 0, to: img.width, by: max(1, img.width / 24)) { total += 1; if p[y * bpr + x * 4 + 3] > 8 { opaque += 1 } }
            }
            #expect(opaque > 0, "\(a.id) is fully transparent")
            #expect(opaque < total || a.category != .icons, "\(a.id) icon fully opaque")
        }
    }

    @Test func themesRestyleAssets() {
        let a = PropsCatalog.byID["frame.cornercut"]!
        let e = a.image(scale: 1, theme: .ember), t = a.image(scale: 1, theme: .toxic)
        #expect(e.dataProvider?.data != t.dataProvider?.data)
        #expect(PropTheme.all.count == 5)
    }

    @Test func diskCacheWritesPNG() {
        let a = PropsCatalog.byID["icon.skull"]!
        let url = a.fileURL(scale: 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.contains("props-builtin"))
    }

    @Test func templatesRoundTripAndResolve() throws {
        #expect(Templates.all.count >= 10)
        for t in Templates.all {
            for theme in [PropTheme.ember, .ice] {
                let s = try #require(Templates.make(t.id, theme: theme), "\(t.id)")
                let data = try JSONEncoder().encode(s)
                let back = try JSONDecoder().decode(LayerScene.self, from: data)
                #expect(back == s, "\(t.id) round trip")
                #expect(!s.layers.isEmpty)
                var ids = Set<String>(); s.forEachLayer { ids.insert($0.id) }
                var n = 0; s.forEachLayer { _ in n += 1 }
                #expect(ids.count == n, "\(t.id) unique layer ids")
                // every builtin image exists
                s.forEachLayer { l in if case .image(let i) = l.kind, let b = i.builtin { #expect(PropsCatalog.byID[b] != nil, "\(t.id): missing \(b)") } }
                // placeholders resolve
                let vars = SceneVariables(s.variableDefaults)
                for key in Templates.placeholders(in: s) {
                    #expect(vars[key] != nil, "\(t.id): unresolved {{\(key)}}")
                    #expect(!vars.resolve("{{\(key)}}").isEmpty)
                }
            }
        }
    }

    @Test func templatePreviewRenders() {
        let s = Templates.make("bgp.maingame")!
        let img = TemplatePreview.render(s, width: 320)
        #expect(img.width == 320 && img.height == 180)
    }

    @Test func effectPresetsCoverAllThemes() {
        for t in PropTheme.all { #expect(EffectPresets.all(t).count >= 15) }
        #expect(!TextPresets.headlineFont.isEmpty)
    }

    @Test func contactSheetsForReview() throws {
        try FileManager.default.createDirectory(atPath: "/tmp/props-shots/templates", withIntermediateDirectories: true)
        for t in Templates.all {
            let img = TemplatePreview.render(Templates.make(t.id)!, width: 960)
            #expect(img.width == 960)
        }
    }
}
