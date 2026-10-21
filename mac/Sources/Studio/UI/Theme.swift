import SwiftUI
import AppKit

// MARK: - Design tokens

enum Theme {
    // Surfaces (dark-first, slightly cool neutral ramp)
    static let bg = Color(red: 0.067, green: 0.070, blue: 0.082)          // window / canvas
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.118)        // panels
    static let panelHi = Color(red: 0.135, green: 0.141, blue: 0.161)      // raised cards
    static let well = Color(red: 0.045, green: 0.047, blue: 0.056)         // inset wells, monitors
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.14)
    // Text
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.34)
    // Semantic
    static let accent = Color(red: 0.30, green: 0.55, blue: 1.0)
    static let program = Color(red: 1.0, green: 0.22, blue: 0.22)          // tally red: on air
    static let preview = Color(red: 0.18, green: 0.82, blue: 0.40)         // tally green: next up
    static let ok = Color(red: 0.25, green: 0.80, blue: 0.50)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)

    // Spacing / radius
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    enum Radius { static let s: CGFloat = 5, m: CGFloat = 8, l: CGFloat = 12 }

    // Typography: SF Pro for UI, SF Mono for timecode and numbers.
    enum Font {
        static let title = SwiftUI.Font.system(size: 22, weight: .bold)
        static let heading = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyBold = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11)
        static let label = SwiftUI.Font.system(size: 10, weight: .bold)
        static func mono(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font { .system(size: size, weight: weight, design: .monospaced) }
    }
}

// MARK: - Surfaces

struct CardModifier: ViewModifier {
    var fill: Color = Theme.panel
    var radius: CGFloat = Theme.Radius.l
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
    }
}
extension View {
    func card(fill: Color = Theme.panel, radius: CGFloat = Theme.Radius.l) -> some View { modifier(CardModifier(fill: fill, radius: radius)) }
}

/// Panel with an uppercase header bar and optional trailing accessory.
struct Panel<Trailing: View, Content: View>: View {
    var title: String; var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted) }
                Text(title.uppercased()).font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Theme.Space.m).frame(height: 32)
            Divider().overlay(Theme.stroke)
            VStack(alignment: .leading, spacing: Theme.Space.s) { content }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }
}
extension Panel where Trailing == EmptyView {
    init(title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, trailing: { EmptyView() }, content: content)
    }
}

/// Legacy name used by older panels.
struct PanelBox<Content: View, Action: View>: View {
    let title: String; let icon: String
    @ViewBuilder var action: Action
    @ViewBuilder var content: Content
    var body: some View { Panel(title: title, icon: icon, trailing: { action }, content: { content }) }
}
extension PanelBox where Action == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, action: { EmptyView() }, content: content)
    }
}

struct SectionHeader: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.faint)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    var icon: String; var title: String; var message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.faint)
            Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text)
            Text(message).font(Theme.Font.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(Theme.Space.xl)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Badges

struct Pill: View {
    var text: String; var color: Color = Theme.muted; var filled = false; var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .bold)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 7).frame(height: 18)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.15), in: Capsule())
    }
}
/// Legacy name.
struct Chip: View {
    var text: String; var color: Color = .white.opacity(0.7); var filled = false
    var body: some View { Pill(text: text, color: color, filled: filled) }
}

/// 8 pt status dot. The pulse is a Core Animation opacity animation (runs in the render server), not a SwiftUI repeatForever,
/// so a pulsing LIVE/REC dot costs the main thread nothing per frame.
struct StatusDot: View {
    var color: Color; var pulse = false
    var body: some View {
        if pulse { PulseDot(color: color).frame(width: 8, height: 8) }
        else { Circle().fill(color).frame(width: 8, height: 8) }
    }
}

private struct PulseDot: NSViewRepresentable {
    var color: Color
    final class V: NSView {
        let dot = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dot.cornerRadius = 4; dot.shadowRadius = 4; dot.shadowOpacity = 0.9; dot.shadowOffset = .zero
            layer?.addSublayer(dot)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, dot.animation(forKey: "pulse") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.35; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(a, forKey: "pulse")
            }
        }
        func set(_ c: NSColor) { dot.backgroundColor = c.cgColor; dot.shadowColor = c.cgColor }
    }
    func makeNSView(context: Context) -> V { let v = V(frame: NSRect(x: 0, y: 0, width: 8, height: 8)); v.set(NSColor(color)); return v }
    func updateNSView(_ v: V, context: Context) { v.set(NSColor(color)) }
}

/// Keyboard-number badge.
struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.Font.mono(10, .bold)).foregroundStyle(Theme.text)
            .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.2)))
    }
}

// MARK: - Meters

/// Segmented audio meter (green / amber / red), horizontal or vertical. `level` is 0...1 linear peak.
struct MeterBar: View {
    var level: Float
    var vertical = true
    var segments = 24
    var body: some View {
        let lit = Int((CGFloat(max(0, min(1, level)).squareRoot()) * CGFloat(segments)).rounded())
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 1.5)) : AnyLayout(HStackLayout(spacing: 1.5))
        layout {
            ForEach(0..<segments, id: \.self) { i in
                let idx = vertical ? segments - 1 - i : i          // 0 = quietest
                let frac = Double(idx) / Double(segments)
                RoundedRectangle(cornerRadius: 1)
                    .fill((frac > 0.88 ? Theme.program : frac > 0.7 ? Theme.warn : Theme.ok).opacity(idx < lit ? 1 : 0.14))
            }
        }
        .animation(.linear(duration: 0.06), value: lit)
        .accessibilityLabel("Audio level").accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - Buttons

enum StudioButtonKind { case primary(Color), secondary, ghost }

struct StudioButtonStyle: ButtonStyle {
    var kind: StudioButtonKind = .secondary
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let p = configuration.isPressed
        let (fg, bg, border): (Color, Color, Color) = {
            switch kind {
            case .primary(let c): return (.white, c.opacity(p ? 0.75 : hover ? 1.0 : 0.9), c.opacity(0.0))
            case .secondary: return (Theme.text, Color.white.opacity(p ? 0.16 : hover ? 0.12 : 0.08), Theme.stroke)
            case .ghost: return (Theme.text, Color.white.opacity(p ? 0.12 : hover ? 0.07 : 0), .clear)
            }
        }()
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 12).frame(minHeight: height)
            .background(bg, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(border))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(p ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: p)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 }
    }
}
extension ButtonStyle where Self == StudioButtonStyle {
    static func studio(_ k: StudioButtonKind = .secondary, height: CGFloat = 30) -> StudioButtonStyle { StudioButtonStyle(kind: k, height: height) }
}

/// Primary call-to-action button.
struct PrimaryButton: View {
    var title: String; var icon: String? = nil; var color: Color = Theme.accent
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let icon { Image(systemName: icon) }; Text(title) }.frame(maxWidth: .infinity)
        }.buttonStyle(.studio(.primary(color)))
    }
}

struct IconButton: View {
    var systemName: String; var label: String; var size: CGFloat = 26; var tint: Color = Theme.muted
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(Color.white.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(label).accessibilityLabel(label)
    }
}

struct StudioToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label.font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.16)).frame(width: 30, height: 18)
                    Circle().fill(.white).frame(width: 14, height: 14).padding(2).shadow(radius: 1, y: 1)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Misc

/// Mini schematic of a layout.
struct LayoutIcon: View {
    var layout: LayoutKind
    static func rects(_ l: LayoutKind) -> [CGRect] {
        switch l {
        case .full: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .side: return [CGRect(x: 0.02, y: 0.25, width: 0.47, height: 0.5), CGRect(x: 0.51, y: 0.25, width: 0.47, height: 0.5)]
        case .pip: return [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0.62, y: 0.65, width: 0.34, height: 0.31)]
        case .desk: return [CGRect(x: 0.02, y: 0.03, width: 0.64, height: 0.62), CGRect(x: 0.68, y: 0.03, width: 0.30, height: 0.62)]
        case .trio: return [CGRect(x: 0.02, y: 0.03, width: 0.6, height: 0.94), CGRect(x: 0.64, y: 0.03, width: 0.34, height: 0.45), CGRect(x: 0.64, y: 0.52, width: 0.34, height: 0.45)]
        }
    }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.07))
                ForEach(Array(Self.rects(layout).enumerated()), id: \.offset) { i, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 0 ? Theme.accent.opacity(0.7) : Theme.warn.opacity(0.8))
                        .frame(width: r.width * g.size.width, height: r.height * g.size.height)
                        .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension LayoutKind {
    var label: String {
        switch self { case .full: "Full screen"; case .side: "Side by side"; case .pip: "Picture in picture"; case .desk: "Host desk"; case .trio: "One big, two small" }
    }
    var slotNames: [String] {
        switch self { case .full: ["Main"]; case .side: ["Left", "Right"]; case .pip: ["Main", "Inset"]; case .desk: ["Game", "Host"]; case .trio: ["Big", "Top", "Bottom"] }
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
