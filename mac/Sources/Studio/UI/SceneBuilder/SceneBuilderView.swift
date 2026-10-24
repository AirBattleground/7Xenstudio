// The "Scenes" page: scene gallery, and the full layer-based scene editor.
import SwiftUI
import AppKit

/// Sidebar page entry point.
struct ScenesPage: View {
    @Environment(AppModel.self) var app
    var body: some View {
        if let s = app.editingScene {
            SceneBuilderView(scene: s, isNew: !app.allScenes.contains { $0.id == s.id }, services: app.services).id(s.id)
        } else {
            SceneGalleryPage().onAppear {
                // developer hook for screenshots: STUDIO_SB_OPEN=1 opens the first scene, STUDIO_SB_TEMPLATE=<id> builds a new scene from a template
                let e = ProcessInfo.processInfo.environment
                if let t = e["STUDIO_SB_TEMPLATE"], let tpl = TemplateCatalog.all(repo: LayerSceneRepository.shared).first(where: { $0.id == t }) {
                    SceneBuilderActions.newScene(app, from: tpl.build(.ember), name: tpl.name)
                } else if e["STUDIO_SB_OPEN"] != nil, let f = app.scenes.first { app.editingScene = f }
            }
        }
    }
}

struct SceneGalleryPage: View {
    @Environment(AppModel.self) var app
    @State private var templateMenu: [TemplateItem] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Scenes").font(Theme.Font.title).foregroundStyle(Theme.text)
                        Text("Build broadcast scenes with layers, props, effects and animation. Click Edit on a scene to open the editor.").font(Theme.Font.body).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Menu {
                        ForEach(templateMenu.filter { !$0.isUser }) { t in Button(t.name) { SceneBuilderActions.newScene(app, from: t.build(.ember), name: t.name) } }
                        if templateMenu.contains(where: \.isUser) {
                            Divider()
                            ForEach(templateMenu.filter(\.isUser)) { t in Button(t.name) { SceneBuilderActions.newScene(app, from: t.build(.ember), name: t.name) } }
                        }
                    } label: { Label("New from template", systemImage: "square.grid.2x2") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Button { app.newScene() } label: { Label("New scene", systemImage: "plus") }
                        .buttonStyle(.studio(.primary(Theme.accent), height: 28))
                }
                HStack(spacing: 10) {
                    PresetSwitcher()
                    Text("Scenes in the active preset (streamed). New scenes join it. Right-click a scene to add it to other presets.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], spacing: 14) {
                    ForEach(Array(app.scenes.enumerated()), id: \.element.id) { i, s in SceneCard(scene: s, index: i) }
                }
                if app.scenes.isEmpty {
                    Text("“\(app.activePreset?.name ?? "This preset")” has no scenes yet. Create a new scene, or add one of the other scenes below.")
                        .font(Theme.Font.body).foregroundStyle(Theme.muted)
                }
                let mine = Set(app.scenes.map(\.id))
                let others = app.allScenes.filter { !mine.contains($0.id) }
                if !others.isEmpty {
                    HStack(spacing: 8) {
                        SectionHeader(text: "Other scenes in the studio (\(others.count))")
                        Text("Not in “\(app.activePreset?.name ?? "")”").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                    }.padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { i, s in SceneCard(scene: s, index: i, inActivePreset: false) }
                    }
                }
            }.padding(Theme.Space.xl)
        }
        .onAppear { templateMenu = TemplateCatalog.all(repo: LayerSceneRepository.shared) }
    }
}

@MainActor
enum SceneBuilderActions {
    /// Create a scene record from a layer scene and open it in the editor.
    static func newScene(_ app: AppModel, from layers: LayerScene, name: String) {
        var ls = layers
        ls.id = UUID().uuidString; ls.name = name; ls.migratedFrom = nil
        ls.layers = ls.layers.map(LayerTree.clone)
        let legacy = Scene(id: ls.id, name: name, layout: .full, slots: [nil])
        LayerSceneRepository.shared.save(ls)
        app.save(legacy)
        app.editingScene = legacy
    }
    static func load(_ s: Scene, isNew: Bool = false, services: StudioServices? = nil) -> LayerScene {
        if var l = services?.layerScenes().first(where: { $0.id == s.id }), LayerSceneRepository.shared.load(s.id) == nil { l.name = s.name; return l }
        if var l = LayerSceneRepository.shared.load(s.id) { l.name = s.name; return l }
        if isNew { return LayerScene(id: s.id, name: s.name, background: .solid(RGBA(hex: 0x06090C))) }
        return LayerScene.migrate(s)
    }
}

struct SceneBuilderView: View {
    @Environment(AppModel.self) var app
    @State private var model: SceneEditorModel
    @State private var canvas = CanvasState()
    @State private var env: SceneEditorEnvironment?
    @State private var keyboard = EditorKeyboard()
    @State private var legacy: Scene
    @State private var showLibrary = true
    @State private var saveState = "Saved"
    @State private var saveTask: Task<Void, Never>?
    @State private var liveTask: Task<Void, Never>?
    @State private var confirmDelete = false
    @State private var templateName = ""
    @State private var askTemplate = false

    init(scene: Scene, isNew: Bool = false, services: StudioServices? = nil) {
        _legacy = State(initialValue: scene)
        _model = State(initialValue: SceneEditorModel(scene: SceneBuilderActions.load(scene, isNew: isNew, services: services)))
    }

    var body: some View {
        let env = self.env ?? SceneEditorEnvironment(app: app)
        VStack(spacing: 0) {
            topBar(env)
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                if showLibrary {
                    LibraryPanel(model: model, env: env, onNewScene: { s in SceneBuilderActions.newScene(app, from: s, name: s.name) }).frame(width: 268)
                    Divider().overlay(Theme.stroke)
                }
                VStack(spacing: 0) {
                    CanvasToolbar(model: model, canvas: canvas)
                    Divider().overlay(Theme.stroke)
                    CanvasView(model: model, state: canvas, env: env)
                    Divider().overlay(Theme.stroke)
                    CanvasStatusBar(model: model, canvas: canvas)
                }
                Divider().overlay(Theme.stroke)
                VStack(spacing: 0) {
                    LayersPanel(model: model, env: env).frame(height: 250)
                    Divider().overlay(Theme.stroke)
                    SBInspectorView(model: model, state: canvas, env: env)
                }.frame(width: 300)
            }
        }
        .background(Theme.bg)
        .onAppear {
            if self.env == nil { self.env = env }
            model.onChange = { _ in scheduleSave(); scheduleLive() }
            keyboard.onSave = { saveNow() }
            keyboard.start(model: model, state: canvas)
            for (k, v) in model.scene.variableDefaults { model.variables[k] = v }
        }
        .onDisappear { keyboard.stop(); saveNow() }
        .onReceive(NotificationCenter.default.publisher(for: .sceneEditorThemeChanged)) { _ in canvas.fitRequested = false }
        .alert("Delete \(legacy.name)?", isPresented: $confirmDelete) {
            Button(app.programID == legacy.id ? "Cut to black & delete" : "Delete scene", role: .destructive) { deleteScene() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(app.programID == legacy.id ? "This scene is ON AIR. Deleting it cuts the program to black first. It is removed from every preset."
                                            : "The scene is removed from the studio and from every preset.")
        }
        .alert("Save as My Template", isPresented: $askTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save") { var s = model.scene; s.name = templateName.isEmpty ? model.scene.name : templateName; env.repo.saveTemplate(s) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It will appear under Templates > My Templates.") }
    }

    // MARK: top bar
    func topBar(_ env: SceneEditorEnvironment) -> some View {
        HStack(spacing: 10) {
            Button { saveNow(); app.editingScene = nil } label: { Label("Scenes", systemImage: "chevron.left") }.buttonStyle(.studio(.ghost, height: 26))
            Divider().frame(height: 18).overlay(Theme.stroke)
            TextField("Scene name", text: Binding(get: { model.scene.name }, set: { n in model.edit("Rename scene", coalesce: "sname") { $0.name = n } }))
                .textFieldStyle(.plain).font(.system(size: 14, weight: .bold)).frame(width: 190)
                .padding(.horizontal, 8).frame(height: 26).background(Theme.well, in: RoundedRectangle(cornerRadius: 6))
            Text(saveState).font(Theme.Font.caption).foregroundStyle(Theme.faint)
            if app.programID == legacy.id { Pill(text: "ON AIR - edits go live", color: Theme.program, filled: true) }
            else if app.previewID == legacy.id { Pill(text: "PREVIEW - edits update live", color: Theme.preview) }
            Spacer()
            ToolButton(symbol: showLibrary ? "sidebar.left" : "sidebar.leading", help: "Show / hide library", active: showLibrary) { withAnimation(.easeOut(duration: 0.15)) { showLibrary.toggle() } }
            Menu {
                Button("Duplicate scene") { duplicateScene() }
                Button("Save as My Template…") { templateName = model.scene.name; askTemplate = true }
                Divider()
                Button("Delete scene…", role: .destructive) { confirmDelete = true }.disabled(app.allScenes.count <= 1)
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }.menuStyle(.borderlessButton).fixedSize()
            Button { saveNow(); ensureSaved(); app.select(legacy) } label: { Label("Preview this scene", systemImage: "eye") }.buttonStyle(.studio(.secondary, height: 26))
            Button { saveNow(); ensureSaved(); app.takeScene(legacy) } label: { Label("Send to Program", systemImage: "play.rectangle.fill") }.buttonStyle(.studio(.primary(Theme.program), height: 26))
        }.padding(.horizontal, 12).frame(height: 44).background(Theme.panel)
    }

    // MARK: persistence
    func scheduleSave() {
        saveState = "Editing…"
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }
    func scheduleLive() {
        liveTask?.cancel()
        let svc = app.services, id = legacy.id
        liveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            var s = model.scene; s.id = id
            svc.pushLive(s)
        }
    }
    func ensureSaved() {
        if !app.allScenes.contains(where: { $0.id == legacy.id }) { app.save(legacy) }
    }
    func saveNow() {
        saveTask?.cancel()
        ensureSaved()
        var s = model.scene; s.id = legacy.id
        LayerSceneRepository.shared.save(s)
        let svc = app.services
        Task { await svc.saveLayerScene(s) }
        if legacy.name != s.name { legacy.name = s.name; app.save(legacy) }
        NotificationCenter.default.post(name: .layerSceneSaved, object: legacy.id)
        saveState = "Saved"
    }
    func duplicateScene() {
        saveNow()
        var copy = model.scene; copy.id = UUID().uuidString; copy.name = model.scene.name + " copy"; copy.layers = copy.layers.map(LayerTree.clone); copy.migratedFrom = nil
        let l = Scene(id: copy.id, name: copy.name, layout: legacy.layout, slots: legacy.slots, fits: legacy.fits)
        LayerSceneRepository.shared.save(copy)
        app.save(l)
        app.editingScene = l
    }
    func deleteScene() {
        app.deleteScene(legacy, cutToBlack: true)
    }
}

extension Notification.Name { static let layerSceneSaved = Notification.Name("layerSceneSaved") }

// MARK: - canvas toolbar (undo, arrange, align)

struct CanvasToolbar: View {
    var model: SceneEditorModel
    var canvas: CanvasState
    var body: some View {
        let has = !model.selection.isEmpty
        let multi = model.selection.count >= 2
        HStack(spacing: 1) {
            ToolButton(symbol: "arrow.uturn.backward", help: "Undo \(model.undoLabel ?? "") (⌘Z)", enabled: model.canUndo) { model.undo() }
            ToolButton(symbol: "arrow.uturn.forward", help: "Redo \(model.redoLabel ?? "") (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            BarDivider()
            ToolButton(symbol: "align.horizontal.left", help: multi ? "Align left" : "Align to canvas left", enabled: has) { model.align(.left) }
            ToolButton(symbol: "align.horizontal.center", help: "Align centre horizontally", enabled: has) { model.align(.centerH) }
            ToolButton(symbol: "align.horizontal.right", help: "Align right", enabled: has) { model.align(.right) }
            ToolButton(symbol: "align.vertical.top", help: "Align top", enabled: has) { model.align(.top) }
            ToolButton(symbol: "align.vertical.center", help: "Align centre vertically", enabled: has) { model.align(.centerV) }
            ToolButton(symbol: "align.vertical.bottom", help: "Align bottom", enabled: has) { model.align(.bottom) }
            ToolButton(symbol: "distribute.horizontal.center", help: "Distribute horizontally (3+ layers)", enabled: model.selection.count >= 3) { model.distribute(.horizontal) }
            ToolButton(symbol: "distribute.vertical.center", help: "Distribute vertically (3+ layers)", enabled: model.selection.count >= 3) { model.distribute(.vertical) }
            BarDivider()
            ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal", enabled: has) { model.flip(horizontal: true) }
            ToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical", enabled: has) { model.flip(horizontal: false) }
            ToolButton(symbol: "rotate.right", help: "Rotate 90°", enabled: has) { model.rotate90() }
            ToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fill canvas", enabled: has) { model.fillCanvas() }
            BarDivider()
            ToolButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to front (⌘])", enabled: has) { model.reorder(.front) }
            ToolButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send to back (⌘[)", enabled: has) { model.reorder(.back) }
            ToolButton(symbol: "folder.badge.plus", help: "Group (⌘G)", enabled: has) { model.group() }
            ToolButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)", enabled: has) { model.duplicateSelected() }
            Spacer(minLength: 0)
        }.padding(.horizontal, 8).frame(height: 36).background(Theme.panel)
    }
}

struct CanvasStatusBar: View {
    var model: SceneEditorModel
    var canvas: CanvasState
    var body: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "minus.magnifyingglass", help: "Zoom out (⌘-)", size: 24) { canvas.zoom(to: canvas.zoom / 1.25) }
            Text("\(Int((canvas.zoom * 100).rounded()))%").font(Theme.Font.mono(11)).foregroundStyle(Theme.muted).frame(width: 44)
            ToolButton(symbol: "plus.magnifyingglass", help: "Zoom in (⌘+)", size: 24) { canvas.zoom(to: canvas.zoom * 1.25) }
            ToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", help: "Fit (⌘0)", size: 24) { canvas.fit(canvas: model.canvasSize) }
            Button("100%") { canvas.zoom(to: 1) }.buttonStyle(.plain).font(Theme.Font.mono(10)).foregroundStyle(Theme.muted).padding(.horizontal, 4).help("Actual size (⌘1)")
            BarDivider()
            ToolButton(symbol: "grid", help: "Grid", active: canvas.showGrid, size: 24) { canvas.showGrid.toggle() }
            ToolButton(symbol: "viewfinder", help: "Safe areas", active: canvas.showSafe, size: 24) { canvas.showSafe.toggle() }
            ToolButton(symbol: "ruler", help: "Rulers (drag from a ruler to make a guide)", active: canvas.showRulers, size: 24) { canvas.showRulers.toggle(); canvas.fitRequested = true }
            ToolButton(symbol: "magnet", help: "Snapping (hold ⌘ to bypass)", active: canvas.snapOn, size: 24) { canvas.snapOn.toggle() }
            ToolButton(symbol: "line.diagonal", help: "Clear guides", enabled: !model.guides.isEmpty, size: 24) { model.guides.removeAll() }
            BarDivider()
            ToolButton(symbol: canvas.previewClock != nil ? "stop.fill" : "play.fill", help: "Preview animations", active: canvas.previewClock != nil, size: 24) { canvas.previewClock = canvas.previewClock == nil ? 0 : nil }
            ToolButton(symbol: "flame", help: "Animate fire / FX", active: canvas.fxMotion, size: 24) { canvas.fxMotion.toggle() }
            Spacer()
            if let c = canvas.cursorCanvas { Text("\(Int(c.x)), \(Int(c.y))").font(Theme.Font.mono(10)).foregroundStyle(Theme.faint) }
            Text("\(model.scene.canvas.w)×\(model.scene.canvas.h)").font(Theme.Font.mono(10)).foregroundStyle(Theme.faint).padding(.leading, 8)
        }.padding(.horizontal, 8).frame(height: 30).background(Theme.panel)
    }
}

/// Scene-card thumbnail rendered by the real engine (cached; refreshes when the scene is saved).
@MainActor
enum SceneThumbs {
    static var images: [String: CGImage] = [:]
}
struct LayerSceneThumb: View {
    @Environment(AppModel.self) var app
    let scene: Scene
    @State private var img: CGImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.well)
            if let img { Image(decorative: img, scale: 1).resizable().scaledToFill() }
        }
        .task(id: "\(scene.id)|\(app.sceneRevision)") {
            let key = "\(scene.id)|\(app.sceneRevision)"
            if let c = SceneThumbs.images[key] { img = c; return }
            guard let ls = app.services.layerScenes().first(where: { $0.id == scene.id }) else { return }
            let r = app.services.stillRenderer()
            let out = await Task.detached(priority: .utility) { r(ls, CGSize(width: 480, height: 270), SceneVariables(Templates.defaultVariables), 4, nil) }.value
            if let out { SceneThumbs.images = SceneThumbs.images.filter { !$0.key.hasPrefix(scene.id + "|") }; SceneThumbs.images[key] = out; img = out }
        }
    }
}
