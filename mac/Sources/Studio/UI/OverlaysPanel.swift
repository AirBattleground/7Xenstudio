import SwiftUI

/// Lets the overlay panel list image props without depending on the props library UI. Set by RealServices.
@MainActor enum OverlayPropCatalog { static var imageProps: () -> [(id: String, name: String)] = { [] } }

struct OverlaysPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var m = model
        let props = OverlayPropCatalog.imageProps()
        Panel(title: "Overlays", icon: "square.stack.3d.up") {
            Toggle("LIVE bug + clock", isOn: $m.overlays.liveBug)
            Toggle("Lower third (name strip)", isOn: $m.overlays.lowerThird)
            if m.overlays.lowerThird {
                TextField("Name, e.g. Alex", text: $m.overlays.lowerTitle).textFieldStyle(.roundedBorder)
                TextField("Role, e.g. Caster", text: $m.overlays.lowerSubtitle).textFieldStyle(.roundedBorder)
            }
            Toggle("Ticker (scrolling text)", isOn: $m.overlays.ticker)
            if m.overlays.ticker { TextField("Next match at 9 PM · Follow us", text: $m.overlays.tickerText).textFieldStyle(.roundedBorder) }

            Toggle("Logo", isOn: $m.overlays.logo.on)
            if m.overlays.logo.on {
                if props.isEmpty {
                    Text("Add an image in Props, then pick it here.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Picker("Image", selection: $m.overlays.logo.propId) {
                        Text("None").tag(String?.none)
                        ForEach(props, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                Picker("Corner", selection: $m.overlays.logo.corner) {
                    Text("Top left").tag(OverlayCorner.tl); Text("Top right").tag(OverlayCorner.tr)
                    Text("Bottom left").tag(OverlayCorner.bl); Text("Bottom right").tag(OverlayCorner.br)
                }
                LabeledContent("Size") { Slider(value: $m.overlays.logo.size, in: 60...400) }
                LabeledContent("Opacity") { Slider(value: $m.overlays.logo.opacity, in: 0.1...1) }
            }

            Toggle("Web image (scoreboard)", isOn: $m.overlays.web.on)
            if m.overlays.web.on {
                TextField("https://example.com/scoreboard.png", text: $m.overlays.web.url).textFieldStyle(.roundedBorder)
                Text("A transparent PNG at this address, refreshed every 2 seconds.").font(.caption).foregroundStyle(Theme.muted)
                LabeledContent("Left") { Slider(value: $m.overlays.web.x, in: 0...0.9) }
                LabeledContent("Top") { Slider(value: $m.overlays.web.y, in: 0...0.9) }
                LabeledContent("Width") { Slider(value: $m.overlays.web.w, in: 0.1...1) }
                LabeledContent("Height") { Slider(value: $m.overlays.web.h, in: 0.1...1) }
                LabeledContent("Opacity") { Slider(value: $m.overlays.web.opacity, in: 0.1...1) }
                Button("Full frame") { m.overlays.web.x = 0; m.overlays.web.y = 0; m.overlays.web.w = 1; m.overlays.web.h = 1 }.controlSize(.small)
            }
        }
        .toggleStyle(StudioToggleStyle())
    }
}
