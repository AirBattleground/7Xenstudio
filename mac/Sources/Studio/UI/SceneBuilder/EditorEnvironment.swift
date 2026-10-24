// Glue between the editor model and the app: prop images, imports, library drops, persistence, ABG variables.
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Stores layer scenes as JSON files (one per scene id). The studio engine reads the same files / is notified through `onSave`.
final class LayerSceneRepository: @unchecked Sendable {
    static let shared = LayerSceneRepository()
    let dir: URL
    /// Called (on any thread) after a scene is written; the engine bridge can hook this to push the scene live.
    var onSave: (@Sendable (LayerScene) -> Void)?
    private let lock = NSLock()
    init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("7XEN Studio/layer-scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }
    func url(_ id: String) -> URL { dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json") }
    func load(_ id: String) -> LayerScene? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(LayerScene.self, from: d)
    }
    func save(_ s: LayerScene) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: url(s.id), options: .atomic) }
        onSave?(s)
    }
    func delete(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }
    /// "My Templates"
    var templatesDir: URL {
        let d = dir.appendingPathComponent("my-templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func myTemplates() -> [LayerScene] {
        let files = (try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap { try? JSONDecoder().decode(LayerScene.self, from: Data(contentsOf: $0)) }
    }
    func saveTemplate(_ s: LayerScene) {
        var t = s; t.id = UUID().uuidString; t.migratedFrom = nil
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(t) { try? d.write(to: templatesDir.appendingPathComponent(t.id + ".json"), options: .atomic) }
    }
    func deleteTemplate(_ id: String) { try? FileManager.default.removeItem(at: templatesDir.appendingPathComponent(id + ".json")) }
}

@MainActor
final class SceneEditorEnvironment {
    let app: AppModel
    let repo = LayerSceneRepository.shared
    var theme: PropTheme = .ember
    private var imageCache: [String: CGImage] = [:]

    init(app: AppModel) { self.app = app }

    // MARK: rasteriser environment
    func rasterEnv(for scene: LayerScene, variables: SceneVariables) -> RasterEnv {
        var e = RasterEnv()
        e.variables = variables; e.variableDefaults = scene.variableDefaults; e.theme = theme
        var ids = Set<String>()
        func collect(_ ls: [Layer]) {
            for l in ls {
                switch l.kind {
                case .image(let i): if let p = i.propId { ids.insert(p) }
                case .group(let c): collect(c)
                default: break
                }
                if let p = l.mask.propId { ids.insert(p) }
            }
        }
        collect(scene.layers)
        if let p = scene.background.propId { ids.insert(p) }
        for id in ids { if let img = propImage(id) { e.propImages[id] = img } }
        for d in app.devices { e.sourceNames[.device(id: d.id)] = d.name }
        e.sourceNames[.camera] = "Webcam"; e.sourceNames[.slate] = "Slate"
        for p in app.props { e.sourceNames[.prop(id: p.id)] = p.name; e.sourceNames[.image(id: p.id)] = p.name }
        return e
    }
    func propImage(_ id: String) -> CGImage? {
        if let c = imageCache[id] { return c }
        guard let info = app.props.first(where: { $0.id == id }) else { return nil }
        if !info.isVideo, let src = CGImageSourceCreateWithURL(info.url as CFURL, nil),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary) {
            imageCache[id] = img; return img
        }
        if let t = app.services.propThumbnail(id: id) { imageCache[id] = t; return t }
        return nil
    }

    // MARK: library actions
    func addFromLibrary(kind: String, value: String, at p: CGPoint, into model: SceneEditorModel) {
        let canvas = model.scene.canvas
        switch kind {
        case "builtin":
            var l = LayerFactory.image(builtin: value, theme: theme, canvas: canvas)
            if let a = BuiltinAssets.asset(value), a.category == .backgrounds || (l.transform.w >= Double(canvas.w) * 0.99 && l.transform.h >= Double(canvas.h) * 0.99) {
                model.add(l, label: "Add \(a.name)")
            } else {
                l.transform.x = p.x - l.transform.w / 2; l.transform.y = p.y - l.transform.h / 2
                model.add(l, label: "Add \(l.name)")
            }
        case "prop":
            guard let info = app.props.first(where: { $0.id == value }) else { return }
            var aspect = 16.0 / 9
            if let img = propImage(value) { aspect = Double(img.width) / Double(max(1, img.height)) }
            let l = LayerFactory.image(prop: value, name: info.name, aspect: aspect, canvas: canvas)
            model.add(l, centeredAt: p, label: "Add \(info.name)")
        case "tool":
            switch value {
            case "rect": model.add(LayerFactory.shape(.rect, canvas: canvas), centeredAt: p, label: "Add rectangle")
            case "rounded": model.add(LayerFactory.shape(.roundedRect, canvas: canvas), centeredAt: p, label: "Add rectangle")
            case "ellipse": model.add(LayerFactory.shape(.ellipse, canvas: canvas), centeredAt: p, label: "Add ellipse")
            case "polygon": model.add(LayerFactory.shape(.polygon, canvas: canvas), centeredAt: p, label: "Add polygon")
            case "star": model.add(LayerFactory.star(canvas: canvas), centeredAt: p, label: "Add star")
            case "line": model.add(LayerFactory.shape(.line, canvas: canvas), centeredAt: p, label: "Add line")
            case "text": model.add(LayerFactory.text(canvas: canvas), centeredAt: p, label: "Add text")
            case "heading": model.add(LayerFactory.text("{{matchTitle}}", canvas: canvas, size: 120), centeredAt: p, label: "Add title")
            case "vs": model.add(LayerFactory.text("{{team1}}  VS  {{team2}}", canvas: canvas, size: 72), centeredAt: p, label: "Add VS text")
            case "teamboard": model.add(LayerFactory.teamBoard(canvas: canvas), label: "Add team status board")
            default:
                if let fx = LayerFactory.effectPresets.first(where: { $0.id == value }) {
                    var l = LayerFactory.effect(fx, canvas: canvas)
                    if fx.frame != nil { l.transform.x = p.x - l.transform.w / 2; l.transform.y = p.y - l.transform.h / 2 }
                    model.add(l, label: "Add \(fx.name)")
                }
            }
        case "source":
            if let d = value.data(using: .utf8), let ref = try? JSONDecoder().decode(SourceRef.self, from: d) {
                model.add(LayerFactory.source(ref, name: sourceName(ref), canvas: canvas, portrait: { if case .device = ref { return true }; return false }()), label: "Add source")
            }
        default: break
        }
    }
    func sourceName(_ r: SourceRef) -> String {
        switch r {
        case .device(let id): return app.devices.first { $0.id == id }?.name ?? "Phone"
        case .camera: return "Webcam"
        case .slate: return "Slate"
        case .prop(let id), .image(let id): return app.props.first { $0.id == id }?.name ?? "Prop"
        case .web: return "Web image"
        }
    }
    func addSource(_ ref: SourceRef, into model: SceneEditorModel) {
        if let d = try? JSONEncoder().encode(ref), let s = String(data: d, encoding: .utf8) {
            addFromLibrary(kind: "source", value: s, at: .zero, into: model)
        }
    }

    /// Import files as props (SVG is rasterised to PNG first), then drop them on the canvas.
    func importFiles(_ urls: [URL], at p: CGPoint?, into model: SceneEditorModel) {
        Task { @MainActor in
            let before = Set(app.props.map(\.id))
            var prepared: [URL] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource(); defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if u.pathExtension.lowercased() == "svg", let png = rasteriseSVG(u) { prepared.append(png) }
                else {
                    // copy out of the security scope so the async add can read it
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent)
                    if (try? FileManager.default.copyItem(at: u, to: tmp)) != nil { prepared.append(tmp) } else { prepared.append(u) }
                }
            }
            var errs: [String] = []
            for u in prepared { do { try await app.services.addProp(url: u) } catch { errs.append("\(u.lastPathComponent): \(error.localizedDescription)") } }
            app.refresh()
            if !errs.isEmpty { app.errorMessage = errs.joined(separator: "\n") }
            let fresh = app.props.filter { !before.contains($0.id) }
            var at = p ?? CGPoint(x: Double(model.scene.canvas.w) / 2, y: Double(model.scene.canvas.h) / 2)
            for f in fresh {
                addFromLibrary(kind: "prop", value: f.id, at: at, into: model)
                at.x += 30; at.y += 30
            }
        }
    }
    func rasteriseSVG(_ url: URL) -> URL? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let scale: CGFloat = max(1, 1024 / max(img.size.width, img.size.height, 1))
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        try? png.write(to: out)
        return out
    }
    func importPanel(into model: SceneEditorModel) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = propContentTypes + [UTType.svg]
        p.message = "Choose PNG, JPG, SVG, GIF or MP4 files to use as props"
        if p.runModal() == .OK { importFiles(p.urls, at: nil, into: model) }
    }

    // MARK: ABG variables
    var abgMatchAvailable: Bool { app.abg.hasMatch }
    /// Fill {{team1}} {{team2}} {{matchTitle}} from the AirBattleground match selected in the app.
    func pullFromABG(into model: SceneEditorModel) {
        guard let link = app.abg.link else { return }
        var vars: [String: String] = [:]
        if let t = link.eventTitle { vars["matchTitle"] = t }
        let sub = link.eventSubtitle ?? ""
        let (t1, t2) = Self.splitTeams(sub.isEmpty ? (link.eventTitle ?? "") : sub)
        if let t1 { vars["team1"] = t1 }
        if let t2 { vars["team2"] = t2 }
        model.edit("Pull from AirBattleground") { s in for (k, v) in vars { s.variableDefaults[k] = v } }
        for (k, v) in vars { model.variables[k] = v }
    }
    nonisolated static func splitTeams(_ s: String) -> (String?, String?) {
        for sep in [" vs. ", " vs ", " VS ", " v ", " – ", " - ", " x "] {
            if let r = s.range(of: sep) {
                let a = s[s.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let b = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty { return (a, b) }
            }
        }
        return (nil, nil)
    }

    // MARK: fonts
    static let preferredFonts = ["Impact", "Bebas Neue", "Oswald", "Anton", "Teko", "Rajdhani", "Orbitron", "DIN Condensed", "DIN Alternate", "Helvetica Neue", "Avenir Next", "Avenir Next Condensed", "Futura",
                                 "Gill Sans", "Arial Black", "Trebuchet MS", "Verdana", "Optima", "Copperplate", "Rockwell", "Georgia", "Didot", "Baskerville", "American Typewriter", "Menlo", "Courier New", "Marker Felt", "Chalkduster"]
    static let installedFonts: [String] = {
        let all = Set(NSFontManager.shared.availableFontFamilies)
        let f = preferredFonts.filter { all.contains($0) }
        return f.isEmpty ? ["Helvetica Neue"] : f
    }()
}
