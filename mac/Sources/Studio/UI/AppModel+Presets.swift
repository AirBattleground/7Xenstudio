import Foundation

// Studio presets, scene delete rules and the match journey (auto-follow) on the app model.
extension AppModel {
    var activePreset: StudioPreset? { presetBook.active }

    // MARK: presets

    /// Launch: migrate the current scenes into "OPUS Studio Default", add "OPUS Advanced Studio" and seed its built-in scenes once.
    func loadPresets() {
        let stages = AdvancedStudioPreset.makeScenes(), extras = AdvancedStudioPreset.extraScenes()
        if let store = services.integrationStore {
            presetBook = store.ensurePresets(advancedStages: stages, advancedExtras: extras, advancedAdditions: [AdvancedStudioPreset.youtubeThumbnail()])
        } else {
            var b = PresetBook()
            b.migrate(scenes: services.scenes().map { ($0.id, $0.name) })
            presetBook = b
        }
    }
    func persistPresets() { services.integrationStore?.savePresetBook(presetBook) }
    private func mutatePresets(_ body: (inout PresetBook) -> Void) {
        var b = presetBook; body(&b)
        guard b != presetBook else { return }
        presetBook = b; persistPresets()
        scenes = presetBook.scenes(allScenes)
    }

    /// Every refresh: scenes created anywhere (New Scene, editor, templates, duplicates) join the active preset; deleted ones leave all presets.
    func syncPresets(_ all: [Scene]) {
        let ids = Set(all.map(\.id))
        var b = presetBook
        if let known = knownSceneIds {
            for s in all where !known.contains(s.id) && b.presets(containing: s.id).isEmpty { b.addToActive(s.id) }
        }
        knownSceneIds = ids
        b.prune(validIds: ids)
        if b != presetBook { presetBook = b; persistPresets() }
    }

    func setActivePreset(_ id: String) {
        guard id != presetBook.activeId else { return }
        autoSwitch = nil
        mutatePresets { $0.setActive(id) }
        if let o = presetBook.active?.overlays { overlays = o }
    }
    func createPreset(name: String, duplicateActive: Bool) {
        let src = duplicateActive ? presetBook.activeId : nil
        mutatePresets { $0.create(name: name, duplicating: src) }
    }
    func renamePreset(_ id: String, to name: String) { mutatePresets { $0.rename(id, to: name) } }
    func deletePreset(_ id: String) {
        mutatePresets { _ = $0.delete(id) }
        if let o = presetBook.active?.overlays { overlays = o }
    }
    func setScene(_ sceneId: String, inPreset presetId: String, _ on: Bool) { mutatePresets { $0.setMember(sceneId, of: presetId, on) } }
    func moveScene(_ sceneId: String, inPreset presetId: String, to index: Int) { mutatePresets { $0.move(sceneId, in: presetId, to: index) } }
    func saveOverlaysToActivePreset() { if let id = presetBook.activeId { let o = overlays; mutatePresets { $0.setOverlays(o, in: id) } } }
    func clearActivePresetOverlays() { if let id = presetBook.activeId { mutatePresets { $0.setOverlays(nil, in: id) } } }
    /// Fresh copies of the built-in "OPUS Advanced Studio" scenes (replaces the stored ones with the same ids).
    func reinstallAdvancedScenes() {
        var b = presetBook
        let fresh = b.reinstallAdvanced(stages: AdvancedStudioPreset.makeScenes(), extras: AdvancedStudioPreset.extraScenes() + [AdvancedStudioPreset.youtubeThumbnail()])
        presetBook = b; persistPresets()
        Task {
            for s in fresh {
                await services.saveLayerScene(s)
                if !allScenes.contains(where: { $0.id == s.id }) { await services.saveScene(Scene(id: s.id, name: s.name, layout: .full, slots: [nil])) }
            }
            refresh()
        }
    }

    // MARK: scene delete

    func deleteBlock(_ s: Scene) -> SceneDeleteBlock? { PresetBook.deleteCheck(sceneId: s.id, programId: programID) }
    /// Deletes the scene from the studio (every preset). The on-air scene needs `cutToBlack` (program goes black first).
    func deleteScene(_ s: Scene, cutToBlack: Bool = false) {
        if deleteBlock(s) == .onAir {
            guard cutToBlack else { return }
            services.cutToBlack(); programID = services.programSceneID
        }
        if editingScene?.id == s.id { editingScene = nil }
        LayerSceneRepository.shared.delete(s.id)
        delete(s)
    }
    func removeFromActivePreset(_ s: Scene) { if let id = presetBook.activeId { setScene(s.id, inPreset: id, false) } }

    // MARK: match journey

    func sceneId(for stage: JourneyStage) -> String? { presetBook.active?.scene(for: stage) }
    func scene(for stage: JourneyStage) -> Scene? { sceneId(for: stage).flatMap { id in allScenes.first { $0.id == id } } }
    /// The stage whose scene is on Program (highlighted in the journey bar).
    var programStage: JourneyStage? { JourneyStage.allCases.first { s in sceneId(for: s).map { $0 == programID } ?? false } }
    /// The stage the match is in (server or simulated state).
    var matchStage: JourneyStage? { matchStatus.state.flatMap(JourneyStage.forMatchState) }

    func previewStage(_ stage: JourneyStage) { if let s = scene(for: stage) { select(s) } }
    func takeStage(_ stage: JourneyStage) { if let s = scene(for: stage) { takeScene(s) } }
    func mapStage(_ stage: JourneyStage, to sceneId: String?) { mutatePresets { $0.setJourney(stage, sceneId: sceneId) } }

    func setAutoFollow(_ on: Bool) {
        var j = journey; j.setEnabled(on, now: Date()); journey = j
        autoSwitch = nil
        if !on { autoTakenStage = nil }
        services.integrationStore?.update { $0.settings.journeyAutoFollow = on }
    }
    /// Cancel on the toast: no switch, and auto-follow waits for the next match state change.
    func cancelAutoSwitch() {
        autoSwitch = nil
        var j = journey; j.manualOverride(); journey = j
    }
    /// Operator take: an automatic switch in flight is dropped; auto-follow pauses unless the take matches the match's stage.
    func noteManualTake(_ sceneId: String?) {
        autoSwitch = nil
        autoTakenStage = nil
        guard journey.enabled else { return }
        var j = journey
        if let c = j.candidate, self.sceneId(for: c) == sceneId { j.acknowledge(c) } else { j.manualOverride() }
        if j != journey { journey = j }
    }

    /// Called from refresh (every 0.5 s).
    func tickJourney(state: String?, now: Date = Date()) {
        // the pre-show scene loops while it is on Program
        if let pre = sceneId(for: .preShow), programID == pre, now.timeIntervalSince(lastPreShowReplay) >= JourneyStage.preShowRepeat {
            if lastPreShowReplay != .distantPast { services.replayProgram() }
            lastPreShowReplay = now
        } else if programID != sceneId(for: .preShow) { lastPreShowReplay = .distantPast }
        var j = journey
        let fire = j.observe(state, now: now)
        if j != journey { journey = j }
        if let stage = fire, let id = sceneId(for: stage), allScenes.contains(where: { $0.id == id }) {
            if programID == id { autoTakenStage = stage }
            else { autoSwitch = PendingAutoSwitch(stage: stage, sceneId: id, deadline: now.addingTimeInterval(PendingAutoSwitch.delay)) }
        }
        if let p = autoSwitch, now >= p.deadline {
            autoSwitch = nil
            // the scene's own transition (`.fade` = use the scene's transitionIn, else the engine default)
            services.takeScene(id: p.sceneId, .fade)
            programID = services.programSceneID; previewID = services.previewSceneID
            autoTakenStage = p.stage
        }
    }
}

// MARK: - Auto-start the match 72 s after its start time
extension AppModel {
    /// When the studio will press Start by itself (nil = not applicable: off, no start time, not `ready`, already tried).
    var autoStartAt: Date? {
        guard autoStartMatch, abg.selectedControl?.state == .ready, let id = abg.link?.eventId, autoStartTriedFor != id else { return nil }
        let t = MatchDataStore.shared.countdownTarget ?? abg.selectedMatch?.startsAt.flatMap(ABGTime.parse)
        return t?.addingTimeInterval(JourneyStage.autoStartDelay)
    }
    func setAutoStartMatch(_ on: Bool) {
        autoStartMatch = on
        services.integrationStore?.update { $0.settings.autoStartMatch = on }
    }
    /// Called from refresh (every 0.5 s): Start once, `autoStartDelay` after the start time, if the match is still ready.
    func tickAutoStart(now: Date = Date()) {
        guard let due = autoStartAt, now >= due, let id = abg.link?.eventId, !abg.controlBusy else { return }
        autoStartTriedFor = id
        NSLog("AutoStart: starting match %@ (%.0f s after start time)", id, JourneyStage.autoStartDelay)
        Task { await abg.startMatch() }
    }
}

// MARK: - Duplicate / reorder scenes from the Studio strip
extension AppModel {
    /// A full copy of the scene (all layers, new ids) named "<name> copy", placed right after the original in the active preset.
    func duplicateScene(_ s: Scene) {
        guard var copy = services.layerScenes().first(where: { $0.id == s.id }) else { return }
        copy.id = UUID().uuidString
        copy.name = String((s.name + " copy").prefix(60))
        copy.migratedFrom = nil
        copy.layers = copy.layers.map(LayerTree.clone)
        let legacy = Scene(id: copy.id, name: copy.name, layout: s.layout, slots: s.slots)
        let presetId = presetBook.activeId
        let after = presetId.flatMap { pid in presetBook.presets.first { $0.id == pid }?.sceneIds.firstIndex(of: s.id) }
        Task {
            await services.saveLayerScene(copy)
            await services.saveScene(legacy)
            refresh()
            if let pid = presetId {
                setScene(copy.id, inPreset: pid, true)
                if let a = after { moveScene(copy.id, inPreset: pid, to: a + 1) }
            }
            refresh()
        }
    }
    /// Drag-and-drop / Move left-right in the active preset's strip.
    func moveSceneInActivePreset(_ sceneId: String, to index: Int) {
        guard let pid = presetBook.activeId else { return }
        moveScene(sceneId, inPreset: pid, to: index)
        refresh()
    }
}
