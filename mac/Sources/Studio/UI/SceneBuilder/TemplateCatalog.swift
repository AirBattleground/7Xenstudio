// Template gallery model: the built-in "Battleground Pro" pack plus the operator's own saved templates.
import Foundation

struct TemplateItem: Identifiable {
    var id: String
    var name: String
    var category: String
    var isUser = false
    var build: (PropTheme) -> LayerScene
}

enum TemplateCatalog {
    static func category(for t: PropTemplate) -> String {
        let known = ["Full screen", "Split", "Intro", "Starting soon", "Be right back", "Outro", "Scoreboard", "Lower thirds", "Gameplay", "Interview"]
        for tag in t.tags { if let k = known.first(where: { $0.lowercased() == tag.lowercased() }) { return k } }
        return (t.tags.first ?? "Battleground").capitalized
    }
    static func all(repo: LayerSceneRepository) -> [TemplateItem] {
        var out: [TemplateItem] = [
            TemplateItem(id: "blank", name: "Blank scene", category: "Basics") { _ in
                LayerScene(name: "Blank", background: .solid(RGBA(hex: 0x06090C)), layers: [])
            }
        ]
        for t in Templates.all {
            out.append(TemplateItem(id: t.id, name: t.name, category: category(for: t)) { theme in
                Templates.make(t.id, theme: theme) ?? LayerScene(name: t.name)
            })
        }
        for u in repo.myTemplates() {
            out.append(TemplateItem(id: u.id, name: u.name, category: "My Templates", isUser: true) { _ in
                var s = u; s.layers = s.layers.map(LayerTree.clone); return s
            })
        }
        return out
    }
}
