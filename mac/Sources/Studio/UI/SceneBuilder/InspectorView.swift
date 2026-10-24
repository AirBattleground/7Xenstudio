// Right-hand inspector: per-layer properties (or scene properties when nothing is selected).
import SwiftUI
import AppKit

/// Bindings from controls to a layer (applied to every selected layer so multi-edit works).
@MainActor
struct LayerBinder {
    let m: SceneEditorModel
    let id: String
    var fallback: Layer { Layer(kind: .shape(ShapeSpec())) }
    var layer: Layer { m.layer(id) ?? fallback }

    func b<T: Equatable>(_ kp: WritableKeyPath<Layer, T>, _ label: String) -> Binding<T> {
        Binding(get: { layer[keyPath: kp] }, set: { v in
            let key = "\(kp)"
            m.updateSelected(label, coalesce: key) { $0[keyPath: kp] = v }
        })
    }
    func text<T: Equatable>(_ kp: WritableKeyPath<TextStyle, T>, _ label: String = "Text style") -> Binding<T> {
        Binding(get: { if case .text(let t) = layer.kind { return t[keyPath: kp] }; return TextStyle()[keyPath: kp] }, set: { v in
            m.updateSelected(label, coalesce: "t\(kp)") { l in if case .text(var t) = l.kind { t[keyPath: kp] = v; l.kind = .text(t) } }
        })
    }
    func shape<T: Equatable>(_ kp: WritableKeyPath<ShapeSpec, T>, _ label: String = "Shape") -> Binding<T> {
        Binding(get: { if case .shape(let t) = layer.kind { return t[keyPath: kp] }; return ShapeSpec()[keyPath: kp] }, set: { v in
            m.updateSelected(label, coalesce: "s\(kp)") { l in if case .shape(var t) = l.kind { t[keyPath: kp] = v; l.kind = .shape(t) } }
        })
    }
    func fx<T: Equatable>(_ kp: WritableKeyPath<EffectSpec, T>, _ label: String = "Effect") -> Binding<T> {
        Binding(get: { if case .effect(let t) = layer.kind { return t[keyPath: kp] }; return EffectSpec(.vignette)[keyPath: kp] }, set: { v in
            m.updateSelected(label, coalesce: "e\(kp)") { l in if case .effect(var t) = l.kind { t[keyPath: kp] = v; l.kind = .effect(t) } }
        })
    }
    func opt<T: Equatable>(_ kp: WritableKeyPath<Layer, T?>, default d: T, _ label: String) -> Binding<T> {
        Binding(get: { layer[keyPath: kp] ?? d }, set: { v in m.updateSelected(label, coalesce: "\(kp)") { $0[keyPath: kp] = v } })
    }
}

struct SBInspectorView: View {
    var model: SceneEditorModel
    var state: CanvasState
    var env: SceneEditorEnvironment
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.selection.count >= 1, let l = model.primary {
                    LayerInspector(model: model, state: state, env: env, layer: l)
                } else {
                    SceneInspector(model: model, env: env)
                }
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - layer inspector

struct LayerInspector: View {
    var model: SceneEditorModel
    var state: CanvasState
    var env: SceneEditorEnvironment
    var layer: Layer
    @State private var lockAspect = false
    private var lb: LayerBinder { LayerBinder(m: model, id: layer.id) }

    var body: some View {
        let lb = self.lb
        VStack(spacing: 0) {
            header
            transformSection(lb)
            kindSection(lb)
            appearanceSection(lb)
            borderSection(lb)
            shadowSection(lb)
            glowSection(lb)
            colourSection(lb)
            chromaSection(lb)
            effectsSection(lb)
            animationSection(lb)
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: LayerRow.symbol(layer.kind)).font(.system(size: 13)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.selection.count > 1 ? "\(model.selection.count) layers" : layer.name).font(Theme.Font.bodyBold).foregroundStyle(Theme.text).lineLimit(1)
                Text(model.selection.count > 1 ? "Edits apply to all" : layer.kind.typeName.capitalized).font(Theme.Font.caption).foregroundStyle(Theme.faint)
            }
            Spacer()
        }.padding(.horizontal, 12).frame(height: 44)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }

    // Transform
    func transformSection(_ lb: LayerBinder) -> some View {
        EditorSection("Transform", icon: "move.3d") {
            let t = layer.transform
            HStack(spacing: 6) {
                NumField(label: "X", value: Binding(get: { t.x }, set: { v in model.updateSelected("Move", coalesce: "x") { $0.transform.x = v } }), step: 1)
                NumField(label: "Y", value: Binding(get: { t.y }, set: { v in model.updateSelected("Move", coalesce: "y") { $0.transform.y = v } }), step: 1)
            }
            HStack(spacing: 6) {
                NumField(label: "W", value: Binding(get: { t.w }, set: { v in
                    let nv = max(1, v)
                    model.updateSelected("Resize", coalesce: "w") { l in
                        let ar = l.transform.h / max(1, l.transform.w)
                        l.transform.w = nv; if lockAspect { l.transform.h = (nv * ar).rounded() }
                    }
                }), step: 1, range: 1...20000)
                Button { lockAspect.toggle() } label: { Image(systemName: lockAspect ? "link" : "link.badge.plus").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(lockAspect ? Theme.accent : Theme.faint).help("Lock aspect ratio")
                NumField(label: "H", value: Binding(get: { t.h }, set: { v in
                    let nv = max(1, v)
                    model.updateSelected("Resize", coalesce: "h") { l in
                        let ar = l.transform.w / max(1, l.transform.h)
                        l.transform.h = nv; if lockAspect { l.transform.w = (nv * ar).rounded() }
                    }
                }), step: 1, range: 1...20000)
            }
            HStack(spacing: 6) {
                NumField(label: "∠", value: Binding(get: { t.rotation }, set: { v in model.updateSelected("Rotate", coalesce: "rot") { $0.transform.rotation = v } }), step: 0.5, range: -360...360, decimals: 1, suffix: "°")
                Spacer(minLength: 0)
                ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { model.flip(horizontal: true) }
                ToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { model.flip(horizontal: false) }
                ToolButton(symbol: "rotate.right", help: "Rotate 90°") { model.rotate90() }
            }
        }
    }

    // Kind-specific
    @ViewBuilder func kindSection(_ lb: LayerBinder) -> some View {
        switch layer.kind {
        case .text: textSection(lb)
        case .shape: shapeSection(lb)
        case .source(let ref, let fit): sourceSection(lb, ref, fit)
        case .image(let spec): imageSection(spec)
        case .effect(let e): fxSection(lb, e)
        case .teamBoard(let spec): TeamBoardInspector(model: model, layerID: layer.id, spec: spec)
        case .group(let kids):
            EditorSection("Group", icon: "folder") {
                Text("\(kids.count) layer\(kids.count == 1 ? "" : "s"). Children move, fade and animate together.").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                Button { model.ungroup() } label: { Label("Ungroup", systemImage: "square.2.layers.3d.slash") }.buttonStyle(.studio(.secondary, height: 26))
            }
        }
    }

    func textSection(_ lb: LayerBinder) -> some View {
        EditorSection("Text", icon: "textformat") {
            TextField("Text", text: lb.text(\.string, "Edit text"), axis: .vertical).lineLimit(1...5)
                .textFieldStyle(.plain).font(.system(size: 13)).padding(8)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            HStack {
                Menu {
                    ForEach(SceneVariables.standardKeys, id: \.self) { k in
                        Button("{{\(k)}}") { var s = lb.text(\.string).wrappedValue; s += "{{\(k)}}"; lb.text(\.string, "Insert variable").wrappedValue = s }
                    }
                } label: { Label("Insert variable", systemImage: "curlybraces") }.menuStyle(.borderlessButton).fixedSize().font(Theme.Font.caption)
                Spacer()
            }
            FieldRow(label: "Font") {
                Picker("", selection: lb.text(\.font, "Font")) {
                    ForEach(SceneEditorEnvironment.installedFonts, id: \.self) { f in Text(f).font(.custom(f, size: 12)).tag(f) }
                }.labelsHidden().controlSize(.small)
            }
            HStack(spacing: 6) {
                NumField(label: "Sz", value: lb.text(\.size, "Font size"), step: 1, range: 4...600, suffix: "px")
                NumField(label: "Tr", value: lb.text(\.tracking, "Tracking"), step: 0.2, range: -50...200, decimals: 1)
            }
            SliderRow(label: "Weight", value: lb.text(\.weight, "Weight"), range: 100...900, decimals: 0)
            HStack(spacing: 6) {
                SymbolSegmented(items: [(TextAlign.left, "text.alignleft", "Left"), (.center, "text.aligncenter", "Centre"), (.right, "text.alignright", "Right")], selection: lb.text(\.alignment, "Alignment"))
                ToolButton(symbol: "italic", help: "Italic", active: lb.text(\.italic).wrappedValue) { let b = lb.text(\.italic, "Italic"); b.wrappedValue.toggle() }
                ToolButton(symbol: "textformat.size.larger", help: "All caps", active: lb.text(\.allCaps).wrappedValue) { let b = lb.text(\.allCaps, "Caps"); b.wrappedValue.toggle() }
            }
            ColorRow(label: "Fill", color: lb.text(\.color, "Text colour"))
            GradientRow(label: "Gradient fill", gradient: lb.text(\.gradient, "Text gradient"), base: lb.text(\.color).wrappedValue)
            FieldRow(label: "Stroke") {
                NumField(label: "W", value: Binding(get: { lb.text(\.stroke).wrappedValue.width }, set: { v in var s = lb.text(\.stroke).wrappedValue; s.width = v; lb.text(\.stroke, "Text stroke").wrappedValue = s }), step: 0.5, range: 0...60, decimals: 1)
                ColorPicker("", selection: Binding(get: { lb.text(\.stroke).wrappedValue.color.swiftUI }, set: { c in var s = lb.text(\.stroke).wrappedValue; s.color = RGBA(c); lb.text(\.stroke, "Text stroke").wrappedValue = s })).labelsHidden()
            }
            shadowControls(Binding(get: { lb.text(\.shadow).wrappedValue }, set: { lb.text(\.shadow, "Text shadow").wrappedValue = $0 }), label: "Text shadow")
        }
    }

    func shapeSection(_ lb: LayerBinder) -> some View {
        EditorSection("Shape", icon: "square.on.circle") {
            FieldRow(label: "Type") {
                Picker("", selection: lb.shape(\.kind, "Shape type")) {
                    Text("Rectangle").tag(ShapeKind.rect); Text("Rounded").tag(ShapeKind.roundedRect); Text("Ellipse").tag(ShapeKind.ellipse)
                    Text("Polygon / star").tag(ShapeKind.polygon); Text("Line").tag(ShapeKind.line)
                }.labelsHidden().controlSize(.small)
            }
            let kind = lb.shape(\.kind).wrappedValue
            ColorRow(label: kind == .line ? "Colour" : "Fill", color: Binding(get: { lb.shape(\.fill).wrappedValue.color }, set: { c in var f = lb.shape(\.fill).wrappedValue; f.color = c; lb.shape(\.fill, "Fill").wrappedValue = f }))
            if kind != .line {
                GradientRow(label: "Gradient", gradient: Binding(get: { lb.shape(\.fill).wrappedValue.gradient }, set: { g in var f = lb.shape(\.fill).wrappedValue; f.gradient = g; lb.shape(\.fill, "Fill gradient").wrappedValue = f }), base: lb.shape(\.fill).wrappedValue.color)
                FieldRow(label: "Outline") {
                    NumField(label: "W", value: Binding(get: { lb.shape(\.stroke).wrappedValue.width }, set: { v in var s = lb.shape(\.stroke).wrappedValue; s.width = v; lb.shape(\.stroke, "Outline").wrappedValue = s }), step: 0.5, range: 0...100, decimals: 1)
                    ColorPicker("", selection: Binding(get: { lb.shape(\.stroke).wrappedValue.color.swiftUI }, set: { c in var s = lb.shape(\.stroke).wrappedValue; s.color = RGBA(c); lb.shape(\.stroke, "Outline").wrappedValue = s })).labelsHidden()
                }
            }
            if kind == .roundedRect { SliderRow(label: "Radius", value: lb.shape(\.cornerRadius, "Radius"), range: 0...300, decimals: 0) }
            if kind == .polygon {
                FieldRow(label: "Sides") { Stepper(value: lb.shape(\.sides, "Sides"), in: 3...16) { Text("\(lb.shape(\.sides).wrappedValue)").font(Theme.Font.mono(11)) }.controlSize(.small) }
                SliderRow(label: "Star", value: lb.shape(\.starInset, "Star"), range: 0...0.8)
            }
            if kind == .line { SliderRow(label: "Thickness", value: lb.shape(\.lineWidth, "Thickness"), range: 1...80, decimals: 0) }
        }
    }

    func sourceSection(_ lb: LayerBinder, _ ref: SourceRef, _ fit: SourceFit) -> some View {
        EditorSection("Source", icon: "video") {
            FieldRow(label: "Input") {
                Menu {
                    if !env.app.devices.isEmpty { Section("Phones") { ForEach(env.app.devices) { d in Button(d.name) { setSource(.device(id: d.id), fit) } } } }
                    Section("This Mac") { Button("Webcam") { setSource(.camera, fit) }; Button("Slate / intro") { setSource(.slate, fit) } }
                    if !env.app.props.isEmpty { Section("Props") { ForEach(env.app.props) { p in Button(p.name) { setSource(p.isVideo ? .prop(id: p.id) : .image(id: p.id), fit) } } } }
                } label: { Text(env.sourceName(ref)).lineLimit(1) }.menuStyle(.borderlessButton).controlSize(.small)
            }
            if case .web(let url) = ref {
                TextField("https://… image URL", text: Binding(get: { url }, set: { setSource(.web(url: $0.trimmingCharacters(in: .whitespaces)), fit) }))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }
            Segmented(items: [(SourceFit.fill, "Fill"), (.fit, "Fit"), (.stretch, "Stretch")], selection: Binding(get: { fit }, set: { setSource(ref, $0) }))
            HStack(spacing: 6) {
                Text("Orientation").font(Theme.Font.caption).foregroundStyle(Theme.muted)
                Spacer()
                ToolButton(symbol: "rotate.left", help: "Rotate 90° counter-clockwise") { model.rotate90(clockwise: false) }
                ToolButton(symbol: "rotate.right", help: "Rotate 90° clockwise") { model.rotate90() }
                ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Mirror") { model.flip(horizontal: true) }
            }
        }
    }
    func setSource(_ ref: SourceRef, _ fit: SourceFit) {
        model.updateSelected("Change source") { l in if case .source = l.kind { l.kind = .source(ref, fit: fit) } }
    }

    func imageSection(_ spec: ImageSpec) -> some View {
        EditorSection("Image", icon: "photo") {
            Text(spec.builtin.flatMap { BuiltinAssets.asset($0)?.name } ?? env.app.props.first { $0.id == spec.propId }?.name ?? "Image").font(Theme.Font.body).foregroundStyle(Theme.text)
            Menu {
                ForEach(env.app.props) { p in Button(p.name) { model.updateSelected("Replace image") { l in if case .image = l.kind { l.kind = .image(ImageSpec(propId: p.id)) } } } }
            } label: { Label("Replace with upload…", systemImage: "arrow.triangle.2.circlepath") }.menuStyle(.borderlessButton).fixedSize().font(Theme.Font.caption)
        }
    }

    func fxSection(_ lb: LayerBinder, _ e: EffectSpec) -> some View {
        EditorSection("Effect", icon: "flame") {
            FieldRow(label: "Type") {
                Picker("", selection: lb.fx(\.kind, "Effect type")) { ForEach(EffectKind.allCases, id: \.self) { Text(Self.fxName($0)).tag($0) } }.labelsHidden().controlSize(.small)
            }
            let k = e.kind
            if [.fireEmitter, .embers, .smoke, .sparks, .lightning, .hudCornerBrackets, .radarSweep, .pulsingGlow, .animatedGradient, .killfeedLine].contains(k) {
                ColorRow(label: "Colour", color: lb.fx(\.color, "Effect colour"))
                if [.fireEmitter, .embers, .sparks, .pulsingGlow, .animatedGradient].contains(k) { ColorRow(label: "Outer", color: lb.fx(\.color2, "Effect colour")) }
            }
            SliderRow(label: "Intensity", value: lb.fx(\.intensity, "Intensity"), range: 0...3)
            if ![.hudCornerBrackets, .scanlines, .vignette, .filmGrain].contains(k) { SliderRow(label: "Speed", value: lb.fx(\.speed, "Speed"), range: 0...4) }
            if [.fireEmitter, .embers, .smoke, .sparks].contains(k) {
                SliderRow(label: "Particles", value: Binding(get: { Double(e.count) }, set: { lb.fx(\.count, "Particles").wrappedValue = Int($0) }), range: 10...600, decimals: 0)
                FieldRow(label: "Seed") { Button { lb.fx(\.seed, "Reseed").wrappedValue = UInt32.random(in: 1...9999) } label: { Label("Randomise", systemImage: "dice") }.buttonStyle(.studio(.secondary, height: 22)) }
            }
            if [.scanlines, .vignette, .hudCornerBrackets].contains(k) { SliderRow(label: "Size", value: lb.fx(\.size, "Size"), range: 1...200, decimals: 0) }
            if k == .hudCornerBrackets || k == .radarSweep { SliderRow(label: "Thickness", value: lb.fx(\.thickness, "Thickness"), range: 1...20, decimals: 0) }
            if k == .animatedGradient { SliderRow(label: "Angle", value: lb.fx(\.angle, "Angle"), range: 0...360, decimals: 0) }
            if [.ticker, .countdown, .killfeedLine].contains(k) {
                TextField("Text", text: lb.fx(\.text, "Effect text")).textFieldStyle(.roundedBorder).controlSize(.small)
                SliderRow(label: "Font size", value: lb.fx(\.fontSize, "Font size"), range: 12...200, decimals: 0)
            }
        }
    }
    static func fxName(_ k: EffectKind) -> String {
        switch k {
        case .fireEmitter: "Fire"; case .embers: "Embers"; case .smoke: "Smoke"; case .sparks: "Sparks"; case .lightning: "Lightning"; case .scanlines: "Scanlines"
        case .glitch: "Glitch"; case .vignette: "Vignette"; case .filmGrain: "Film grain"; case .lightSweep: "Light sweep"; case .pulsingGlow: "Pulsing glow"
        case .hudCornerBrackets: "HUD brackets"; case .radarSweep: "Radar"; case .animatedGradient: "Animated gradient"; case .ticker: "Ticker"; case .countdown: "Countdown"; case .killfeedLine: "Kill-feed line"
        }
    }

    // Appearance
    func appearanceSection(_ lb: LayerBinder) -> some View {
        EditorSection("Appearance", icon: "circle.lefthalf.filled") {
            SliderRow(label: "Opacity", value: lb.b(\.opacity, "Opacity"), range: 0...1, percent: true)
            FieldRow(label: "Blend") {
                Picker("", selection: lb.b(\.blend, "Blend mode")) { ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().controlSize(.small)
            }
            SliderRow(label: "Corner", value: lb.b(\.cornerRadius, "Corner radius"), range: 0...400, decimals: 0)
            FieldRow(label: "Mask") {
                Picker("", selection: Binding(get: { layer.mask.kind }, set: { k in model.updateSelected("Mask") { $0.mask.kind = k } })) {
                    Text("None").tag(MaskKind.none); Text("Rounded").tag(MaskKind.roundedRect); Text("Circle").tag(MaskKind.circle)
                    Text("Hexagon").tag(MaskKind.hexagon); Text("Parallelogram").tag(MaskKind.parallelogram)
                }.labelsHidden().controlSize(.small)
            }
            if layer.mask.kind == .parallelogram { SliderRow(label: "Skew", value: Binding(get: { layer.mask.skew }, set: { v in model.updateSelected("Skew", coalesce: "skew") { $0.mask.skew = v } }), range: 0...0.6) }
            if layer.mask.kind != .none { SliderRow(label: "Feather", value: Binding(get: { layer.mask.feather }, set: { v in model.updateSelected("Feather", coalesce: "feather") { $0.mask.feather = v } }), range: 0...60, decimals: 0) }
            DisclosureGroup("Crop") {
                VStack(spacing: 4) {
                    SliderRow(label: "Left", value: Binding(get: { layer.crop.l }, set: { v in model.updateSelected("Crop", coalesce: "cl") { $0.crop.l = v } }), range: 0...0.9)
                    SliderRow(label: "Right", value: Binding(get: { layer.crop.r }, set: { v in model.updateSelected("Crop", coalesce: "cr") { $0.crop.r = v } }), range: 0...0.9)
                    SliderRow(label: "Top", value: Binding(get: { layer.crop.t }, set: { v in model.updateSelected("Crop", coalesce: "ct") { $0.crop.t = v } }), range: 0...0.9)
                    SliderRow(label: "Bottom", value: Binding(get: { layer.crop.b }, set: { v in model.updateSelected("Crop", coalesce: "cb") { $0.crop.b = v } }), range: 0...0.9)
                }.padding(.top, 4)
            }.font(Theme.Font.caption).foregroundStyle(Theme.muted)
            Text("STYLE PRESETS").font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.faint).padding(.top, 2)
            FlowChips(items: LayerFactory.stylePresets.map { ($0.id, $0.name) }) { id in
                if let p = LayerFactory.stylePresets.first(where: { $0.id == id }) { model.updateSelected("Style: \(p.name)") { p.apply(&$0) } }
            }
        }
    }

    func borderSection(_ lb: LayerBinder) -> some View {
        EditorSection("Border", icon: "square.dashed", open: layer.border.width > 0) {
            FieldRow(label: "Width") { NumField(label: "W", value: Binding(get: { layer.border.width }, set: { v in model.updateSelected("Border", coalesce: "bw") { $0.border.width = v } }), step: 0.5, range: 0...200, decimals: 1) }
            ColorRow(label: "Colour", color: Binding(get: { layer.border.color }, set: { c in model.updateSelected("Border colour", coalesce: "bc") { $0.border.color = c } }))
            GradientRow(gradient: Binding(get: { layer.border.gradient }, set: { g in model.updateSelected("Border gradient", coalesce: "bg") { $0.border.gradient = g } }), base: layer.border.color)
        }
    }
    func shadowSection(_ lb: LayerBinder) -> some View {
        EditorSection("Shadow", icon: "shadow", open: layer.shadow.isOn) {
            shadowControls(Binding(get: { layer.shadow }, set: { s in model.updateSelected("Shadow", coalesce: "shadow") { $0.shadow = s } }), label: "Shadow")
        }
    }
    func shadowControls(_ b: Binding<Shadow>, label: String) -> some View {
        VStack(spacing: 6) {
            ColorRow(label: label, color: Binding(get: { b.wrappedValue.color }, set: { var s = b.wrappedValue; s.color = $0; b.wrappedValue = s }))
            HStack(spacing: 6) {
                NumField(label: "B", value: Binding(get: { b.wrappedValue.blur }, set: { var s = b.wrappedValue; s.blur = $0; b.wrappedValue = s }), step: 0.5, range: 0...200, decimals: 1)
                NumField(label: "X", value: Binding(get: { b.wrappedValue.dx }, set: { var s = b.wrappedValue; s.dx = $0; b.wrappedValue = s }), step: 0.5, decimals: 1)
                NumField(label: "Y", value: Binding(get: { b.wrappedValue.dy }, set: { var s = b.wrappedValue; s.dy = $0; b.wrappedValue = s }), step: 0.5, decimals: 1)
            }
        }
    }
    func glowSection(_ lb: LayerBinder) -> some View {
        EditorSection("Glow", icon: "sun.max", open: layer.glow.isOn) {
            ColorRow(label: "Colour", color: Binding(get: { layer.glow.color }, set: { c in model.updateSelected("Glow colour", coalesce: "gc") { $0.glow.color = c } }))
            SliderRow(label: "Radius", value: Binding(get: { layer.glow.radius }, set: { v in model.updateSelected("Glow", coalesce: "gr") { $0.glow.radius = v } }), range: 0...120, decimals: 0)
            SliderRow(label: "Intensity", value: Binding(get: { layer.glow.intensity }, set: { v in model.updateSelected("Glow", coalesce: "gi") { $0.glow.intensity = v } }), range: 0...3)
        }
    }
    func colourSection(_ lb: LayerBinder) -> some View {
        EditorSection("Colour adjust", icon: "paintpalette", open: !layer.colorAdjust.isIdentity, trailing: layer.colorAdjust.isIdentity ? nil : AnyView(
            Button("Reset") { model.updateSelected("Reset colour") { $0.colorAdjust = ColorAdjust() } }.buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent))) {
            SliderRow(label: "Brightness", value: Binding(get: { layer.colorAdjust.brightness }, set: { v in model.updateSelected("Brightness", coalesce: "cab") { $0.colorAdjust.brightness = v } }), range: -1...1)
            SliderRow(label: "Contrast", value: Binding(get: { layer.colorAdjust.contrast }, set: { v in model.updateSelected("Contrast", coalesce: "cac") { $0.colorAdjust.contrast = v } }), range: -1...1)
            SliderRow(label: "Saturation", value: Binding(get: { layer.colorAdjust.saturation }, set: { v in model.updateSelected("Saturation", coalesce: "cas") { $0.colorAdjust.saturation = v } }), range: -1...1)
            SliderRow(label: "Hue", value: Binding(get: { layer.colorAdjust.hue }, set: { v in model.updateSelected("Hue", coalesce: "cah") { $0.colorAdjust.hue = v } }), range: -180...180, decimals: 0)
            FieldRow(label: "Tint") {
                ColorPicker("", selection: Binding(get: { (layer.colorAdjust.tint ?? RGBA(1, 0.5, 0.2, 0)).swiftUI }, set: { c in
                    var r = RGBA(c); if r.a == 0 { r.a = 0.5 }; model.updateSelected("Tint", coalesce: "cat") { $0.colorAdjust.tint = r } }), supportsOpacity: true).labelsHidden()
                if layer.colorAdjust.tint != nil { Button("Clear") { model.updateSelected("Clear tint") { $0.colorAdjust.tint = nil } }.buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent) }
            }
        }
    }
    func chromaSection(_ lb: LayerBinder) -> some View {
        EditorSection("Chroma key", icon: "wand.and.stars", open: layer.chromaKey != nil, trailing: AnyView(
            Toggle("", isOn: Binding(get: { layer.chromaKey != nil }, set: { on in model.updateSelected(on ? "Enable chroma key" : "Disable chroma key") { $0.chromaKey = on ? ChromaKey() : nil } }))
                .toggleStyle(StudioToggleStyle()).labelsHidden())) {
            if let ck = layer.chromaKey {
                ColorRow(label: "Key colour", color: Binding(get: { ck.color }, set: { c in model.updateSelected("Key colour") { $0.chromaKey?.color = c } }))
                SliderRow(label: "Similarity", value: Binding(get: { ck.similarity }, set: { v in model.updateSelected("Similarity", coalesce: "cks") { $0.chromaKey?.similarity = v } }), range: 0...1)
                SliderRow(label: "Smoothness", value: Binding(get: { ck.smoothness }, set: { v in model.updateSelected("Smoothness", coalesce: "ckm") { $0.chromaKey?.smoothness = v } }), range: 0...1)
                SliderRow(label: "Spill", value: Binding(get: { ck.spill }, set: { v in model.updateSelected("Spill", coalesce: "ckp") { $0.chromaKey?.spill = v } }), range: 0...1)
            } else { Text("Remove a green or blue screen behind a camera or phone.").font(Theme.Font.caption).foregroundStyle(Theme.faint) }
        }
    }
    func effectsSection(_ lb: LayerBinder) -> some View {
        EditorSection("Layer effects", icon: "sparkles", open: !layer.effects.isEmpty, trailing: AnyView(
            Menu {
                ForEach(LayerEffectKind.allCases, id: \.self) { k in Button(Self.leName(k)) { model.updateSelected("Add effect") { $0.effects.append(Effect(k)) } } }
            } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize())) {
            if layer.effects.isEmpty { Text("Glitch, scanlines, blur, flicker and more.").font(Theme.Font.caption).foregroundStyle(Theme.faint) }
            ForEach(Array(layer.effects.enumerated()), id: \.offset) { i, e in
                VStack(spacing: 4) {
                    HStack {
                        Toggle("", isOn: Binding(get: { e.enabled }, set: { v in model.updateSelected("Toggle effect") { if $0.effects.indices.contains(i) { $0.effects[i].enabled = v } } })).toggleStyle(StudioToggleStyle()).labelsHidden()
                        Text(Self.leName(e.kind)).font(Theme.Font.bodyBold)
                        Spacer()
                        Button { model.updateSelected("Remove effect") { if $0.effects.indices.contains(i) { $0.effects.remove(at: i) } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.faint)
                    }
                    SliderRow(label: "Amount", value: Binding(get: { e.amount }, set: { v in model.updateSelected("Effect amount", coalesce: "fa\(i)") { if $0.effects.indices.contains(i) { $0.effects[i].amount = v } } }))
                    SliderRow(label: "Speed", value: Binding(get: { e.speed }, set: { v in model.updateSelected("Effect speed", coalesce: "fs\(i)") { if $0.effects.indices.contains(i) { $0.effects[i].speed = v } } }), range: 0...4)
                }.padding(8).background(Theme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    static func leName(_ k: LayerEffectKind) -> String {
        switch k { case .blur: "Blur"; case .chromaticAberration: "Chromatic aberration"; case .glitch: "Glitch"; case .scanlines: "Scanlines"; case .pixelate: "Pixelate"; case .flicker: "Flicker"; case .shake: "Shake" }
    }

    // Animations
    struct AnimPreset: Identifiable { var id: String; var name: String; var make: () -> [Animation] }
    static let animPresets: [AnimPreset] = [
        AnimPreset(id: "fadein", name: "Fade in") { [.fadeIn(0.5)] },
        AnimPreset(id: "slideleft", name: "Slide in from left") { [.slideIn(from: 400, direction: 0, dur: 0.6), .fadeIn(0.4)] },
        AnimPreset(id: "slideright", name: "Slide in from right") { [.slideIn(from: 400, direction: 180, dur: 0.6), .fadeIn(0.4)] },
        AnimPreset(id: "slideup", name: "Slide up") { [.slideIn(from: 200, direction: 90, dur: 0.6), .fadeIn(0.4)] },
        AnimPreset(id: "pop", name: "Pop in") { [Animation(trigger: .onShow, kind: .scale, duration: 0.5, easing: .backOut, from: 0.6, to: 1), .fadeIn(0.3)] },
        AnimPreset(id: "wipe", name: "Wipe reveal") { [Animation(trigger: .onShow, kind: .wipe, duration: 0.7, easing: .easeOut, from: 0, to: 1, direction: 0)] },
        AnimPreset(id: "glitchin", name: "Glitch in") { [Animation(trigger: .onShow, kind: .glitch, duration: 0.6, easing: .linear, from: 1, to: 0), .fadeIn(0.15)] },
        AnimPreset(id: "typewriter", name: "Typewriter") { [Animation(trigger: .onShow, kind: .typewriter, duration: 1.2, easing: .linear, from: 0, to: 1)] },
        AnimPreset(id: "pulse", name: "Pulse (loop)") { [.pulse(period: 1.2, amount: 0.06)] },
        AnimPreset(id: "float", name: "Float (loop)") { [.float(period: 3, amplitude: 8)] },
        AnimPreset(id: "spin", name: "Spin (loop)") { [.spin(period: 8)] },
        AnimPreset(id: "fadeout", name: "Fade out") { [.fadeOut(0.4)] },
    ]
    func animationSection(_ lb: LayerBinder) -> some View {
        EditorSection("Animations", icon: "play.rectangle", open: !layer.animations.isEmpty, trailing: AnyView(HStack(spacing: 8) {
            Button { state.previewClock = 0 } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).foregroundStyle(Theme.accent).help("Preview animations")
            Menu {
                ForEach(Self.animPresets) { p in Button(p.name) { model.updateSelected("Add animation") { $0.animations.append(contentsOf: p.make()) }; state.previewClock = 0 } }
            } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
        })) {
            if layer.animations.isEmpty { Text("In, out and loop animations. Presets with one click.").font(Theme.Font.caption).foregroundStyle(Theme.faint) }
            ForEach(layer.animations) { a in animRow(a) }
        }
    }
    func animRow(_ a: Animation) -> some View {
        func set(_ label: String, coalesce: String? = nil, _ f: @escaping (inout Animation) -> Void) {
            model.updateSelected(label, coalesce: coalesce) { l in if let i = l.animations.firstIndex(where: { $0.id == a.id }) { f(&l.animations[i]) } }
        }
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { a.trigger }, set: { v in set("Animation trigger") { $0.trigger = v } })) {
                    Text("In").tag(AnimTrigger.onShow); Text("Out").tag(AnimTrigger.onHide); Text("Loop").tag(AnimTrigger.loop); Text("On take").tag(AnimTrigger.onTake)
                }.labelsHidden().controlSize(.small).frame(width: 74)
                Picker("", selection: Binding(get: { a.kind }, set: { v in set("Animation type") { $0.kind = v } })) {
                    ForEach(AnimKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.labelsHidden().controlSize(.small)
                Button { model.updateSelected("Remove animation") { $0.animations.removeAll { $0.id == a.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 6) {
                NumField(label: "D", value: Binding(get: { a.duration }, set: { v in set("Duration", coalesce: "ad") { $0.duration = max(0.05, v) } }), step: 0.05, range: 0.05...30, decimals: 2, suffix: "s")
                NumField(label: "⏱", value: Binding(get: { a.delay }, set: { v in set("Delay", coalesce: "adl") { $0.delay = max(0, v) } }), step: 0.05, range: 0...30, decimals: 2, suffix: "s")
            }
            HStack(spacing: 6) {
                NumField(label: "↦", value: Binding(get: { a.from }, set: { v in set("Animation from", coalesce: "af") { $0.from = v } }), step: 0.05, decimals: 2)
                NumField(label: "⇥", value: Binding(get: { a.to }, set: { v in set("Animation to", coalesce: "at") { $0.to = v } }), step: 0.05, decimals: 2)
            }
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { a.easing }, set: { v in set("Easing") { $0.easing = v } })) {
                    ForEach(Easing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().controlSize(.small)
                if [.slide, .wipe, .float].contains(a.kind) {
                    NumField(label: "∠", value: Binding(get: { a.direction }, set: { v in set("Direction", coalesce: "adir") { $0.direction = v } }), step: 5, range: -360...360, suffix: "°")
                }
            }
        }.padding(8).background(Theme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct FlowChips: View {
    var items: [(String, String)]
    var action: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.0) { it in
                Button { action(it.0) } label: {
                    Text(it.1).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(height: 22)
                        .background(Color.white.opacity(0.07), in: Capsule()).overlay(Capsule().strokeBorder(Theme.stroke))
                }.buttonStyle(.plain).foregroundStyle(Theme.text)
            }
        }
    }
}

/// Simple wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - scene inspector (nothing selected)

struct SceneInspector: View {
    var model: SceneEditorModel
    var env: SceneEditorEnvironment
    @State private var newKey = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.scene.name).font(Theme.Font.bodyBold).lineLimit(1)
                    Text("Scene · \(model.scene.canvas.w)×\(model.scene.canvas.h)").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                }
                Spacer()
            }.padding(.horizontal, 12).frame(height: 44).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
            backgroundSection
            transitionSection
            variablesSection
        }
    }
    var backgroundSection: some View {
        let bg = model.scene.background
        return EditorSection("Background", icon: "rectangle.fill") {
            FieldRow(label: "Type") {
                Picker("", selection: Binding(get: { bg.kind }, set: { k in
                    var b = bg; b.kind = k
                    if (k == .linearGradient || k == .radialGradient), b.gradient == nil { b.gradient = Gradient.linear(RGBA(hex: 0x1A0A05), RGBA(hex: 0x06090C), angle: 90) }
                    model.setBackground(b) })) {
                    Text("Solid").tag(BackgroundKind.solid); Text("Linear gradient").tag(BackgroundKind.linearGradient); Text("Radial gradient").tag(BackgroundKind.radialGradient)
                    Text("Image").tag(BackgroundKind.image); Text("Video").tag(BackgroundKind.video)
                }.labelsHidden().controlSize(.small)
            }
            ColorRow(label: "Colour", color: Binding(get: { bg.color }, set: { c in model.edit("Background colour", coalesce: "bgc") { $0.background.color = c } }))
            if bg.kind == .linearGradient || bg.kind == .radialGradient {
                GradientRow(gradient: Binding(get: { bg.gradient }, set: { g in model.edit("Background gradient", coalesce: "bgg") { $0.background.gradient = g } }), base: bg.color)
            }
            if bg.kind == .image || bg.kind == .video {
                FieldRow(label: "Prop") {
                    Picker("", selection: Binding(get: { bg.propId ?? "" }, set: { v in model.edit("Background prop") { $0.background.propId = v.isEmpty ? nil : v } })) {
                        Text("None").tag("")
                        ForEach(env.app.props.filter { bg.kind == .video ? $0.isVideo : !$0.isVideo }) { Text($0.name).tag($0.id) }
                    }.labelsHidden().controlSize(.small)
                }
                SliderRow(label: "Dim", value: Binding(get: { bg.dim }, set: { v in model.edit("Dim", coalesce: "bgd") { $0.background.dim = v } }), percent: true)
            }
        }
    }
    func transitionControls(_ label: String, _ t: SceneTransition?, _ set: @escaping (SceneTransition?) -> Void) -> some View {
        let cur = t ?? SceneTransition(.fade)
        return VStack(alignment: .leading, spacing: 6) {
            FieldRow(label: label) {
                Picker("", selection: Binding(get: { t == nil ? "default" : cur.kind.rawValue }, set: { v in
                    if v == "default" { set(nil) } else if let k = SceneTransitionKind(rawValue: v) { var n = cur; n.kind = k; if k == .cut { n.duration = 0 } else if n.duration == 0 { n.duration = 0.4 }; set(n) }
                })) {
                    Text("Default").tag("default")
                    Text("Cut").tag("cut"); Text("Fade").tag("fade"); Text("Slide").tag("slide"); Text("Zoom").tag("zoom")
                    Text("Wipe").tag("wipe"); Text("Stinger (fire wipe)").tag("stinger")
                }.labelsHidden().controlSize(.small)
            }
            if t != nil, cur.kind != .cut {
                SliderRow(label: "Duration", value: Binding(get: { cur.duration }, set: { v in var n = cur; n.duration = v; set(n) }), range: 0.1...3, decimals: 1)
                if cur.kind == .slide || cur.kind == .wipe {
                    SliderRow(label: "Direction", value: Binding(get: { cur.direction }, set: { v in var n = cur; n.direction = v; set(n) }), range: 0...360, decimals: 0)
                }
                if cur.kind == .stinger {
                    FieldRow(label: "Stinger") {
                        Picker("", selection: Binding(get: { cur.stingerPropId ?? "" }, set: { v in var n = cur; n.stingerPropId = v.isEmpty ? nil : v; set(n) })) {
                            Text("Built-in fire wipe").tag("")
                            ForEach(env.app.props.filter(\.isVideo)) { Text($0.name).tag($0.id) }
                        }.labelsHidden().controlSize(.small)
                    }
                }
            }
        }
    }
    var transitionSection: some View {
        EditorSection("Transition", icon: "arrow.left.arrow.right") {
            transitionControls("In", model.scene.transitionIn) { n in model.edit("Transition in") { $0.transitionIn = n } }
            transitionControls("Out", model.scene.transitionOut) { n in model.edit("Transition out") { $0.transitionOut = n } }
            Text("Used when this scene is taken to program.").font(Theme.Font.caption).foregroundStyle(Theme.faint)
        }
    }
    var variablesSection: some View {
        let keys = SceneVariables.standardKeys + model.scene.variableDefaults.keys.filter { !SceneVariables.standardKeys.contains($0) }.sorted()
        return EditorSection("Variables", icon: "curlybraces") {
            Text("Use {{name}} inside any text layer.").font(Theme.Font.caption).foregroundStyle(Theme.faint)
            ForEach(keys, id: \.self) { k in
                FieldRow(label: k, labelWidth: 78) {
                    TextField("", text: Binding(get: { model.variables[k] ?? model.scene.variableDefaults[k] ?? "" }, set: { v in
                        model.variables[k] = v
                        model.edit("Variable \(k)", coalesce: "var\(k)") { $0.variableDefaults[k] = v }
                    })).textFieldStyle(.roundedBorder).controlSize(.small)
                }
            }
            HStack {
                TextField("new variable", text: $newKey).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("Add") {
                    let k = newKey.trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty { model.edit("Add variable") { $0.variableDefaults[k] = $0.variableDefaults[k] ?? "" }; newKey = "" }
                }.controlSize(.small).disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button { env.pullFromABG(into: model) } label: { Label("Pull from AirBattleground match", systemImage: "arrow.down.circle") }
                .buttonStyle(.studio(.secondary, height: 26)).disabled(!env.abgMatchAvailable)
                .help(env.abgMatchAvailable ? "Fill {{team1}} {{team2}} {{matchTitle}} from the selected match" : "Connect AirBattleground and pick a match first")
        }
    }
}
