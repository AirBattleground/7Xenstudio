import Foundation

/// "Auto-follow match": watches the match state and says when to switch the program to the next journey stage.
/// Pure state machine (driven by AppModel every 0.5 s, tested in JourneyTests):
///  - a new state must stay unchanged for `debounce` seconds before it counts (no flapping on live/summary/live);
///  - each stable stage fires once;
///  - a manual take (or Cancel on the "Switching to…" toast) pauses auto-follow until the match state changes again.
struct JourneyAutoFollow: Equatable {
    var enabled = false
    var debounce: TimeInterval = 2
    private(set) var observed: String?
    private(set) var candidate: JourneyStage?
    private(set) var candidateSince: Date?
    /// The stage auto-follow last switched to (or the operator took by hand while it was the match's stage).
    private(set) var applied: JourneyStage?
    /// Manual override: waiting for the next match state change.
    private(set) var paused = false
    private var pausedAt: String?

    init(enabled: Bool = false, debounce: TimeInterval = 2) { self.enabled = enabled; self.debounce = debounce }

    /// Turning it on (or off) starts fresh: the current state is followed once it has been stable for `debounce` seconds.
    mutating func setEnabled(_ on: Bool, now: Date) {
        enabled = on; paused = false; pausedAt = nil; applied = nil
        if candidate != nil { candidateSince = now }
    }

    /// Feed the latest match state. Returns the stage to switch to now, or nil.
    mutating func observe(_ state: String?, now: Date) -> JourneyStage? {
        if state != observed {
            observed = state
            candidate = state.flatMap(JourneyStage.forMatchState)
            candidateSince = now
            if paused, state != pausedAt { paused = false; pausedAt = nil }
        }
        guard enabled, !paused, let c = candidate, let since = candidateSince,
              now.timeIntervalSince(since) >= debounce, c != applied else { return nil }
        applied = c
        return c
    }

    /// The operator took something else (or cancelled an automatic switch): stop until the match state changes.
    mutating func manualOverride() {
        guard enabled else { return }
        paused = true; pausedAt = observed
    }
    /// The operator took this stage's scene by hand: count it as done, no pause.
    mutating func acknowledge(_ stage: JourneyStage) { applied = stage }
}

/// A scheduled automatic switch, shown as a 3-second "Switching to Winner…" toast with Cancel.
struct PendingAutoSwitch: Equatable {
    var stage: JourneyStage
    var sceneId: String
    var deadline: Date
    static let delay: TimeInterval = 3
}
