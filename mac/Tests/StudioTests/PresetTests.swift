import Testing
import Foundation
@testable import Studio

/// Studio presets: migration, CRUD, scene membership, delete rules, journey mapping, Advanced seeding.
struct PresetTests {
    static func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("preset-\(UUID().uuidString)") }
    static let scenes: [(id: String, name: String)] = [("a", "Starting Soon - 10 Mins"), ("b", "Game Play"), ("c", "Team Status"), ("d", "OPUS Ipad")]

    @Test func presetMigrationPutsCurrentScenesIntoOpusDefault() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StudioStore(dir: dir)
        for (id, name) in Self.scenes { store.upsert(Scene(id: id, name: name, layout: .full, slots: [nil])) }
        let book = store.ensurePresets()
        #expect(book.presets.map(\.name) == [PresetNames.opusDefault, PresetNames.opusAdvanced])
        #expect(book.active?.name == PresetNames.opusDefault)
        #expect(book.active?.sceneIds == ["a", "b", "c", "d"])
        #expect(book.presets[1].sceneIds.isEmpty)
        // name-based first guess of the journey
        #expect(book.active?.scene(for: .startsIn) == "a" && book.active?.scene(for: .gameplay) == "b")
        // persisted, and a second launch changes nothing
        let again = try StudioStore(dir: dir).ensurePresets()
        #expect(again == book)
        // old store.json without presets still decodes (lenient)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("store.json"))) as! [String: Any]
        #expect((raw["presets"] as? [Any])?.count == 2 && raw["activePresetId"] as? String == book.activeId)
        let legacy = try JSONDecoder().decode(StoreDoc.self, from: Data(#"{"scenes":[],"presets":"garbage"}"#.utf8))
        #expect(legacy.presets.isEmpty)
    }

    @Test func presetCRUD() {
        var b = PresetBook()
        b.migrate(scenes: Self.scenes)
        let def = b.activeId!
        let dup = b.create(name: "Finals", duplicating: def)
        #expect(b.activeId == dup.id && dup.sceneIds == ["a", "b", "c", "d"] && dup.journey == b.preset(def)!.journey)
        let empty = b.create(name: "  ", activate: false)
        #expect(empty.name == "New preset" && empty.sceneIds.isEmpty && b.activeId == dup.id)
        let second = b.create(name: "Finals", activate: false); #expect(second.name == "Finals 2")
        b.rename(dup.id, to: "Grand Finals"); #expect(b.preset(dup.id)?.name == "Grand Finals")
        b.rename(dup.id, to: "   "); #expect(b.preset(dup.id)?.name == "Grand Finals")
        let deleted = b.delete(dup.id); #expect(deleted)
        #expect(b.activeId == def)                     // deleting the active preset activates the first remaining
        while b.presets.count > 1 { let ok = b.delete(b.presets.last!.id); #expect(ok) }
        let lastDeleted = b.delete(def); #expect(!lastDeleted)                         // never the last one
        #expect(b.presets.count == 1)
    }

    @Test func presetSceneMembership() {
        var b = PresetBook()
        b.migrate(scenes: Self.scenes)
        let def = b.activeId!, adv = b.presets[1].id
        b.setMember("b", of: adv, true); b.setMember("b", of: adv, true)
        #expect(b.preset(adv)?.sceneIds == ["b"])       // no duplicates; a scene can be in several presets
        #expect(b.presets(containing: "b").count == 2)
        b.move("d", in: def, to: 0); #expect(b.preset(def)?.sceneIds == ["d", "a", "b", "c"])
        b.move("d", in: def, to: 99); #expect(b.preset(def)?.sceneIds == ["a", "b", "c", "d"])
        let all = Self.scenes.map { Scene(id: $0.id, name: $0.name, layout: .full, slots: []) }
        b.setActive(adv)
        #expect(b.scenes(all).map(\.id) == ["b"])
        #expect(b.scenesActiveFirst(all).map(\.id) == ["b", "a", "c", "d"])
        b.addToActive("new"); #expect(b.preset(adv)?.sceneIds == ["b", "new"])
        // removing from a preset also clears its journey stage
        b.setJourney(.gameplay, sceneId: "b")
        b.setMember("b", of: adv, false)
        #expect(b.preset(adv)?.scene(for: .gameplay) == nil && b.isMember("b", of: def))
    }

    @Test func presetDeleteRules() throws {
        #expect(PresetBook.deleteCheck(sceneId: "a", programId: "a") == .onAir)
        #expect(PresetBook.deleteCheck(sceneId: "a", programId: "b") == nil)
        #expect(PresetBook.deleteCheck(sceneId: "a", programId: nil) == nil)
        // deleting a scene removes it from every preset and journey (store level)
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StudioStore(dir: dir)
        for (id, name) in Self.scenes { store.upsert(Scene(id: id, name: name, layout: .full, slots: [nil])) }
        var b = store.ensurePresets()
        b.setMember("a", of: b.presets[1].id, true); b.setJourney(.startsIn, sceneId: "a", in: b.presets[1].id)
        store.savePresetBook(b)
        store.removeScene("a")
        let after = store.presetBook
        #expect(after.presets.allSatisfy { !$0.sceneIds.contains("a") && !$0.journey.values.contains("a") })
        // prune drops ids that vanished some other way
        var p = PresetBook(presets: [StudioPreset(name: "X", sceneIds: ["x", "y"], journey: ["winner": "y"])], activeId: nil)
        let pruned = p.prune(validIds: ["x"]); #expect(pruned)
        #expect(p.presets[0].sceneIds == ["x"] && p.presets[0].journey.isEmpty)
    }

    @Test func presetJourneyMapping() {
        var b = PresetBook()
        b.migrate(scenes: Self.scenes)
        b.setJourney(.winner, sceneId: "zz")             // a scene from outside joins the preset
        #expect(b.active?.scene(for: .winner) == "zz" && b.active?.sceneIds.last == "zz")
        b.setJourney(.winner, sceneId: nil)
        #expect(b.active?.scene(for: .winner) == nil)
        // presets have independent mappings
        let other = b.create(name: "Other")
        #expect(other.journey.isEmpty && b.active?.scene(for: .gameplay) == nil)
        // Codable round trip
        let data = try! JSONEncoder().encode(b.presets)
        #expect(try! JSONDecoder().decode([StudioPreset].self, from: data) == b.presets)
    }

    @Test func presetAdvancedSeedsOnceAndNeverAfterDelete() {
        var b = PresetBook()
        b.migrate(scenes: Self.scenes)
        var stages: [JourneyStage: LayerScene] = [:]
        // empty placeholder scenes are not seeded
        for s in JourneyStage.allCases { stages[s] = LayerScene(id: "adv.\(s.rawValue)", name: s.title) }
        let none = b.seedAdvanced(stages: stages, extras: []); #expect(none.isEmpty)
        for s in JourneyStage.allCases { stages[s]?.layers = [.text("T", "{{matchTitle}}", x: 0, y: 0, w: 100, h: 50)] }
        let seeded = b.seedAdvanced(stages: stages, extras: [LayerScene(id: "adv.brb", name: "BRB")])
        #expect(seeded.count == 6)
        let adv = b.presets.first { $0.builtin == StudioPreset.builtinAdvanced }!
        #expect(adv.sceneIds == ["adv.preShow", "adv.startsIn", "adv.gameplay", "adv.summary", "adv.winner", "adv.brb"])
        #expect(adv.scene(for: .winner) == "adv.winner" && adv.seeded == true)
        for id in adv.sceneIds { b.sceneDeleted(id) }
        let again = b.seedAdvanced(stages: stages, extras: []); #expect(again.isEmpty)          // the operator deleted them: stays empty
        let re = b.reinstallAdvanced(stages: stages, extras: []); #expect(re.count == 5)  // only on request
        #expect(b.active?.name == PresetNames.opusDefault)                   // seeding never changes the active preset
    }
}
