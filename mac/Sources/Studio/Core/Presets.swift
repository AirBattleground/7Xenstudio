import Foundation

// Studio presets: a named set of scenes (own list + order), a match-journey mapping (JourneyStage -> scene id)
// and optional default overlays. The operator streams with the ACTIVE preset: the Studio strip, hotkeys and New Scene
// work within it. A scene can belong to several presets; deleting a scene removes it from all of them.
// Stored in store.json (`presets`, `activePresetId`), lenient decoding, migrated once from the existing scene list.

struct StudioPreset: Codable, Identifiable, Hashable {
    static let builtinDefault = "opusDefault", builtinAdvanced = "opusAdvanced"

    var id: String
    var name: String
    var sceneIds: [String] = []
    /// JourneyStage.rawValue -> scene id
    var journey: [String: String] = [:]
    /// Overlays applied when the preset becomes active (nil = keep whatever is on).
    var overlays: Overlays? = nil
    /// `builtinDefault` / `builtinAdvanced` for the two built-in presets, nil for the operator's own.
    var builtin: String? = nil
    /// The built-in scenes were inserted once; never reseeded after the operator deletes them.
    var seeded: Bool? = nil
    /// additive: built-in scenes added to the preset after its first seed (e.g. the YouTube Thumbnail), each inserted once by id.
    var seededAdditions: [String]? = nil
    var createdAt: String = isoNow()

    init(id: String = newId("pr"), name: String, sceneIds: [String] = [], journey: [String: String] = [:], overlays: Overlays? = nil, builtin: String? = nil) {
        self.id = id; self.name = name; self.sceneIds = sceneIds; self.journey = journey; self.overlays = overlays; self.builtin = builtin
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.lenient(.id, newId("pr")); name = c.lenient(.name, "Preset")
        sceneIds = c.lenient(.sceneIds, [String]()); journey = c.lenient(.journey, [String: String]())
        overlays = c.lenientOpt(.overlays); builtin = c.lenientOpt(.builtin); seeded = c.lenientOpt(.seeded)
        seededAdditions = c.lenientOpt(.seededAdditions)
        createdAt = c.lenient(.createdAt, isoNow())
    }
    private enum K: String, CodingKey { case id, name, sceneIds, journey, overlays, builtin, seeded, seededAdditions, createdAt }

    func scene(for stage: JourneyStage) -> String? { journey[stage.rawValue] }
    mutating func setScene(_ id: String?, for stage: JourneyStage) { journey[stage.rawValue] = id }
    /// Drops a scene from the list and from every journey stage that used it.
    mutating func removeScene(_ id: String) {
        sceneIds.removeAll { $0 == id }
        for (k, v) in journey where v == id { journey[k] = nil }
    }
}

/// Why a scene cannot simply be deleted.
enum SceneDeleteBlock: Equatable { case onAir }

/// All presets + the active one. Pure value type: every rule lives here (tested in PresetTests).
struct PresetBook: Equatable {
    var presets: [StudioPreset] = []
    var activeId: String? = nil

    var active: StudioPreset? { presets.first { $0.id == activeId } ?? presets.first }
    func preset(_ id: String) -> StudioPreset? { presets.first { $0.id == id } }
    private func index(_ id: String?) -> Int? { presets.firstIndex { $0.id == id } }
    func presets(containing sceneId: String) -> [StudioPreset] { presets.filter { $0.sceneIds.contains(sceneId) } }

    // MARK: migration

    /// Launch-time housekeeping. No presets yet: every existing scene goes into "OPUS Studio Default" (made active).
    /// "OPUS Advanced Studio" is added (empty) when missing. Scene ids that no longer exist are dropped. Returns true when changed.
    @discardableResult
    mutating func migrate(scenes: [(id: String, name: String)]) -> Bool {
        let before = self
        if presets.isEmpty {
            let ids = scenes.map(\.id)
            presets.append(StudioPreset(name: PresetNames.opusDefault, sceneIds: ids, journey: Self.guessJourney(scenes), builtin: StudioPreset.builtinDefault))
            activeId = presets[0].id
        }
        if !presets.contains(where: { $0.builtin == StudioPreset.builtinAdvanced || $0.name == PresetNames.opusAdvanced }) {
            presets.append(StudioPreset(name: PresetNames.opusAdvanced, builtin: StudioPreset.builtinAdvanced))
        }
        prune(validIds: Set(scenes.map(\.id)))
        if index(activeId) == nil { activeId = presets.first?.id }
        return self != before
    }

    /// Name-based first guess of the journey mapping for existing scenes ("Starting soon" -> starts in, "Game play" -> gameplay ...).
    static func guessJourney(_ scenes: [(id: String, name: String)]) -> [String: String] {
        let rules: [(JourneyStage, [String])] = [
            (.startsIn, ["starting", "starts in", "countdown", "soon", "pre-match", "prematch"]),
            (.gameplay, ["game play", "gameplay", "game-play", "in-game", "ingame"]),
            (.summary, ["summary", "result", "standing", "leaderboard", "points table"]),
            (.winner, ["winner", "champion", "chicken dinner", "victory"])]
        var out: [String: String] = [:]
        var used = Set<String>()
        for (stage, words) in rules {
            if let s = scenes.first(where: { s in !used.contains(s.id) && words.contains { s.name.lowercased().contains($0) } }) {
                out[stage.rawValue] = s.id; used.insert(s.id)
            }
        }
        return out
    }

    /// Removes scene ids that do not exist any more (from lists and journeys). Returns true when changed.
    @discardableResult
    mutating func prune(validIds: Set<String>) -> Bool {
        var changed = false
        for i in presets.indices {
            let gone = Set(presets[i].sceneIds).union(presets[i].journey.values).subtracting(validIds)
            for id in gone { presets[i].removeScene(id); changed = true }
        }
        return changed
    }

    // MARK: built-in "OPUS Advanced Studio" scenes

    /// Inserts the Advanced preset's scenes once: only when the preset exists, has no scenes, was never seeded and the
    /// scenes have content. Returns the scenes the caller must store (empty when nothing to do).
    mutating func seedAdvanced(stages: [JourneyStage: LayerScene], extras: [LayerScene]) -> [LayerScene] {
        guard let i = presets.firstIndex(where: { $0.builtin == StudioPreset.builtinAdvanced }),
              presets[i].sceneIds.isEmpty, presets[i].seeded != true,
              stages.values.contains(where: { !$0.layers.isEmpty }) || extras.contains(where: { !$0.layers.isEmpty }) else { return [] }
        return installAdvanced(at: i, stages: stages, extras: extras)
    }
    /// Built-in scenes that came after the first seed (the YouTube Thumbnail): each joins the seeded Advanced preset once
    /// (also on stores seeded before it existed); never again after the operator deletes it. Returns the scenes to store.
    mutating func seedAdvancedAdditions(_ scenes: [LayerScene]) -> [LayerScene] {
        guard let i = presets.firstIndex(where: { $0.builtin == StudioPreset.builtinAdvanced }), presets[i].seeded == true else { return [] }
        var done = presets[i].seededAdditions ?? []
        var out: [LayerScene] = []
        for s in scenes where !done.contains(s.id) && !s.layers.isEmpty {
            if !presets[i].sceneIds.contains(s.id) { presets[i].sceneIds.append(s.id) }
            done.append(s.id); out.append(s)
        }
        if !out.isEmpty { presets[i].seededAdditions = done }
        return out
    }
    /// "Reinstall built-in scenes": puts fresh copies of the Advanced scenes into the preset (same ids, replaces them).
    mutating func reinstallAdvanced(stages: [JourneyStage: LayerScene], extras: [LayerScene]) -> [LayerScene] {
        guard let i = presets.firstIndex(where: { $0.builtin == StudioPreset.builtinAdvanced }) else { return [] }
        return installAdvanced(at: i, stages: stages, extras: extras)
    }
    private mutating func installAdvanced(at i: Int, stages: [JourneyStage: LayerScene], extras: [LayerScene]) -> [LayerScene] {
        var out: [LayerScene] = []
        for stage in JourneyStage.allCases { if let s = stages[stage] { out.append(s); presets[i].setScene(s.id, for: stage) } }
        out.append(contentsOf: extras)
        for s in out where !presets[i].sceneIds.contains(s.id) { presets[i].sceneIds.append(s.id) }
        presets[i].seeded = true
        return out
    }

    // MARK: CRUD

    /// New preset: empty, or a copy (scenes, order, journey, overlays) of `duplicating`. Becomes active when `activate`.
    @discardableResult
    mutating func create(name: String, duplicating: String? = nil, activate: Bool = true) -> StudioPreset {
        var p = StudioPreset(name: uniqueName(Self.clean(name) ?? "New preset"))
        if let src = duplicating.flatMap(preset) { p.sceneIds = src.sceneIds; p.journey = src.journey; p.overlays = src.overlays }
        presets.append(p)
        if activate { activeId = p.id }
        return p
    }
    mutating func rename(_ id: String, to name: String) {
        guard let i = index(id), let n = Self.clean(name) else { return }
        presets[i].name = n
    }
    /// Deleting the last preset is refused (returns false). Deleting the active one activates the first remaining.
    @discardableResult
    mutating func delete(_ id: String) -> Bool {
        guard presets.count > 1, let i = index(id) else { return false }
        presets.remove(at: i)
        if activeId == id || index(activeId) == nil { activeId = presets.first?.id }
        return true
    }
    mutating func setActive(_ id: String) { if index(id) != nil { activeId = id } }

    // MARK: scenes

    func isMember(_ sceneId: String, of presetId: String) -> Bool { preset(presetId)?.sceneIds.contains(sceneId) ?? false }
    mutating func setMember(_ sceneId: String, of presetId: String, _ on: Bool) {
        guard let i = index(presetId) else { return }
        if on { if !presets[i].sceneIds.contains(sceneId) { presets[i].sceneIds.append(sceneId) } }
        else { presets[i].removeScene(sceneId) }
    }
    /// A scene created while this preset is active joins it.
    mutating func addToActive(_ sceneId: String) {
        if activeId == nil { activeId = presets.first?.id }
        if let a = activeId { setMember(sceneId, of: a, true) }
    }
    /// Moves a scene inside a preset's list (index clamped).
    mutating func move(_ sceneId: String, in presetId: String, to newIndex: Int) {
        guard let i = index(presetId), let from = presets[i].sceneIds.firstIndex(of: sceneId) else { return }
        presets[i].sceneIds.remove(at: from)
        presets[i].sceneIds.insert(sceneId, at: max(0, min(newIndex, presets[i].sceneIds.count)))
    }
    /// The scene was deleted from the studio: gone from every preset and journey.
    mutating func sceneDeleted(_ sceneId: String) { for i in presets.indices { presets[i].removeScene(sceneId) } }
    mutating func setJourney(_ stage: JourneyStage, sceneId: String?, in presetId: String? = nil) {
        guard let i = index(presetId ?? activeId) else { return }
        presets[i].setScene(sceneId, for: stage)
        if let s = sceneId, !presets[i].sceneIds.contains(s) { presets[i].sceneIds.append(s) }
    }
    mutating func setOverlays(_ o: Overlays?, in presetId: String) { if let i = index(presetId) { presets[i].overlays = o } }

    /// The preset's scenes in its order (unknown ids skipped). Without presets (mock backend) every scene.
    func scenes(_ all: [Scene], presetId: String? = nil) -> [Scene] {
        guard let p = presetId.flatMap(preset) ?? active else { return all }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.sceneIds.compactMap { byId[$0] }
    }
    /// Scenes of the active preset first, then every other scene (auto capture pickers).
    func scenesActiveFirst(_ all: [Scene]) -> [Scene] {
        let mine = scenes(all)
        let ids = Set(mine.map(\.id))
        return mine + all.filter { !ids.contains($0.id) }
    }

    /// The on-air scene cannot be deleted without cutting to black first.
    static func deleteCheck(sceneId: String, programId: String?) -> SceneDeleteBlock? { sceneId == programId ? .onAir : nil }

    static func clean(_ name: String) -> String? {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return n.isEmpty ? nil : n
    }
    func uniqueName(_ base: String) -> String {
        let names = Set(presets.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

extension StudioStore {
    var presetBook: PresetBook { let d = snapshot; return PresetBook(presets: d.presets, activeId: d.activePresetId) }
    func savePresetBook(_ b: PresetBook) { update { $0.presets = b.presets; $0.activePresetId = b.activeId } }

    /// Every scene id + name as the studio lists them (old scenes, then native layer scenes).
    static func sceneList(_ doc: StoreDoc) -> [(id: String, name: String)] {
        doc.scenes.map { ($0.id, $0.name) } + doc.layerScenes.filter { n in !doc.scenes.contains { $0.id == n.id } }.map { ($0.id, $0.name) }
    }

    /// Launch: migrate the scene list into presets (first run: "OPUS Studio Default" holds every current scene and is active),
    /// make sure "OPUS Advanced Studio" exists and insert its built-in scenes once when they are available.
    @discardableResult
    func ensurePresets(advancedStages: [JourneyStage: LayerScene] = [:], advancedExtras: [LayerScene] = [], advancedAdditions: [LayerScene] = []) -> PresetBook {
        update { doc in
            var b = PresetBook(presets: doc.presets, activeId: doc.activePresetId)
            b.migrate(scenes: Self.sceneList(doc))
            let seeded = b.seedAdvanced(stages: advancedStages, extras: advancedExtras) + b.seedAdvancedAdditions(advancedAdditions)
            for s in seeded where !doc.layerScenes.contains(where: { $0.id == s.id }) {
                doc.layerScenes.append(s)
            }
            doc.presets = b.presets; doc.activePresetId = b.activeId
            return b
        }
    }
    /// Fresh copies of the Advanced preset's scenes (replacing the stored ones with the same id).
    @discardableResult
    func reinstallAdvancedScenes(stages: [JourneyStage: LayerScene], extras: [LayerScene]) -> PresetBook {
        update { doc in
            var b = PresetBook(presets: doc.presets, activeId: doc.activePresetId)
            for s in b.reinstallAdvanced(stages: stages, extras: extras) {
                if let i = doc.layerScenes.firstIndex(where: { $0.id == s.id }) { doc.layerScenes[i] = s } else { doc.layerScenes.append(s) }
            }
            doc.presets = b.presets; doc.activePresetId = b.activeId
            return b
        }
    }
}
