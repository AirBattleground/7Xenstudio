import Foundation

/// The one place core code touches integrations. Delete Sources/Studio/Integrations/AirBattleground and this
/// file's AirBattleground line (and the few `model.abg` UI hooks) and the studio still builds and works.
@MainActor enum StudioIntegrations {
    static func makeAirBattleground(store: StudioStore?) -> ABGController {
        let service: BroadcastLinkService
        if ProcessInfo.processInfo.environment["STUDIO_ABG_MOCK"] != nil {
            let mock = MockBroadcastLinkService(account: ABGAccount(name: "Mock Admin", org: "Mock Org"))
            mock.matchList += MockBroadcastLinkService.controlDemoMatches()
            service = mock
        } else { service = StudioLinkService() }
        // Team Status board: live team data of the picked match over the same Studio Link (read-only)
        TeamBoardHub.shared.abgCredentials = { [service] in service.studioLinkCredentials }
        let abg = ABGController(service: service, persistence: store.map { ABGStorePersistence(store: $0) } ?? ABGMemoryPersistence())
        // match control + autoCapture blocks ride on the shared GET …/live poller (MatchDataStore, every 3 s, ETag / 304)
        MatchDataStore.shared.onIngest = { [weak abg] data in Task { @MainActor in abg?.ingestLive(data) } }
        abg.onLiveBody = { data in try? MatchDataStore.shared.ingest(data) }
        return abg
    }

    /// YouTube thumbnail (Go Live sheet + Outputs): rendered from a scene with the live {{variables}}, uploaded through the
    /// same Studio Link (the studio has no YouTube credentials; AirBattleground sets it on the admin's broadcast).
    static func makeThumbnail(abg: ABGController, services: StudioServices) -> ThumbnailController {
        let link = abg.service
        let env = ThumbnailEnvironment(
            scenes: { [weak services] in services?.layerScenes() ?? [] },
            variables: { [weak services, weak abg] in
                // engine values first (what Program shows), then the match feed, then the picked match's title
                var v = services?.liveSceneVariables() ?? SceneVariables()
                for (k, x) in MatchDataStore.shared.variables() where (v[k] ?? "").isEmpty { v[k] = x }
                for (k, x) in SceneVariables.fromMatch(abg?.link) where (v[k] ?? "").isEmpty { v[k] = x }
                for k in Array(v.values.keys) where v[k] == "" { v[k] = nil }      // empty -> the scene's defaults
                return v
            },
            render: services.stillRenderer(),
            upload: { u in await link.uploadThumbnail(u) },
            broadcastId: { [weak abg] in abg?.broadcastId },
            matchId: { [weak abg] in abg?.link?.eventId })
        return ThumbnailController(env: env, persistence: services.integrationStore.map { ThumbnailStorePersistence(store: $0) })
    }

    /// Auto capture (Studio page -> Capture tab): stills of a chosen scene sent to the picked match.
    static func makeAutoCapture(abg: ABGController, services: StudioServices) -> AutoCaptureController {
        let link = abg.service
        let env = CaptureEnvironment(
            isConnected: { [weak abg] in abg?.isConnected ?? false },
            matchId: { [weak abg] in abg?.link?.eventId },
            programSceneId: { [weak services] in services?.programSceneID },
            scene: { [weak services] id in services?.layerScenes().first { $0.id == id } },
            render: services.captureRenderer(),
            upload: { u in await link.uploadCapture(u) },
            feeds: { [weak services] in
                (services?.devices() ?? []).map { CaptureFeed(ref: .device(id: $0.id), name: $0.name, online: $0.online && $0.videoReady) }
            },
            captureResult: { m, c in await link.captureResult(matchId: m, captureId: c) },
            controlState: { [weak abg] in abg?.selectedControl?.state },
            startsAt: { [weak abg] in abg?.selectedMatch?.startsAt.flatMap(ABGTime.parse) })
        return AutoCaptureController(env: env, persistence: services.integrationStore.map { AutoCaptureStorePersistence(store: $0) })
    }
}
