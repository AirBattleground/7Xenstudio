import Foundation

/// The one place core code touches integrations. Delete Sources/Studio/Integrations/AirBattleground and this
/// file's AirBattleground line (and the few `model.abg` UI hooks) and the studio still builds and works.
@MainActor enum StudioIntegrations {
    static func makeAirBattleground(store: StudioStore?) -> ABGController {
        let service: BroadcastLinkService = ProcessInfo.processInfo.environment["STUDIO_ABG_MOCK"] != nil
            ? MockBroadcastLinkService(account: ABGAccount(name: "Mock Admin", org: "Mock Org")) : StudioLinkService()
        return ABGController(service: service, persistence: store.map { ABGStorePersistence(store: $0) } ?? ABGMemoryPersistence())
    }
}
