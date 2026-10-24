// Shared live match data: ONE poller of GET <host>/api/studio-link/matches/{matchId}/live (X-Studio-Key, every 3 s, ETag / 304)
// feeding both the Team Status board (TeamBoardHub, AirBattleground source) and the {{MatchKeys}} scene variables + the
// match journey (auto-follow). On errors the last good data stays. A "Simulate" mode rehearses the journey without a server.
//
// JSON (additions to the Team Status contract in TeamBoard.swift; every field optional, unknown fields ignored):
//   {
//     "version": 42,
//     "match": { "id": "...", "title": "Grand Finals - Match 3", "map": "Erangel",
//                "state": "scheduled|live|summary|finished",
//                "startsAt": "2026-10-23T18:00:00Z", "round": "Grand Finals", "matchNumber": 3 },
//     "control": { "state": "locked|ready|live|ended|published", "unlocksAt": "2026-10-23T17:55:00Z" },   // optional, preferred:
//                 locked|ready -> starts in, live -> gameplay, ended -> summary, published -> winner; countdown uses unlocksAt while locked
//     "teams": [ ... as before (slot, name, logo, status, players, kills = FIN., totalPoints = TOT. PTS.) ... ],
//     "summary": { "teams": [ { "slot": 1, "name": "SOUL", "logo": "https://...", "kills": 12, "placement": 1,
//                               "placementPoints": 15, "killPoints": 12, "totalPoints": 27 } ],
//                  "mvp": { "name": "MORTAL", "team": "SOUL", "kills": 9, "damage": 1284, "photo": "https://..." } },
//     "winner": { "slot": 1, "name": "SOUL", "logo": "https://...", "kills": 18, "totalPoints": 33,
//                 "players": [ { "name": "MORTAL", "kills": 9, "damage": 1284 } ] }
//   }
import Foundation

struct MatchSnapshot: Equatable, Sendable {
    struct Standing: Equatable, Sendable {
        var slot: Int?
        var name = ""
        var logo: String?
        var kills = 0
        var placement: Int?
        var placementPoints = 0
        var killPoints = 0
        var totalPoints = 0
    }
    struct MVP: Equatable, Sendable { var name = "", team = "", kills = 0, damage = 0, photo: String? }
    struct Player: Equatable, Sendable { var name = "", kills = 0, damage = 0 }
    struct Winner: Equatable, Sendable { var slot: Int?, name = "", logo: String?, kills = 0, totalPoints = 0, players: [Player] = [] }

    var state: String?
    /// AirBattleground match `control` (preferred over `state` when present): locked | ready | live | ended | published
    var controlState: String?
    var unlocksAt: Date?
    var unlocksAtText: String?
    /// optional `match.liveAt`: when the match went live (drives {{elapsed}}; else the studio counts from when it saw "live")
    var liveAt: Date?
    var title: String?
    var map: String?
    var round: String?
    var matchNumber: String?
    var startsAtText: String?
    var startsAt: Date?
    var teamCount: Int?
    var aliveTeams: Int?
    /// summary.teams, sorted by totalPoints (desc), then kills (desc), then slot
    var standings: [Standing] = []
    var mvp: MVP?
    var winner: Winner?
    /// Team Status board rows (nil when the answer has no `teams` array)
    var board: TeamBoardData?
    /// additive `results.complete`: every team that played has its rank (nil = not sent: legacy server / not ended)
    var resultsComplete: Bool?

    /// Ended, but AirBattleground is still reading the results screens (the summary would be incomplete).
    var processing: Bool { (controlState.map { $0 == "ended" } ?? (state == "summary")) && resultsComplete == false }

    /// Journey stage: `control.state` when present, else `match.state`.
    var stage: JourneyStage? {
        if processing { return .gameplay }      // results still coming in: stay on the game until the summary is complete
        if let c = controlState, let st = JourneyStage.forControlState(c) { return st }
        return state.flatMap(JourneyStage.forMatchState)
    }
    /// What {{countdown}} counts to: `control.unlocksAt` while locked, else `match.startsAt`.
    var countdownTarget: Date? { controlState == "locked" && unlocksAt != nil ? unlocksAt : startsAt }
}

enum MatchDataParser {
    typealias J = JSONTeamBoardSource

    static func parse(_ data: Data) throws -> MatchSnapshot {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw TeamBoardError.notJSON }
        guard root is [String: Any] else { throw TeamBoardError.notJSON }
        var s = MatchSnapshot()
        let m = J.value(root, path: "match")
        s.state = J.string(J.value(m, path: "state"))?.lowercased().trimmingCharacters(in: .whitespaces)
        s.title = J.string(J.value(m, path: "title"))
        s.map = J.string(J.value(m, path: "map"))
        s.round = J.string(J.value(m, path: "round"))
        s.matchNumber = J.string(J.value(m, path: "matchNumber"))
        if let v = J.value(m, path: "startsAt") { s.startsAtText = J.string(v); s.startsAt = date(v) }
        s.liveAt = J.value(m, path: "liveAt").flatMap(date)
        // `control` at the top level (or inside `match`)
        let ctl = J.value(root, path: "control") ?? J.value(m, path: "control")
        s.controlState = J.string(J.value(ctl, path: "state"))?.lowercased().trimmingCharacters(in: .whitespaces)
        if let v = J.value(ctl, path: "unlocksAt") { s.unlocksAtText = J.string(v); s.unlocksAt = date(v) }
        if let r = J.value(root, path: "results") as? [String: Any], let c = r["complete"] as? Bool { s.resultsComplete = c }
        if let board = try? J.parse(data, mapping: TeamBoardMapping()) {
            s.board = board
            s.teamCount = board.teams.count
            s.aliveTeams = board.teams.filter { !$0.isEliminated }.count
        }
        if let arr = J.value(root, path: "summary.teams") as? [Any] {
            s.standings = arr.compactMap { $0 as? [String: Any] }.enumerated().map { i, o in
                var t = MatchSnapshot.Standing()
                t.slot = J.int(o["slot"]); t.name = J.string(o["name"]) ?? "TEAM \(i + 1)"
                t.logo = J.string(o["logo"]).flatMap { $0.isEmpty ? nil : $0 }
                t.kills = J.int(o["kills"]) ?? 0; t.placement = J.int(o["placement"])
                t.placementPoints = J.int(o["placementPoints"]) ?? 0; t.killPoints = J.int(o["killPoints"]) ?? t.kills
                t.totalPoints = J.int(o["totalPoints"]) ?? (t.placementPoints + t.killPoints)
                return t
            }
            s.standings = s.standings.enumerated().sorted { a, b in
                let x = a.element, y = b.element
                if x.totalPoints != y.totalPoints { return x.totalPoints > y.totalPoints }
                if x.kills != y.kills { return x.kills > y.kills }
                return (x.slot ?? Int.max, a.offset) < (y.slot ?? Int.max, b.offset)
            }.map(\.element)
        }
        if let o = J.value(root, path: "summary.mvp") as? [String: Any] {
            s.mvp = MatchSnapshot.MVP(name: J.string(o["name"]) ?? "", team: J.string(o["team"]) ?? "", kills: J.int(o["kills"]) ?? 0,
                                      damage: num(o["damage"]) ?? 0, photo: J.string(o["photo"]).flatMap { $0.isEmpty ? nil : $0 })
        }
        if let o = J.value(root, path: "winner") as? [String: Any] {
            var w = MatchSnapshot.Winner(slot: J.int(o["slot"]), name: J.string(o["name"]) ?? "", logo: J.string(o["logo"]).flatMap { $0.isEmpty ? nil : $0 },
                                         kills: J.int(o["kills"]) ?? 0, totalPoints: J.int(o["totalPoints"]) ?? 0)
            w.players = ((o["players"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map {
                MatchSnapshot.Player(name: J.string($0["name"]) ?? "", kills: J.int($0["kills"]) ?? 0, damage: num($0["damage"]) ?? 0)
            }
            s.winner = w
        }
        return s
    }

    /// Integer from a number or numeric string (decimals rounded).
    static func num(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return Int(d.rounded()) }
        return nil
    }
    /// ISO 8601 (with or without fractional seconds) or a Unix time (seconds or milliseconds).
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { let d = n.doubleValue; return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d) }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if let d = Double(s) { return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d) }
        return nil
    }
    /// "MM:SS" until `startsAt` (minutes may exceed 59), "" once it is past or unknown.
    static func countdown(to startsAt: Date?, now: Date) -> String {
        guard let startsAt else { return "" }
        let left = Int(ceil(startsAt.timeIntervalSince(now)))
        guard left > 0 else { return "" }
        return String(format: "%02d:%02d", left / 60, left % 60)
    }
    /// Countdown ran out while the match is still waiting to start: "PREPARING" (lobby) replaces the timer.
    static func applyPreparing(_ v: inout [String: String], target: Date?, startsInStage: Bool, now: Date) {
        let over = target.map { $0.timeIntervalSince(now) <= 0 } ?? false
        if over && startsInStage {
            v[MatchKeys.countdown] = ""; v[MatchKeys.preparing] = "PREPARING"
            v[MatchKeys.countdownGhost] = ""; v[MatchKeys.countdownLabel] = "LOBBY"
        } else {
            v[MatchKeys.preparing] = ""; v[MatchKeys.countdownGhost] = "00:00"; v[MatchKeys.countdownLabel] = "MIN  :  SEC"
        }
    }
    /// 1284 -> "1,284"
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US"); f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Every MatchKeys value the snapshot provides (keys without data are left out so scene defaults still apply).
    static func variables(_ s: MatchSnapshot, now: Date) -> [String: String] {
        var v: [String: String] = [:]
        func put(_ k: String, _ x: String?) { if let x, !x.isEmpty { v[k] = x } }
        put(MatchKeys.matchTitle, s.title); put(MatchKeys.map, s.map); put(MatchKeys.round, s.round)
        put(MatchKeys.matchNumber, s.matchNumber); put(MatchKeys.startsAt, s.startsAtText); put(MatchKeys.matchState, s.state)
        put(MatchKeys.startsAtLocal, s.startsAt.map { MatchKeys.localStart($0) })
        put(MatchKeys.matchLine, MatchKeys.line(round: s.round, matchNumber: s.matchNumber, map: s.map))
        if let t = s.countdownTarget { v[MatchKeys.countdown] = countdown(to: t, now: now) }
        applyPreparing(&v, target: s.countdownTarget, startsInStage: s.stage == .startsIn, now: now)
        v[MatchKeys.processing] = s.processing ? "PROCESSING RESULTS" : ""
        // state in the match.state vocabulary (scheduled/live/summary/finished), derived from control.state when present
        if let st = s.stage { v[MatchKeys.matchState] = st.matchState }
        put(MatchKeys.teamCount, s.teamCount.map(String.init)); put(MatchKeys.aliveTeams, s.aliveTeams.map(String.init))
        for (i, t) in s.standings.prefix(16).enumerated() {
            let n = i + 1
            v[MatchKeys.rankName(n)] = t.name; put(MatchKeys.rankLogo(n), t.logo)
            v[MatchKeys.rankKills(n)] = "\(t.kills)"; v[MatchKeys.rankPlacePts(n)] = "\(t.placementPoints)"; v[MatchKeys.rankTotal(n)] = "\(t.totalPoints)"
        }
        if let m = s.mvp {
            put(MatchKeys.mvpName, m.name); put(MatchKeys.mvpTeam, m.team); v[MatchKeys.mvpKills] = "\(m.kills)"
            v[MatchKeys.mvpDamage] = grouped(m.damage); put(MatchKeys.mvpPhoto, m.photo)
        }
        // winner: the server's `winner`, else (finished / summary) the top of the standings
        var w = s.winner
        if w == nil, s.stage == .winner, let top = s.standings.first {
            w = MatchSnapshot.Winner(slot: top.slot, name: top.name, logo: top.logo, kills: top.kills, totalPoints: top.totalPoints)
        }
        if let w {
            put(MatchKeys.winnerName, w.name); put(MatchKeys.winnerLogo, w.logo)
            v[MatchKeys.winnerKills] = "\(w.kills)"; v[MatchKeys.winnerTotal] = "\(w.totalPoints)"
            for (i, p) in w.players.prefix(4).enumerated() {
                v[MatchKeys.winnerPlayer(i + 1)] = p.name
                v[MatchKeys.winnerPlayerKills(i + 1)] = "\(p.kills)"; v[MatchKeys.winnerPlayerDamage(i + 1)] = "\(p.damage)"
            }
        }
        return v
    }
}

/// The process-wide match data poller (also the Team Status board's AirBattleground source). Thread-safe, never blocks.
final class MatchDataStore: TeamBoardSource, @unchecked Sendable {
    static let shared = MatchDataStore()
    static let simulatedStates = ["scheduled", "live", "summary", "finished"]

    enum Connection: String, Sendable { case off, connecting, ok, error, simulated }
    struct Status: Equatable, Sendable {
        var connection: Connection = .off
        var lastOK: Date?
        var lastError: String?
        /// match.state vocabulary (scheduled / live / summary / finished), from control.state when present; simulated wins
        var state: String?
        var simulated: String?
        var stage: JourneyStage? { state.flatMap(JourneyStage.forMatchState) }
    }

    /// Where to poll (nil = no AirBattleground link / no match picked). Defaults to the hub's Studio Link config.
    var config: @Sendable () -> JSONTeamBoardSource.Config? = { TeamBoardHub.shared.abgConfig() }
    var interval: Double = 3

    private let lock = NSLock()
    private var snap: MatchSnapshot?
    private var etag: String?
    private var url: String?
    private var _lastOK: Date?, _lastError: String?
    private var _simulated: String?, simStart = Date()
    private var _liveSince: Date?
    private var task: Task<Void, Never>?
    private var since = Date()

    init() {}
    deinit { task?.cancel() }

    // MARK: polling

    /// Starts the 3 s loop once (idempotent). Polls only while a match is picked.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(max(1, self.interval) * 1_000_000_000))
            }
        }
    }
    func stop() { lock.withLock { task?.cancel(); task = nil } }

    func tick() async {
        guard let cfg = config() else {
            lock.withLock { if url != nil { snap = nil; etag = nil; url = nil; _lastOK = nil; _lastError = nil } }
            return
        }
        lock.withLock { if url != cfg.url { snap = nil; etag = nil; _lastOK = nil; _lastError = nil; url = cfg.url; since = Date() } }
        await pollOnce(cfg)
    }

    func pollOnce(_ cfg: JSONTeamBoardSource.Config) async {
        guard let u = URL(string: cfg.url) else { lock.withLock { _lastError = "Bad match URL" }; return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in cfg.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let tag = lock.withLock({ snap != nil ? etag : nil }) { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304 { lock.withLock { _lastError = nil; _lastOK = Date() }; return }
            if let h = http, h.statusCode == 401 || h.statusCode == 403 { throw TeamBoardError.auth }
            if let h = http, h.statusCode == 404 { throw TeamBoardError.notFound }
            if let h = http, !(200..<300).contains(h.statusCode) { throw TeamBoardError.http(h.statusCode) }
            var tag = http?.value(forHTTPHeaderField: "ETag")
            if tag == nil, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = JSONTeamBoardSource.string(o["version"]) { tag = "\"" + v + "\"" }
            try ingest(data, etag: tag)
        } catch {
            lock.withLock { _lastError = (error as? TeamBoardError)?.description ?? error.localizedDescription }   // keep the last data
        }
    }

    /// Applies one server answer (also used by tests). Throws (and keeps the old data) when it is not JSON.
    func ingest(_ data: Data, etag tag: String? = nil, now: Date = Date()) throws {
        let s = try MatchDataParser.parse(data)
        lock.withLock {
            // an answer without `teams` keeps the board rows of the previous answer
            var s = s
            if s.board == nil, let old = snap?.board { s.board = old; s.teamCount = s.teamCount ?? old.teams.count; s.aliveTeams = s.aliveTeams ?? old.teams.filter { !$0.isEliminated }.count }
            if s.controlState != snap?.controlState || s.unlocksAt != snap?.unlocksAt { snapControlChangedAt = now }
            snap = s; etag = tag; _lastError = nil; _lastOK = now
        }
        onIngest?(data)
    }
    /// additive (AirBattleground match control): every new GET …/live body (its `control` + `autoCapture` blocks). Set once at startup.
    var onIngest: (@Sendable (Data) -> Void)?

    // MARK: simulate (rehearse the journey without the server)

    /// "scheduled" | "live" | "summary" | "finished", nil = back to the server.
    func simulate(_ state: String?) { lock.withLock { if _simulated == nil || state == nil { simStart = Date() }; _simulated = state } }
    var simulated: String? { lock.withLock { _simulated } }

    // MARK: reads

    var latest: MatchSnapshot? { lock.withLock { snap } }
    /// The match state the journey follows (simulated wins).
    var state: String? { lock.withLock { _simulated ?? effectiveStage(snap)?.matchState } }
    /// Control state published by the AirBattleground match picker (ABGController), newer than the last /live answer.
    /// The newer of the two wins: whichever control value changed last (picker/start/stop vs. the polled /live body).
    func setControl(state: String?, unlocksAt: Date?, now: Date = Date()) {
        lock.withLock {
            let v = state.map { ($0.lowercased(), unlocksAt) }
            if v?.0 != _control?.state || v?.1 != _control?.unlocksAt { _control = v.map { ($0.0, $0.1, now) } }
        }
    }
    private var _control: (state: String, unlocksAt: Date?, changedAt: Date)?
    /// When the /live body's own control (state / unlocksAt) last changed.
    private var snapControlChangedAt = Date.distantPast
    private var useOverride: Bool {
        guard let c = _control else { return false }
        return snap?.controlState == nil || c.changedAt > snapControlChangedAt
    }
    private func effectiveStage(_ s: MatchSnapshot?) -> JourneyStage? {
        if useOverride, let c = _control, let st = JourneyStage.forControlState(c.state) {
            return st == .summary && s?.resultsComplete == false ? .gameplay : st
        }
        return s?.stage
    }
    private func withControl(_ s: MatchSnapshot?) -> MatchSnapshot? {
        guard useOverride, let c = _control else { return s }
        var x = s ?? MatchSnapshot()
        x.controlState = c.state; if let u = c.unlocksAt { x.unlocksAt = u }
        return x
    }
    /// What the countdown counts to right now (control.unlocksAt while locked, else match.startsAt); nil when unknown.
    var countdownTarget: Date? { lock.withLock { withControl(snap)?.countdownTarget } }
    var status: Status {
        let hasConfig = config() != nil
        return lock.withLock {
            var s = Status(lastOK: _lastOK, lastError: _lastError, state: _simulated ?? effectiveStage(snap)?.matchState, simulated: _simulated)
            // Pre-show: before the countdown, while the start (unlock) time is more than 15 min away
            if _simulated == nil, s.state == JourneyStage.startsIn.matchState, let t = withControl(snap)?.countdownTarget,
               t.timeIntervalSinceNow > JourneyStage.preShowLead { s.state = JourneyStage.preShow.matchState }
            if _simulated != nil { s.connection = .simulated }
            else if !hasConfig { s.connection = .off }
            else if _lastError != nil { s.connection = .error }
            else if _lastOK != nil { s.connection = .ok }
            else { s.connection = .connecting }
            return s
        }
    }

    /// {{MatchKeys}} values right now (countdown recomputed from startsAt on every call).
    func variables(now: Date = Date()) -> [String: String] {
        let (sim, s, start, live) = lock.withLock { () -> (String?, MatchSnapshot?, Date, Date?) in
            // {{elapsed}}: match time since the journey reached gameplay (server `match.liveAt` when given, else first seen live)
            let stage = _simulated.flatMap(JourneyStage.forMatchState) ?? effectiveStage(snap)
            if stage == .gameplay { if _liveSince == nil { _liveSince = _simulated == nil ? (snap?.liveAt ?? now) : now } } else { _liveSince = nil }
            return (_simulated, withControl(snap), simStart, _liveSince)
        }
        var v: [String: String]
        if let sim { v = Self.simulatedVariables(state: sim, started: start, now: now) }
        else if let s { v = MatchDataParser.variables(s, now: now) }
        else { return [:] }
        v[MatchKeys.elapsed] = live.map { SceneVariables.clock(Int(now.timeIntervalSince($0))) } ?? ""
        return v
    }
    /// MatchKeys.sample with the simulated state; "scheduled" counts down 5 minutes from when the simulation started.
    static func simulatedVariables(state: String, started: Date, now: Date) -> [String: String] {
        var v = MatchKeys.sample
        v[MatchKeys.matchState] = state
        v[MatchKeys.startsAt] = isoNow(started.addingTimeInterval(300))
        v[MatchKeys.startsAtLocal] = MatchKeys.localStart(started.addingTimeInterval(300))
        v[MatchKeys.countdown] = state == "scheduled" ? MatchDataParser.countdown(to: started.addingTimeInterval(300), now: now) : ""
        MatchDataParser.applyPreparing(&v, target: started.addingTimeInterval(300), startsInStage: state == "scheduled", now: now)
        if state == "scheduled" { v[MatchKeys.aliveTeams] = v[MatchKeys.teamCount] }
        return v
    }

    // MARK: TeamBoardSource

    func snapshot() -> TeamBoardData? {
        lock.lock(); defer { lock.unlock() }
        if _simulated != nil {
            var d = MockTeamBoardSource.data(count: 16, tick: Int(Date().timeIntervalSince(simStart) / 4))
            if _simulated == "scheduled" { d.teams = d.teams.map { var t = $0; t.status = 4; t.players = nil; return t } }
            return d
        }
        let stale = Date().timeIntervalSince(_lastOK ?? since) > TeamBoardHub.staleAfter
        guard var d = snap?.board else {
            if snap != nil { return TeamBoardData(title: snap?.title ?? "", teams: [], stale: stale, message: "NO TEAMS YET") }
            return stale ? TeamBoardData(stale: true, message: _lastError.map { "NO DATA - " + $0.uppercased() }) : nil
        }
        d.stale = stale
        return d
    }
}
