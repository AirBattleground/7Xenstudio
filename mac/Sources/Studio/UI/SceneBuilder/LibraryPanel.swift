// Left library: Templates, Props, Shapes & FX, Sources, My uploads.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum LibraryTab: String, CaseIterable, Identifiable {
    case templates = "Templates", props = "Props", shapes = "Shapes", sources = "Sources", uploads = "Uploads"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .templates: "square.grid.2x2"; case .props: "shield.lefthalf.filled"; case .shapes: "textformat.alt"; case .sources: "video"; case .uploads: "square.and.arrow.down" }
    }
}

/// Async, cached thumbnails for built-in assets.
@MainActor
final class AssetThumbs {
    static let shared = AssetThumbs()
    private var cache: [String: CGImage] = [:]
    func image(_ a: BuiltinAsset, theme: PropTheme, maxPixel: Int = 220) async -> CGImage? {
        let key = "\(a.id)|\(a.themed ? theme.id : "-")|\(maxPixel)"
        if let c = cache[key] { return c }
        let img = await Task.detached(priority: .utility) { () -> CGImage? in
            let full = a.image(scale: 1, theme: theme)
            let k = Double(maxPixel) / Double(max(full.width, full.height))
            if k >= 1 { return full }
            let w = max(1, Int(Double(full.width) * k)), h = max(1, Int(Double(full.height) * k))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return full }
            ctx.interpolationQuality = .high
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }.value
        if let img { if cache.count > 800 { cache.removeAll() }; cache[key] = img }
        return img
    }
}

struct LibraryPanel: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    var onNewScene: (LayerScene) -> Void
    @State private var tab: LibraryTab = .templates

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LibraryTab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold))
                            Text(t.rawValue).font(.system(size: 9, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(tab == t ? Theme.accent : Theme.muted)
                        .background(tab == t ? Theme.accent.opacity(0.12) : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? Theme.accent : .clear).frame(height: 2) }
                    }.buttonStyle(.plain).accessibilityLabel(t.rawValue)
                }
            }.background(Theme.well.opacity(0.5))
            Divider().overlay(Theme.stroke)
            ThemeChips(env: env)
            Group {
                switch tab {
                case .templates: TemplatesTab(model: model, env: env, onNewScene: onNewScene)
                case .props: PropsTab(model: model, env: env)
                case .shapes: ShapesTab(model: model, env: env)
                case .sources: SourcesTab(model: model, env: env)
                case .uploads: UploadsTab(model: model, env: env)
                }
            }
        }
        .background(Theme.panel)
    }
}

struct ThemeChips: View {
    var env: SceneEditorEnvironment
    @State private var sel: String = "ember"
    var body: some View {
        HStack(spacing: 6) {
            Text("THEME").font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.faint)
            ForEach(PropTheme.all) { t in
                Button { sel = t.id; env.theme = t; NotificationCenter.default.post(name: .sceneEditorThemeChanged, object: t.id) } label: {
                    Circle().fill(LinearGradient(colors: [Color(hex: t.glow), Color(hex: t.primary), Color(hex: t.hot)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(sel == t.id ? Color.white : Color.white.opacity(0.15), lineWidth: sel == t.id ? 2 : 1))
                }.buttonStyle(.plain).help(t.name).accessibilityLabel(t.name)
            }
            Spacer()
        }.padding(.horizontal, 10).frame(height: 30).onAppear { sel = env.theme.id }
    }
}
extension Notification.Name { static let sceneEditorThemeChanged = Notification.Name("sceneEditorThemeChanged") }
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

struct CategoryChips<T: Hashable>: View {
    var items: [(T?, String)]
    @Binding var sel: T?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    Button { sel = it.0 } label: {
                        Text(it.1).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 22)
                            .foregroundStyle(sel == it.0 ? Color.white : Theme.muted)
                            .background(sel == it.0 ? Theme.accent : Color.white.opacity(0.07), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 10)
        }.frame(height: 28)
    }
}

// MARK: - Templates

struct TemplatesTab: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    var onNewScene: (LayerScene) -> Void
    @State private var cat: String? = nil
    @State private var items: [TemplateItem] = []
    @State private var theme: PropTheme = .ember
    @State private var confirmApply: TemplateItem?

    var cats: [String] { var seen: [String] = []; for i in items where !seen.contains(i.category) { seen.append(i.category) }; return seen }
    var shown: [TemplateItem] { items.filter { cat == nil || $0.category == cat } }
    var body: some View {
        VStack(spacing: 6) {
            CategoryChips(items: [(nil, "All")] + cats.map { ($0 as String?, $0) }, sel: $cat).padding(.top, 6)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(shown) { t in
                        TemplateCard(item: t, theme: theme, env: env, variables: model.variables)
                            .contextMenu {
                                Button("Apply to current scene") { confirmApply = t }
                                Button("New scene from template") { onNewScene(t.build(theme)) }
                                if t.isUser { Divider(); Button("Delete template", role: .destructive) { env.repo.deleteTemplate(t.id); reload() } }
                            }
                            .onTapGesture(count: 2) { confirmApply = t }
                    }
                }.padding(10)
                if shown.isEmpty { EmptyState(icon: "square.grid.2x2", title: "No templates", message: "Use Save as My Template in the scene menu to add your own.") }
            }
            if let sel = confirmApply { EmptyView().id(sel.id) }
        }
        .onAppear { theme = env.theme; reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sceneEditorThemeChanged)) { n in if let id = n.object as? String { theme = PropTheme.named(id) } }
        .confirmationDialog("Apply \(confirmApply?.name ?? "template")?", isPresented: Binding(get: { confirmApply != nil }, set: { if !$0 { confirmApply = nil } }), presenting: confirmApply) { t in
            Button("Replace current layers") { apply(t, replace: true) }
            Button("Add on top of current layers") { apply(t, replace: false) }
            Button("New scene from template") { onNewScene(t.build(theme)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Undo (⌘Z) restores the previous scene.") }
    }
    func reload() { items = TemplateCatalog.all(repo: env.repo) }
    func apply(_ t: TemplateItem, replace: Bool) {
        var s = t.build(theme)
        // keep the phones / cameras the operator already placed: copy their source refs onto the template's source layers in order
        let existing = LayerTree.flatten(model.scene.layers).compactMap { l -> SourceRef? in if case .source(let r, _) = l.kind { return r }; return nil }
        if replace {
            var it = existing.makeIterator()
            func fill(_ ls: inout [Layer]) {
                for i in ls.indices {
                    if case .source(_, let fit) = ls[i].kind, let r = it.next() { ls[i].kind = .source(r, fit: fit) }
                    if case .group(var c) = ls[i].kind { fill(&c); ls[i].kind = .group(c) }
                }
            }
            fill(&s.layers)
            let keepID = model.scene.id, keepName = model.scene.name, keepMig = model.scene.migratedFrom
            s.id = keepID; s.name = keepName; s.migratedFrom = keepMig
            model.replaceScene(s, label: "Apply \(t.name)")
        } else {
            model.edit("Add \(t.name)") { sc in sc.layers.append(contentsOf: s.layers.map(LayerTree.clone)); for (k, v) in s.variableDefaults where sc.variableDefaults[k] == nil { sc.variableDefaults[k] = v } }
        }
    }
}

struct TemplateCard: View {
    var item: TemplateItem
    var theme: PropTheme
    var env: SceneEditorEnvironment
    var variables: SceneVariables
    @State private var img: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(Theme.well)
                if let img { Image(decorative: img, scale: 1).resizable().scaledToFit() } else { ProgressView().controlSize(.small) }
            }
            .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hover ? Theme.accent : Theme.stroke, lineWidth: hover ? 2 : 1))
            Text(item.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.text)
            Text(item.category).font(.system(size: 9)).foregroundStyle(Theme.faint)
        }
        .onHover { hover = $0 }
        .task(id: "\(item.id)|\(theme.id)") {
            let scene = item.build(theme)
            var e = env.rasterEnv(for: scene, variables: variables); e.theme = theme
            let envCopy = e
            img = await Task.detached(priority: .utility) { SceneRasterizer.render(scene, width: 360, env: envCopy) }.value
        }
        .help("Double-click to apply. Right-click for more.")
    }
}

// MARK: - Props

struct PropsTab: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    @State private var query = ""
    @State private var cat: PropCategory? = nil
    @State private var theme: PropTheme = .ember
    var assets: [BuiltinAsset] {
        var a = query.isEmpty ? PropsCatalog.all : PropsCatalog.search(query)
        if let cat { a = a.filter { $0.category == cat } }
        return a
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Search props", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 8).frame(height: 26).background(Theme.well, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.top, 8)
            TeamBoardLibraryRow(model: model, env: env).padding(.horizontal, 10)
            CategoryChips(items: [(nil, "All")] + PropCategory.allCases.map { ($0 as PropCategory?, $0.title) }, sel: $cat)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(assets) { a in
                        PropTile(asset: a, theme: theme) { add(a) }
                    }
                }.padding(10)
                if assets.isEmpty { EmptyState(icon: "magnifyingglass", title: "No props found", message: "Try another word or category.") }
            }
        }
        .onAppear { theme = env.theme }
        .onReceive(NotificationCenter.default.publisher(for: .sceneEditorThemeChanged)) { n in if let id = n.object as? String { theme = PropTheme.named(id) } }
    }
    func add(_ a: BuiltinAsset) {
        env.addFromLibrary(kind: "builtin", value: a.id, at: CGPoint(x: Double(model.scene.canvas.w) / 2, y: Double(model.scene.canvas.h) / 2), into: model)
    }
}

struct PropTile: View {
    var asset: BuiltinAsset
    var theme: PropTheme
    var onAdd: () -> Void
    @State private var img: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Checker()
                if let img { Image(decorative: img, scale: 1).resizable().scaledToFit().padding(4) }
            }
            .aspectRatio(16 / 10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hover ? Theme.accent : Theme.stroke, lineWidth: hover ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if hover { Button(action: onAdd) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).background(Theme.accent, in: Circle()).foregroundStyle(.white) }.buttonStyle(.plain).padding(4) }
            }
            Text(asset.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onAdd)
        .onDrag { NSItemProvider(object: LibraryDrag.builtin(asset.id) as NSString) }
        .task(id: "\(asset.id)|\(theme.id)") { img = await AssetThumbs.shared.image(asset, theme: theme) }
        .help("\(asset.name): double-click or drag onto the canvas")
    }
}

// MARK: - Shapes, text, FX

struct ShapesTab: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    struct Tool: Identifiable { var id: String; var name: String; var symbol: String }
    static let tools: [Tool] = [
        Tool(id: "rect", name: "Rectangle", symbol: "rectangle"), Tool(id: "rounded", name: "Rounded", symbol: "rectangle.roundedtop"), Tool(id: "ellipse", name: "Ellipse", symbol: "circle"),
        Tool(id: "polygon", name: "Polygon", symbol: "hexagon"), Tool(id: "star", name: "Star", symbol: "star"), Tool(id: "line", name: "Line", symbol: "line.diagonal"),
        Tool(id: "text", name: "Text", symbol: "textformat"), Tool(id: "heading", name: "Match title", symbol: "textformat.size.larger"), Tool(id: "vs", name: "Team VS Team", symbol: "person.2"),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "Shapes & text")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Self.tools) { t in toolTile(t.id, t.name, t.symbol) }
                }
                SectionHeader(text: "Fire & effects")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(LayerFactory.effectPresets) { p in toolTile(p.id, p.name, p.symbol, wide: true) }
                }
            }.padding(10)
        }
    }
    func toolTile(_ id: String, _ name: String, _ symbol: String, wide: Bool = false) -> some View {
        ToolTile(name: name, symbol: symbol, wide: wide) {
            env.addFromLibrary(kind: "tool", value: id, at: CGPoint(x: Double(model.scene.canvas.w) / 2, y: Double(model.scene.canvas.h) / 2), into: model)
        }.onDrag { NSItemProvider(object: LibraryDrag.tool(id) as NSString) }
    }
}
struct ToolTile: View {
    var name: String; var symbol: String; var wide: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(hover ? Theme.accent : Theme.text)
                Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: wide ? 52 : 62)
            .background(hover ? Color.white.opacity(0.09) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.7) : Theme.stroke))
        }.buttonStyle(.plain).onHover { hover = $0 }.help("Click or drag onto the canvas")
    }
}

// MARK: - Sources

struct SourcesTab: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    @State private var url = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Phones")
                if env.app.devices.isEmpty { Text("No phones paired yet. Add one on the Phones page.").font(Theme.Font.caption).foregroundStyle(Theme.faint) }
                ForEach(env.app.devices) { d in
                    sourceRow(d.name, d.videoReady ? "Live" : (d.online ? "Connected" : "Offline"), "iphone", d.videoReady ? Theme.ok : Theme.faint, .device(id: d.id))
                }
                SectionHeader(text: "This Mac")
                sourceRow("Webcam", "Camera", "web.camera", Theme.accent, .camera)
                sourceRow("Slate / intro", "Text card or intro video", "text.below.photo", Theme.accent, .slate)
                if !env.app.props.filter(\.isVideo).isEmpty {
                    SectionHeader(text: "Video props")
                    ForEach(env.app.props.filter(\.isVideo)) { p in sourceRow(p.name, "Video", "film", .purple, .prop(id: p.id)) }
                }
                SectionHeader(text: "Live data")
                TeamBoardLibraryRow(model: model, env: env)
                SectionHeader(text: "Web image")
                HStack {
                    TextField("https://… image URL", text: $url).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button("Add") { env.addSource(.web(url: url.trimmingCharacters(in: .whitespaces)), into: model); url = "" }.controlSize(.small)
                        .disabled(!(url.hasPrefix("http://") || url.hasPrefix("https://")))
                }
                Text("Refreshed every 2 seconds. Use it for a scoreboard or stats image.").font(Theme.Font.caption).foregroundStyle(Theme.faint)
            }.padding(10)
        }
    }
    func sourceRow(_ title: String, _ sub: String, _ symbol: String, _ tint: Color, _ ref: SourceRef) -> some View {
        SourceRowView(title: title, sub: sub, symbol: symbol, tint: tint) { env.addSource(ref, into: model) }
            .onDrag { NSItemProvider(object: LibraryDrag.source((try? String(data: JSONEncoder().encode(ref), encoding: .utf8)) ?? "") as NSString) }
    }
}
/// "Team Status Board" entry (Props and Sources tabs): click to add, or drag onto the canvas.
struct TeamBoardLibraryRow: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    var body: some View {
        SourceRowView(title: "Team Status Board", sub: "Live team status (manual, JSON URL or mock)", symbol: "list.number", tint: Color(hex: 0xE9C46A)) {
            env.addFromLibrary(kind: "tool", value: "teamboard", at: .zero, into: model)
        }
        .onDrag { NSItemProvider(object: LibraryDrag.tool("teamboard") as NSString) }
        .help("Adds the dynamic team status board on the right side at full height. Set its data source in the Inspector.")
    }
}
struct SourceRowView: View {
    var title: String; var sub: String; var symbol: String; var tint: Color
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(sub).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundStyle(hover ? Theme.accent : Theme.faint)
            }
            .padding(6).background(hover ? Color.white.opacity(0.07) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - Uploads

struct UploadsTab: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 8) {
            Button { env.importPanel(into: model) } label: { Label("Import PNG, JPG, SVG, GIF, MP4…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.studio(.secondary, height: 28)).padding(.horizontal, 10).padding(.top, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(env.app.props) { p in
                        UploadTile(prop: p, env: env) { env.addFromLibrary(kind: "prop", value: p.id, at: CGPoint(x: Double(model.scene.canvas.w) / 2, y: Double(model.scene.canvas.h) / 2), into: model) }
                    }
                }.padding(.horizontal, 10)
                if env.app.props.isEmpty {
                    EmptyState(icon: "tray.and.arrow.down", title: "Nothing uploaded", message: "Drop files here, or drag them onto the canvas.")
                }
            }
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(4) } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var urls: [URL] = []
            let g = DispatchGroup()
            for p in providers { g.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; g.leave() } }
            g.notify(queue: .main) { MainActor.assumeIsolated { if !urls.isEmpty { env.importFiles(urls, at: nil, into: model) } } }
            return true
        }
    }
}
struct UploadTile: View {
    var prop: PropInfo
    var env: SceneEditorEnvironment
    var onAdd: () -> Void
    @State private var img: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Checker()
                if let img { Image(decorative: img, scale: 1).resizable().scaledToFit() } else { Image(systemName: prop.isVideo ? "film" : "photo").foregroundStyle(Theme.faint) }
            }
            .aspectRatio(16 / 10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hover ? Theme.accent : Theme.stroke, lineWidth: hover ? 2 : 1))
            .overlay(alignment: .bottomTrailing) { if prop.isVideo { Image(systemName: "play.fill").font(.system(size: 8)).padding(3).background(.black.opacity(0.6), in: Circle()).padding(3) } }
            Text(prop.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onAdd)
        .onDrag { NSItemProvider(object: LibraryDrag.prop(prop.id) as NSString) }
        .task(id: prop.id) {
            for _ in 0..<30 { if let i = env.propImage(prop.id) { img = i; return }; try? await Task.sleep(nanoseconds: 300_000_000) }
        }
    }
}
