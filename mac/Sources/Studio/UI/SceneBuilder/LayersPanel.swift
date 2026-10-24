// Layer tree: thumbnails, visibility / lock, rename, groups, drag-reorder, per-layer opacity + blend.
import SwiftUI
import UniformTypeIdentifiers

/// Renders a layer thumbnail off the main thread and caches it by layer content.
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [Int: CGImage] = [:]
    func image(for layer: Layer, env: SceneEditorEnvironment) async -> CGImage? {
        var h = Hasher(); h.combine(layer); h.combine(env.theme.id)
        let key = h.finalize()
        if let c = cache[key] { return c }
        let renv = env.rasterEnv(for: LayerScene(layers: [layer]), variables: .sample)
        let img = await Task.detached(priority: .utility) { SceneRasterizer.layerThumbnail(layer, size: 96, env: renv) }.value
        if let img { if cache.count > 600 { cache.removeAll() }; cache[key] = img }
        return img
    }
}

struct LayerThumb: View {
    var layer: Layer
    var env: SceneEditorEnvironment
    @State private var img: CGImage?
    var body: some View {
        ZStack {
            Checker()
            if let img { Image(decorative: img, scale: 1).resizable().scaledToFit() }
        }
        .frame(width: 40, height: 26).clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.stroke))
        .task(id: layer) { img = await ThumbCache.shared.image(for: layer, env: env) }
    }
}

struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 5
            for y in 0..<Int(size.height / s + 1) { for x in 0..<Int(size.width / s + 1) where (x + y) % 2 == 0 {
                ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(.white.opacity(0.07)))
            } }
        }.background(Color.black.opacity(0.35))
    }
}

struct LayerRow: View {
    static func symbol(_ k: LayerKind) -> String {
        switch k {
        case .source(let r, _): switch r { case .device: "iphone"; case .camera: "web.camera"; case .web: "globe"; default: "film" }
        case .image: "photo"; case .shape: "square.on.circle"; case .text: "textformat"; case .group: "folder"; case .effect: "flame"; case .teamBoard: "list.number"
        }
    }
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    var layer: Layer
    var depth: Int
    @Binding var expanded: Set<String>
    @State private var editing = false
    @State private var name = ""
    @State private var hover = false
    @FocusState private var focus: Bool

    var selected: Bool { model.isSelected(layer.id) }
    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if case .group = layer.kind {
                Button { if expanded.contains(layer.id) { expanded.remove(layer.id) } else { expanded.insert(layer.id) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded.contains(layer.id) ? 90 : 0)).frame(width: 12)
                }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            } else { Color.clear.frame(width: 12, height: 1) }
            Button { model.toggleVisible(layer.id) } label: {
                Image(systemName: layer.visible ? "eye.fill" : "eye.slash").font(.system(size: 10)).frame(width: 18)
                    .foregroundStyle(layer.visible ? Theme.muted : Theme.faint)
            }.buttonStyle(.plain).help(layer.visible ? "Hide" : "Show")
            LayerThumb(layer: layer, env: env)
            if editing {
                TextField("", text: $name).textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).focused($focus)
                    .onSubmit { commit() }.onExitCommand { editing = false }
                    .padding(.horizontal, 4).background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text(layer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(layer.visible ? Theme.text : Theme.faint)
                    .onTapGesture(count: 2) { name = layer.name; editing = true; focus = true }
            }
            Spacer(minLength: 0)
            if layer.blend != .normal { Text(layer.blend.rawValue.prefix(3).uppercased()).font(Theme.Font.mono(8, .bold)).foregroundStyle(Theme.faint) }
            Button { model.toggleLock(layer.id) } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open").font(.system(size: 10)).frame(width: 18)
                    .foregroundStyle(layer.locked ? Theme.warn : (hover ? Theme.muted : Theme.faint.opacity(0.5)))
            }.buttonStyle(.plain).help(layer.locked ? "Unlock" : "Lock")
        }
        .padding(.horizontal, 6).frame(height: 34)
        .background(selected ? Theme.accent.opacity(0.22) : (hover ? Color.white.opacity(0.05) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.select(layer.id, extend: flags.contains(.shift) || flags.contains(.command))
        }
        .contextMenu {
            Button("Duplicate") { model.select(layer.id); model.duplicateSelected() }
            Button("Rename") { name = layer.name; editing = true; focus = true }
            Button(layer.locked ? "Unlock" : "Lock") { model.toggleLock(layer.id) }
            Divider()
            Button("Group") { if !model.isSelected(layer.id) { model.select(layer.id) }; model.group() }
            if case .group = layer.kind { Button("Ungroup") { model.select(layer.id); model.ungroup() } }
            Divider()
            Button("Delete", role: .destructive) { model.select(layer.id); model.deleteSelected() }
        }
        .accessibilityElement(children: .combine).accessibilityLabel("\(layer.name), \(layer.visible ? "visible" : "hidden")\(layer.locked ? ", locked" : "")")
    }
    func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { model.rename(layer.id, n) }
        editing = false
    }
}

struct LayersPanel: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    @State private var expanded = Set<String>()
    @State private var dropTarget: (id: String, pos: SceneEditorModel.DropPosition)?
    @State private var draggingID: String?

    struct Item: Identifiable { var layer: Layer; var depth: Int; var id: String { layer.id } }
    func items() -> [Item] {
        var out: [Item] = []
        func walk(_ ls: [Layer], _ d: Int) {
            for l in ls.reversed() {
                out.append(Item(layer: l, depth: d))
                if case .group(let c) = l.kind, expanded.contains(l.id) { walk(c, d + 1) }
            }
        }
        walk(model.scene.layers, 0)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            if let l = model.primary { appearanceStrip(l) }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items()) { it in
                        LayerRow(model: model, env: env, layer: it.layer, depth: it.depth, expanded: $expanded)
                            .overlay(alignment: dropTarget?.id == it.id && dropTarget?.pos == .above ? .top : .bottom) {
                                if dropTarget?.id == it.id, dropTarget?.pos != .into { Rectangle().fill(Theme.accent).frame(height: 2) }
                            }
                            .overlay { if dropTarget?.id == it.id, dropTarget?.pos == .into { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2) } }
                            .onDrag { draggingID = it.id; return NSItemProvider(object: "7xen-layer:\(it.id)" as NSString) }
                            .onDrop(of: [.text], delegate: LayerDrop(model: model, item: it.layer, dropTarget: $dropTarget, draggingID: $draggingID))
                    }
                    if model.scene.layers.isEmpty {
                        EmptyState(icon: "square.3.layers.3d", title: "No layers", message: "Add shapes, text, props or a phone source from the library.")
                    }
                }.padding(6)
            }
            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.panel)
        .onChange(of: model.selection) { _, sel in   // keep selected children visible
            for id in sel { if let loc = LayerTree.location(of: id, in: model.scene.layers), let p = loc.parent { expanded.insert(p) } }
        }
        .onAppear { for l in LayerTree.flatten(model.scene.layers) where l.kind.typeName == "group" { expanded.insert(l.id) } }
    }
    var header: some View {
        HStack {
            Text("LAYERS").font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.muted)
            Text("\(LayerTree.flatten(model.scene.layers).count)").font(Theme.Font.mono(10)).foregroundStyle(Theme.faint)
            Spacer()
        }.padding(.horizontal, 12).frame(height: 30)
    }
    func appearanceStrip(_ l: Layer) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { l.blend }, set: { b in model.updateSelected("Blend mode") { $0.blend = b } })) {
                ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.labelsHidden().controlSize(.small).frame(width: 92)
            Slider(value: Binding(get: { l.opacity }, set: { v in model.updateSelected("Opacity", coalesce: "opacity") { $0.opacity = v } }), in: 0...1).controlSize(.mini).tint(Theme.accent)
            Text("\(Int((l.opacity * 100).rounded()))%").font(Theme.Font.mono(10)).foregroundStyle(Theme.muted).frame(width: 32, alignment: .trailing)
        }.padding(.horizontal, 10).frame(height: 32).background(Color.white.opacity(0.03))
    }
    var footer: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Rectangle") { env.addFromLibrary(kind: "tool", value: "rect", at: center, into: model) }
                Button("Ellipse") { env.addFromLibrary(kind: "tool", value: "ellipse", at: center, into: model) }
                Button("Text") { env.addFromLibrary(kind: "tool", value: "text", at: center, into: model) }
                Button("Group selection") { model.group() }
            } label: { Image(systemName: "plus").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).fixedSize().help("Add layer")
            ToolButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)", enabled: !model.selection.isEmpty) { model.duplicateSelected() }
            ToolButton(symbol: "folder.badge.plus", help: "Group (⌘G)", enabled: !model.selection.isEmpty) { model.group() }
            ToolButton(symbol: "arrow.up", help: "Bring forward (])", enabled: !model.selection.isEmpty) { model.reorder(.forward) }
            ToolButton(symbol: "arrow.down", help: "Send backward ([)", enabled: !model.selection.isEmpty) { model.reorder(.backward) }
            Spacer()
            ToolButton(symbol: "trash", help: "Delete (⌫)", enabled: !model.selection.isEmpty) { model.deleteSelected() }
        }.padding(.horizontal, 8).frame(height: 34)
    }
    var center: CGPoint { CGPoint(x: Double(model.scene.canvas.w) / 2, y: Double(model.scene.canvas.h) / 2) }
}

struct LayerDrop: DropDelegate {
    var model: SceneEditorModel
    var item: Layer
    @Binding var dropTarget: (id: String, pos: SceneEditorModel.DropPosition)?
    @Binding var draggingID: String?
    func position(_ info: DropInfo) -> SceneEditorModel.DropPosition {
        let y = info.location.y
        if case .group = item.kind { return y < 9 ? .above : y > 25 ? .below : .into }
        return y < 17 ? .above : .below
    }
    func dropEntered(info: DropInfo) { dropTarget = (item.id, position(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? { dropTarget = (item.id, position(info)); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if dropTarget?.id == item.id { dropTarget = nil } }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        let pos = position(info)
        dropTarget = nil
        guard let id = draggingID else { return false }
        draggingID = nil
        return model.move(id, relativeTo: item.id, pos)
    }
}
