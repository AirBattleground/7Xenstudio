// Small reusable inspector controls in the Studio dark style.
import SwiftUI
import AppKit

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
    }
}

struct EditorSection<Content: View>: View {
    var title: String; var icon: String
    @State var open: Bool
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    init(_ title: String, icon: String, open: Bool = true, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; _open = State(initialValue: open); self.trailing = trailing; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Theme.faint).frame(width: 10)
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(title.uppercased()).font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
                .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider().overlay(Theme.stroke)
        }
    }
}

struct FieldRow<Content: View>: View {
    var label: String; var labelWidth: CGFloat = 78
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .leading).lineLimit(1)
            content
        }
    }
}

/// Number box with a scrub label (drag the label left/right to change the value).
struct NumField: View {
    var label: String
    @Binding var value: Double
    var step: Double = 1
    var range: ClosedRange<Double> = -100_000...100_000
    var decimals = 0
    var suffix = ""
    @State private var scrubBase: Double?
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint).frame(width: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                    if scrubBase == nil { scrubBase = value }
                    let v = (scrubBase ?? value) + Double(g.translation.width) * step * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)
                    value = min(range.upperBound, max(range.lowerBound, decimals == 0 ? v.rounded() : v))
                }.onEnded { _ in scrubBase = nil })
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            TextField("", value: $value, format: .number.precision(.fractionLength(0...max(decimals, 0))))
                .textFieldStyle(.plain).font(Theme.Font.mono(11)).multilineTextAlignment(.trailing)
            if !suffix.isEmpty { Text(suffix).font(.system(size: 9)).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct SliderRow: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var decimals = 2
    var percent = false
    var body: some View {
        FieldRow(label: label) {
            Slider(value: $value, in: range).controlSize(.small).tint(Theme.accent)
            Text(percent ? "\(Int((value * 100).rounded()))%" : String(format: "%.\(decimals)f", value))
                .font(Theme.Font.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 40, alignment: .trailing)
        }
    }
}

struct ColorRow: View {
    var label: String
    @Binding var color: RGBA
    var body: some View {
        FieldRow(label: label) {
            ColorPicker("", selection: Binding(get: { color.swiftUI }, set: { color = RGBA($0) }), supportsOpacity: true).labelsHidden()
            Text(String(format: "#%02X%02X%02X", Int(color.r * 255), Int(color.g * 255), Int(color.b * 255))).font(Theme.Font.mono(10.5)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
    }
}

/// Optional gradient with up to 4 stops. When off, `gradient` is nil.
struct GradientRow: View {
    var label = "Gradient"
    @Binding var gradient: Gradient?
    var base: RGBA
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldRow(label: label) {
                Toggle("", isOn: Binding(get: { gradient != nil }, set: { on in
                    gradient = on ? Gradient.linear(base, RGBA(base.r * 0.4, base.g * 0.4, base.b * 0.4), angle: 90) : nil
                })).toggleStyle(StudioToggleStyle()).labelsHidden()
                if let g = gradient {
                    RoundedRectangle(cornerRadius: 4).fill(LinearGradient(stops: g.stops.map { .init(color: $0.color.swiftUI, location: $0.pos) }, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 16).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
                }
            }
            if let g = gradient {
                ForEach(Array(g.stops.enumerated()), id: \.offset) { i, st in
                    FieldRow(label: i == 0 ? "Stops" : "") {
                        ColorPicker("", selection: Binding(get: { st.color.swiftUI }, set: { c in var n = g; n.stops[i].color = RGBA(c); gradient = n }), supportsOpacity: true).labelsHidden()
                        Slider(value: Binding(get: { st.pos }, set: { v in var n = g; n.stops[i].pos = v; gradient = n }), in: 0...1).controlSize(.small)
                        if g.stops.count > 2 { Button { var n = g; n.stops.remove(at: i); gradient = n } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
                    }
                }
                HStack(spacing: 8) {
                    NumField(label: "∠", value: Binding(get: { g.angle }, set: { v in var n = g; n.angle = v; gradient = n }), step: 1, range: -360...360, suffix: "°").frame(width: 84)
                    Picker("", selection: Binding(get: { g.radial }, set: { v in var n = g; n.radial = v; gradient = n })) {
                        Text("Linear").tag(false); Text("Radial").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    if g.stops.count < 4 {
                        Button { var n = g; n.stops.append(GradientStop(1, n.stops.last?.color ?? .white)); n.stops = n.stops.enumerated().map { GradientStop(Double($0.offset) / Double(max(1, n.stops.count - 1)), $0.element.color) }; gradient = n } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Add colour stop")
                    }
                }
            }
        }
    }
}

struct Segmented<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { selection = it.0 } label: {
                    Text(it.1).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundStyle(selection == it.0 ? Theme.text : Theme.muted)
                        .background(selection == it.0 ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }.buttonStyle(.plain)
            }
        }.padding(2).background(Theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SymbolSegmented<T: Hashable>: View {
    var items: [(T, String, String)]    // value, symbol, help
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { selection = it.0 } label: {
                    Image(systemName: it.1).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundStyle(selection == it.0 ? Theme.text : Theme.muted)
                        .background(selection == it.0 ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }.buttonStyle(.plain).help(it.2)
            }
        }.padding(2).background(Theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct ToolButton: View {
    var symbol: String; var help: String
    var active = false
    var enabled = true
    var size: CGFloat = 26
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Theme.accent : (enabled ? Theme.text : Theme.faint))
                .background(active ? Theme.accent.opacity(0.18) : (hover && enabled ? Color.white.opacity(0.08) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).onHover { hover = $0 }.help(help).accessibilityLabel(help)
    }
}

struct BarDivider: View { var body: some View { Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 3) } }
