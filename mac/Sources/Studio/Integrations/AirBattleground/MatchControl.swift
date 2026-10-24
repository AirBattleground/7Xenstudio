// Studio match control (AirBattleground contract "the studio takes over the match"):
//   GET  /api/studio-link/matches                 items[].control { state, unlocksAt, reason, teams, slots }
//   POST /api/studio-link/matches/{id}/start|stop  -> 200 same body as GET …/live, 409 CONFLICT { error: { message } }
//   GET  /api/studio-link/matches/{id}/live         (polled by MatchDataStore) control + autoCapture blocks
//   GET  /api/studio-link/matches/{id}/captures/{captureId}  detection result of one screenshot
// The studio never computes unlocksAt and never says what a screenshot shows: everything here only mirrors the server.
import Foundation

// MARK: - control

struct MatchControl: Equatable, Hashable, Sendable {
    enum State: String, Codable, Sendable, CaseIterable { case locked, ready, live, ended, published }
    var state: State
    /// ISO time the match unlocks (server-computed), only meaningful while locked
    var unlocksAt: String?
    /// "Registration is open until 10:30 PM (12/16 slots filled)"
    var reason: String?
    var teams: Int?
    var slots: Int?

    init(state: State, unlocksAt: String? = nil, reason: String? = nil, teams: Int? = nil, slots: Int? = nil) {
        self.state = state; self.unlocksAt = unlocksAt; self.reason = reason; self.teams = teams; self.slots = slots
    }
    var unlocksAtDate: Date? { unlocksAt.flatMap(ABGTime.parse) }

    /// Seconds until the unlock (nil = unknown or not locked); never negative.
    func secondsToUnlock(now: Date) -> Int? {
        guard state == .locked, let d = unlocksAtDate else { return nil }
        return max(0, Int(ceil(d.timeIntervalSince(now))))
    }
    /// "Locked · unlocks in 12:31" / "Ready" / "Live" / "Ended" / "Published"
    func chip(now: Date) -> String {
        switch state {
        case .locked:
            guard let s = secondsToUnlock(now: now) else { return "Locked" }
            return s > 0 ? "Locked · unlocks in \(ABGTime.countdown(s))" : "Locked · unlocking…"
        case .ready: return "Ready"
        case .live: return "Live"
        case .ended: return "Ended"
        case .published: return "Published"
        }
    }
    /// "12/16 teams"
    var teamsLine: String? {
        guard let t = teams else { return nil }
        return slots.map { "\(t)/\($0) teams" } ?? "\(t) teams"
    }
}

extension MatchControl: Decodable {
    private enum K: String, CodingKey { case state, unlocksAt, reason, teams, slots }
    /// Lenient: an unknown or missing state fails (the caller treats the match as legacy); other fields are optional.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let raw = try c.decode(String.self, forKey: .state).trimmingCharacters(in: .whitespaces).lowercased()
        guard let st = State(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown control state \(raw)")
        }
        state = st
        unlocksAt = ((try? c.decodeIfPresent(String.self, forKey: .unlocksAt)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        teams = Self.int(c, .teams); slots = Self.int(c, .slots)
    }
    private static func int(_ c: KeyedDecodingContainer<K>, _ k: K) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int(s) }
        return nil
    }
}

/// The one big Start / Stop button of the selected match, driven only by control.state.
enum MatchControlButton: Equatable, Sendable {
    case start(enabled: Bool)
    case stop
    /// ended (waiting for results) / published (read-only): no button
    case none

    /// `legacyStatus` is used only when the server sends no control block (old server: allow everything as before).
    static func make(_ c: MatchControl?, legacyStatus: ABGMatch.Status? = nil) -> MatchControlButton {
        guard let c else { return legacyStatus == .live ? .stop : .start(enabled: true) }
        switch c.state {
        case .locked: return .start(enabled: false)
        case .ready: return .start(enabled: true)
        case .live: return .stop
        case .ended, .published: return .none
        }
    }
}

enum ABGTime {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    /// 751 -> "12:31", 4000 -> "1:06:40"
    static func countdown(_ secs: Int) -> String {
        let s = max(0, secs), h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%02d:%02d", m, s % 60)
    }
    /// "just now" / "12 s ago" / "3 min ago" / "2 h ago"
    static func ago(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}

// MARK: - GET …/live (control + autoCapture), also the body of start / stop

/// `autoCapture` block of GET …/live. Every field optional.
struct LiveAutoCapture: Equatable, Sendable {
    var active: Bool?
    var lastCaptureAt: Date?
    var lastAppliedAt: Date?
    var lastError: String?
    var paused = false
    /// lobby | results | in_game | other (if the server sends it)
    var lastDetected: String?
}

struct LiveControlBody: Equatable, Sendable {
    var matchId: String?
    var control: MatchControl?
    var autoCapture: LiveAutoCapture?

    static func parse(_ data: Data) -> LiveControlBody? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var b = LiveControlBody()
        if let m = root["match"] as? [String: Any] { b.matchId = str(m["id"]) }
        if let c = root["control"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: c) {
            b.control = try? JSONDecoder().decode(MatchControl.self, from: d)
        }
        if let a = root["autoCapture"] as? [String: Any] {
            var x = LiveAutoCapture()
            x.active = a["active"] as? Bool
            x.lastCaptureAt = str(a["lastCaptureAt"]).flatMap(ABGTime.parse)
            x.lastAppliedAt = str(a["lastAppliedAt"]).flatMap(ABGTime.parse)
            x.lastError = str(a["lastError"]).flatMap { $0.isEmpty ? nil : $0 }
            x.paused = (a["paused"] as? Bool) ?? false
            x.lastDetected = str(a["lastDetected"]).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            b.autoCapture = x
        }
        return b
    }
    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, !(v is Bool) { return n.stringValue }
        return nil
    }
}

// MARK: - capture detection result (GET …/captures/{captureId})

struct CaptureResult: Equatable, Sendable, Decodable {
    enum Status: String, Sendable { case queued, reading, applied, ignored, failed }
    var captureId: String?
    var status: Status
    /// lobby | results | in_game | other | nil
    var detected: String?
    var confidence: Double?
    var message: String?
    var isFinal: Bool { status == .applied || status == .ignored || status == .failed }

    init(captureId: String? = nil, status: Status, detected: String? = nil, confidence: Double? = nil, message: String? = nil) {
        self.captureId = captureId; self.status = status; self.detected = detected; self.confidence = confidence; self.message = message
    }
    private enum K: String, CodingKey { case captureId, status, detected, confidence, message }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        captureId = (try? c.decodeIfPresent(String.self, forKey: .captureId)) ?? nil
        let raw = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)?.lowercased() ?? "queued"
        status = Status(rawValue: raw) ?? .queued
        detected = ((try? c.decodeIfPresent(String.self, forKey: .detected)) ?? nil)?.lowercased()
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? nil
        message = ((try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum CaptureResultReply: Equatable, Sendable {
    case result(CaptureResult)
    case notFound
    case failed(String)
}

/// "Lobby" / "Results" / "In-game" / "Not a game screen"
enum CaptureDetected {
    static func label(_ d: String?) -> String? {
        switch d?.lowercased() {
        case "lobby"?: "Lobby"
        case "results"?: "Results"
        case "in_game"?, "ingame"?, "in-game"?: "In-game"
        case "other"?: "Not a game screen"
        default: nil
        }
    }
}

/// What the operator sees for one manual screenshot.
struct CaptureOutcome: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case progress, ok, warn, error }
    var text: String
    var detail: String?
    var tone: Tone

    static let notGame = "Not a game screen. Check the scene"

    /// "Lobby ✓ 14 teams", "Results ✓ page 1", "Not a game screen. Check the scene", failed -> red server message.
    static func from(_ r: CaptureResult) -> CaptureOutcome {
        switch r.status {
        case .queued: return CaptureOutcome(text: "Waiting for the reader…", tone: .progress)
        case .reading: return CaptureOutcome(text: "Reading the screenshot…", tone: .progress)
        case .failed: return CaptureOutcome(text: r.message ?? "AirBattleground couldn't read the screenshot.", tone: .error)
        case .ignored:
            if r.detected == nil || r.detected == "other" { return CaptureOutcome(text: notGame, detail: r.message, tone: .warn) }
            let l = CaptureDetected.label(r.detected) ?? "Screenshot"
            return CaptureOutcome(text: "\(l) not used" + (r.message.map { ". \($0)" } ?? ""), tone: .warn)
        case .applied:
            guard let l = CaptureDetected.label(r.detected), r.detected != "other" else {
                return CaptureOutcome(text: r.detected == "other" ? notGame : "Applied ✓", detail: r.message, tone: r.detected == "other" ? .warn : .ok)
            }
            let extra = summary(r.message)
            return CaptureOutcome(text: "\(l) ✓" + (extra.map { " \($0)" } ?? ""), detail: extra == nil ? r.message : nil, tone: .ok)
        }
    }
    static let timedOut = CaptureOutcome(text: "No answer from the reader after 60 s. Check the match on AirBattleground.", tone: .warn)

    /// "Read 14 teams from the lobby" -> "14 teams"; "Results page 1 read" -> "page 1"; otherwise nil.
    static func summary(_ m: String?) -> String? {
        guard let m else { return nil }
        for p in [#"\d+\s+teams?"#, #"page\s+\d+"#, #"\d+\s+players?"#] {
            if let r = m.range(of: p, options: [.regularExpression, .caseInsensitive]) { return m[r].lowercased() }
        }
        return nil
    }
}

/// Polling GET …/captures/{captureId}: every 1.5 s, at most 60 s (pure step, tested).
enum CaptureResultPolling {
    static let interval = 1.5
    static let timeout = 60.0
    enum Step: Equatable { case wait, done(CaptureResult), timedOut, gone }
    static func step(_ reply: CaptureResultReply?, elapsed: Double) -> Step {
        if case .result(let r)? = reply, r.isFinal { return .done(r) }
        if case .notFound? = reply, elapsed >= 10 { return .gone }     // a brand new capture may 404 for a moment
        return elapsed >= timeout ? .timedOut : .wait
    }
}

// MARK: - status strip (Capture tab + compact on the Studio page)

struct CaptureStatusStrip: Equatable {
    enum Tone: Equatable { case neutral, ok, live, warn, error }
    var state: String
    var stateTone: Tone
    /// "Last screenshot 12 s ago · Lobby" (nil = none yet)
    var lastShot: String?
    /// autoCapture.lastError, shown in red
    var error: String?
    var pausedByManager: Bool

    static func make(control: MatchControl?, auto: LiveAutoCapture?, localLastAt: Date?, localDetected: String?, now: Date) -> CaptureStatusStrip {
        let state = control?.chip(now: now) ?? "Match"
        let tone: Tone = switch control?.state {
        case .locked?: .warn
        case .ready?: .ok
        case .live?: .live
        case .ended?: .warn
        case .published?, nil: .neutral
        }
        // the server's view wins (it also counts frames sent by another studio); local as a fallback
        let at: Date? = [auto?.lastCaptureAt, localLastAt].compactMap { $0 }.max()
        let det = CaptureDetected.label(auto?.lastDetected ?? localDetected)
        let last = at.map { "Last screenshot \(ABGTime.ago($0, now: now))" + (det.map { " · \($0)" } ?? "") }
        return CaptureStatusStrip(state: state, stateTone: tone, lastShot: last, error: auto?.lastError, pausedByManager: auto?.paused ?? false)
    }
}
