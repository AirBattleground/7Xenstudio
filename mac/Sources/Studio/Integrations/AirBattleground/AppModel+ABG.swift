import Foundation

enum GoLiveOption: String, CaseIterable { case adminYouTube, recordOnly }

extension AppModel {
    /// Heartbeat payload (state, fps, bitrate) from the live output stats, like shows.ts sent from the pipeline.
    func abgHeartbeatStatus() -> ABGHeartbeat {
        let s = stats
        let state = s.error != nil ? "error" : (s.live && s.kbps > 0 ? "live" : "starting")
        return ABGHeartbeat(state: state, fps: s.live && s.fps > 0 ? s.fps : nil, bitrateKbps: s.live && s.kbps > 0 ? s.kbps : nil)
    }

    /// Go Live from the sheet. Throws a user-facing error; the sheet shows it and offers Retry.
    func startShow(_ option: GoLiveOption, alsoRecord: Bool, otherDestinationIDs: [String] = []) async throws {
        guard !live, !busy else { return }
        busy = true; defer { busy = false; refresh() }
        switch option {
        case .recordOnly:
            recordOn = true
            try await services.goLive(record: true, destinationIDs: [], extraDestinations: [])
        case .adminYouTube:
            let ingest = try await abg.prepareYouTube()     // fresh ingest right before starting
            recordOn = alsoRecord
            do { try await services.goLive(record: alsoRecord, destinationIDs: otherDestinationIDs, extraDestinations: ingest.destinations) }
            catch { await abg.abortBroadcast(); throw error }
            abg.beginHeartbeats()
        }
    }
}
