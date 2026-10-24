// Built-in "Battleground Pro" prop pack: registry, accent themes and on-disk cache.
// Everything is drawn procedurally with CoreGraphics / CoreText. No external assets.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Accent colour set that restyles every asset and template (Ember, Toxic, Ice, Crimson, Gold).
struct PropTheme: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var primary: UInt32   // main accent
    var hot: UInt32       // deep / danger accent
    var glow: UInt32      // bright highlight
    var isDefault: Bool { id == PropTheme.ember.id }

    static let ember   = PropTheme(id: "ember",   name: "Ember",       primary: 0xFF7A1A, hot: 0xE5261B, glow: 0xFFC247)
    static let toxic   = PropTheme(id: "toxic",   name: "Toxic Green", primary: 0x7CFF2B, hot: 0x14A83C, glow: 0xE4FF6B)
    static let ice     = PropTheme(id: "ice",     name: "Ice Blue",    primary: 0x35B6FF, hot: 0x1E55FF, glow: 0xBFF0FF)
    static let crimson = PropTheme(id: "crimson", name: "Crimson",     primary: 0xFF2D3D, hot: 0xA80016, glow: 0xFF9A8A)
    static let gold    = PropTheme(id: "gold",    name: "Gold",        primary: 0xFFC21A, hot: 0xD9820A, glow: 0xFFF1A6)
    static let all: [PropTheme] = [.ember, .toxic, .ice, .crimson, .gold]
    static func named(_ id: String) -> PropTheme { all.first { $0.id == id } ?? .ember }
}

enum PropCategory: String, CaseIterable, Sendable, Identifiable {
    case frames, hud, icons, banners, textures, backgrounds, fire, stingers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .frames: "Frames & Borders"; case .hud: "HUD"; case .icons: "Battleground Icons"
        case .banners: "Banners & Name Plates"; case .textures: "Textures & Overlays"
        case .backgrounds: "Backgrounds"; case .fire: "Fire & FX"; case .stingers: "Stingers & Transitions"
        }
    }
    var symbol: String {
        switch self {
        case .frames: "rectangle.dashed"; case .hud: "scope"; case .icons: "shield.lefthalf.filled"
        case .banners: "rectangle.and.text.magnifyingglass"; case .textures: "circle.grid.3x3"
        case .backgrounds: "photo"; case .fire: "flame"; case .stingers: "bolt.horizontal"
        }
    }
}

/// Drawing context handed to renderers: top-left origin, design units, `a` is the active theme.
struct PCtx {
    let g: CGContext
    let w: CGFloat
    let h: CGFloat
    let a: PropTheme
    let scale: CGFloat
    var rect: CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
}

struct BuiltinAsset: Identifiable, Sendable {
    let id: String
    let name: String
    let category: PropCategory
    let tags: [String]
    let size: CGSize
    /// Large full-frame art is only rendered at 1x.
    var maxScale: CGFloat = 2
    /// Whether the art uses theme colours (false = neutral texture, theme-independent).
    var themed: Bool = true
    let renderer: @Sendable (PCtx) -> Void

    func image(scale: CGFloat = 1, theme: PropTheme = .ember) -> CGImage {
        BuiltinAssets.render(self, scale: scale, theme: theme)
    }
    /// PNG on disk (written on demand). Engine agent can load layers from this path.
    func fileURL(scale: CGFloat = 1, theme: PropTheme = .ember) -> URL {
        BuiltinAssets.fileURL(self, scale: scale, theme: theme)
    }
}

enum BuiltinAssets {
    static let version = 4
    static var all: [BuiltinAsset] { PropsCatalog.all }
    static func asset(_ id: String) -> BuiltinAsset? { PropsCatalog.byID[id] }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("7XEN Studio/props-builtin", isDirectory: true)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mem: [String: CGImage] = [:]

    static func effectiveScale(_ a: BuiltinAsset, _ s: CGFloat) -> CGFloat { min(max(1, s.rounded()), a.maxScale) }

    static func render(_ a: BuiltinAsset, scale: CGFloat, theme: PropTheme) -> CGImage {
        let sc = effectiveScale(a, scale)
        let th = a.themed ? theme : .ember
        let key = "\(a.id)|\(sc)|\(th.id)"
        lock.lock(); if let m = mem[key] { lock.unlock(); return m }; lock.unlock()
        let img = draw(a, scale: sc, theme: th)
        lock.lock(); mem[key] = img; lock.unlock()
        return img
    }

    static func draw(_ a: BuiltinAsset, scale: CGFloat, theme: PropTheme) -> CGImage {
        let pw = max(1, Int(ceil(a.size.width * scale))), ph = max(1, Int(ceil(a.size.height * scale)))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: scale, y: -scale)
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
        a.renderer(PCtx(g: ctx, w: a.size.width, h: a.size.height, a: theme, scale: scale))
        return ctx.makeImage()!
    }

    static func fileURL(_ a: BuiltinAsset, scale: CGFloat, theme: PropTheme) -> URL {
        let sc = effectiveScale(a, scale)
        let th = a.themed ? theme : .ember
        let dir = directory.appendingPathComponent("v\(version)", isDirectory: true)
        let name = "\(a.id)\(th.isDefault ? "" : "@\(th.id)")\(sc > 1 ? "@2x" : "").png"
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writePNG(render(a, scale: sc, theme: th), to: url)
        return url
    }

    /// Pre-renders the whole pack (1x, default theme) in the background on first launch; stamps a version file.
    static func prewarm() {
        let stamp = directory.appendingPathComponent("version.txt")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == "\(version)" { return }
        DispatchQueue.global(qos: .utility).async {
            for a in PropsCatalog.all { _ = fileURL(a, scale: 1, theme: .ember) }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "\(version)".write(to: stamp, atomically: true, encoding: .utf8)
        }
    }

    static func writePNG(_ img: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
}

enum PropsCatalog {
    static let categories: [PropCategory] = PropCategory.allCases
    static let all: [BuiltinAsset] = {
        var a: [BuiltinAsset] = []
        a += frameAssets(); a += hudAssets(); a += iconAssets(); a += bannerAssets()
        a += textureAssets(); a += backgroundAssets(); a += fireAssets(); a += stingerAssets()
        a += AdvancedStudioAssets.all()      // OPUS Advanced Studio: AirBattleground logos + luxury kit
        return a
    }()
    static let byID: [String: BuiltinAsset] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    static func assets(in c: PropCategory) -> [BuiltinAsset] { all.filter { $0.category == c } }
    static func search(_ q: String) -> [BuiltinAsset] {
        let t = q.lowercased().split(separator: " ").map(String.init)
        return all.filter { a in t.allSatisfy { w in a.name.lowercased().contains(w) || a.tags.contains { $0.contains(w) } || a.id.contains(w) } }
    }
}

/// Registry helper used by the category files.
func asset(_ id: String, _ name: String, _ cat: PropCategory, _ w: CGFloat, _ h: CGFloat, tags: [String] = [],
           maxScale: CGFloat = 2, themed: Bool = true, _ r: @escaping @Sendable (PCtx) -> Void) -> BuiltinAsset {
    BuiltinAsset(id: id, name: name, category: cat, tags: tags, size: CGSize(width: w, height: h), maxScale: maxScale, themed: themed, renderer: r)
}
