// First-run scenes: the Battleground Pro templates, wired to this studio's phones and Mac camera.
import Foundation

enum StarterScenes {
    /// (scene id, template id, name shown to the operator)
    static let defs: [(id: String, template: String, name: String)] = [
        ("starter-startingsoon", "bgp.startingsoon", "Starting Soon"),
        ("starter-main", "bgp.maingame", "Main Game + Facecam"),
        ("starter-squad4", "bgp.squad4", "Squad 4-Phone Grid"),
        ("starter-brb", "bgp.brb", "BRB"),
        ("starter-winner", "bgp.winner", "Winner"),
    ]
    /// Scenes carrying this variable default get empty phone slots filled whenever a phone is paired.
    static let autoKey = "_autoAssign"

    static func make(deviceIDs: [String], theme: PropTheme = .ember) -> [LayerScene] {
        defs.compactMap { d in
            guard var s = Templates.make(d.template, theme: theme) else { return nil }
            s.id = d.id; s.name = d.name; s.migratedFrom = nil
            s.variableDefaults[autoKey] = "1"
            _ = assign(&s, deviceIDs: deviceIDs)
            return s
        }
    }

    /// Phone slots (`.device("")`) take the paired phones in order; a template's "Gameplay" slate becomes the first phone. Facecam stays this Mac's camera.
    /// Returns true when something changed.
    @discardableResult
    static func assign(_ s: inout LayerScene, deviceIDs: [String]) -> Bool {
        guard !deviceIDs.isEmpty else { return false }
        var next = 0, changed = false
        func walk(_ ls: inout [Layer]) {
            for i in ls.indices {
                if case .group(var c) = ls[i].kind { walk(&c); ls[i].kind = .group(c); continue }
                guard case .source(let ref, let fit) = ls[i].kind else { continue }
                if case .device(let id) = ref, id.isEmpty, next < deviceIDs.count {
                    ls[i].kind = .source(.device(id: deviceIDs[next]), fit: fit); next += 1; changed = true
                } else if ref == .slate, ls[i].name == "Gameplay" {
                    ls[i].kind = .source(.device(id: deviceIDs[0]), fit: fit); changed = true
                }
            }
        }
        walk(&s.layers)
        return changed
    }
}
