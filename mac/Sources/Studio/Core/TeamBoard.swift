// Dynamic "Team Status" board: data model, data sources (manual / JSON URL polling / mock), carousel timing and layout.
// Rendered by TeamBoardArt (CoreGraphics, off the render thread) into cached sprites; see LayerRenderer.teamBoardParts.
//
// DATA CONTRACT (AirBattleground source = the default; the JSON URL source uses the same default mapping).
// TODO(AirBattleground): this endpoint is specified for the AirBattleground team but not live yet -- confirm when it ships.
//
//   GET <host>/api/studio-link/matches/{matchId}/live      header X-Studio-Key: <studio key>   (If-None-Match: <version/ETag>)
//   200 -> {
//     "version": 42,                         // also sent as the ETag; a 304 answer keeps the current data
//     "updatedAt": "2026-10-23T18:00:00Z",
//     "match": { "id": "...", "title": "Grand Finals - Match 3", "state": "scheduled|live|summary|finished", "map": "Erangel" },
//                (+ startsAt, round, matchNumber, and top-level `summary` / `winner`: see Core/MatchData.swift, which polls this endpoint once
//                 for the board AND the {{MatchKeys}} scene variables / match journey)
//     "teams": [
//       { "id": "t1", "slot": 1, "name": "Team Alpha", "logo": "https://.../alpha.png", "status": 3,
//         "kills": 7, "totalPoints": 19,          // FIN. and TOT. PTS. columns (aliases: "finishes", "points")
//         "players": [ { "name": "P1", "state": "alive" }, { "state": "knocked" }, { "state": "eliminated" }, { "state": "alive" } ] },
//       ...
//     ]
//   }
//
//  - Rows = teams.count, ordered by `slot` (1-based, shown in the rank column).
//  - `status` = players still alive (0...4). 0 = team eliminated (row drawn disabled, not hidden).
//  - `players` (optional) = per-player `state` "alive" | "knocked" | "eliminated" (synonyms accepted, see PlayerState).
//    Without `players` the bars show `status` gold bars followed by grey ones. Without `status` it is derived from `players`.
//  - `kills` (FIN.) / `totalPoints` (TOT. PTS.): optional per team. When a team has none, the board looks them up in
//    `summary.teams` (same `slot`, else same `name`: its `kills` / `totalPoints`). Unknown values show a subtle "-".
//  - Team status is maintained by the match manager on AirBattleground's Match Center; the studio only reads it
//    (manual editing exists only in Manual mode). Polled every 3 s; on errors the last good data stays and the board shows a
//    small "data stale" dot after 15 s without a good answer.
import Foundation
import CoreGraphics

// MARK: - data

enum PlayerState: String, Codable, Hashable, CaseIterable, Sendable {
    case alive, knocked, eliminated
    /// Lenient parse of API values.
    init?(loose v: Any?) {
        if let b = v as? Bool { self = b ? .alive : .eliminated; return }
        if let n = v as? NSNumber { self = n.intValue == 0 ? .eliminated : (n.intValue == 2 ? .knocked : .alive); return }
        guard let s = (v as? String)?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        switch s {
        case "alive", "live", "up", "ok", "active", "playing": self = .alive
        case "knocked", "knock", "knocked_out", "knockedout", "down", "downed", "dbno": self = .knocked
        case "eliminated", "elim", "elim.", "dead", "out", "killed", "eliminado": self = .eliminated
        default: return nil
        }
    }
}

struct TeamBoardData: Hashable, Sendable {
    struct Team: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var name: String = "TEAM"
        var logoURL: String? = nil
        /// Players still in the game (alive count, 0...4). 0 = eliminated.
        var status: Int = 4
        /// Per-player states (optional; drives the bars when present).
        var players: [PlayerState]? = nil
        /// Explicit rank (nil = position in the list).
        var rank: Int? = nil
        /// FIN. column: finishes (kills) so far (nil = unknown, drawn as "-").
        var finishes: Int? = nil
        /// TOT. PTS. column: total points (nil = unknown, drawn as "-").
        var points: Int? = nil
        init(id: String = UUID().uuidString, name: String, logoURL: String? = nil, status: Int = 4, players: [PlayerState]? = nil, rank: Int? = nil,
             finishes: Int? = nil, points: Int? = nil) {
            self.id = id; self.name = name; self.logoURL = logoURL; self.status = status; self.players = players; self.rank = rank
            self.finishes = finishes; self.points = points
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = c.lenient(.id, UUID().uuidString); name = c.lenient(.name, "TEAM"); logoURL = c.lenientOpt(.logoURL)
            status = c.lenient(.status, 4); players = c.lenientOpt(.players); rank = c.lenientOpt(.rank)
            finishes = c.lenientOpt(.finishes); points = c.lenientOpt(.points)
        }
        private enum K: String, CodingKey { case id, name, logoURL, status, players, rank, finishes, points }
        var isEliminated: Bool { status <= 0 }
        /// The `count` bars, left to right.
        func bars(_ count: Int) -> [PlayerState] {
            if let p = players, !p.isEmpty {
                var out = Array(p.prefix(count))
                while out.count < count { out.append(.eliminated) }
                return out
            }
            let alive = max(0, min(count, status))
            return Array(repeating: .alive, count: alive) + Array(repeating: .eliminated, count: count - alive)
        }
    }
    var title: String = ""
    var teams: [Team] = []
    /// No good answer for `TeamBoardHub.staleAfter` seconds: the board shows a small "data stale" dot.
    var stale = false
    /// Shown instead of rows when there are no teams (e.g. "PICK AN AIRBATTLEGROUND MATCH").
    var message: String? = nil
    init(title: String = "", teams: [Team] = [], stale: Bool = false, message: String? = nil) { self.title = title; self.teams = teams; self.stale = stale; self.message = message }
}

// MARK: - configuration (stored in the layer)

/// airbattleground = the match picked in the app (Studio Link host + key, no URL typing); json = any URL; manual; mock.
enum TeamBoardSourceKind: String, Codable, CaseIterable, Sendable { case airbattleground, manual, json, mock }

/// Where to find things in the polled JSON. Paths are dot separated, array indices allowed ("data.0.teams").
/// Fields are looked up on each team object (dot paths allowed too, e.g. "team.name").
struct TeamBoardMapping: Codable, Hashable, Sendable {
    var teamsPath = "teams"
    var titlePath = "match.title"
    var idField = "id"
    var nameField = "name"
    var statusField = "status"
    var playersField = "players"
    var playerStateField = "state"
    var logoField = "logo"
    var rankField = "slot"
    /// FIN. column (aliases tried when missing: "kills", "finishes")
    var finishesField = "kills"
    /// TOT. PTS. column (aliases tried when missing: "totalPoints", "points")
    var pointsField = "totalPoints"
    /// Fallback standings for FIN. / TOT. PTS. (matched by slot, else name); empty = no fallback.
    var summaryPath = "summary.teams"
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); let z = TeamBoardMapping()
        teamsPath = c.lenient(.teamsPath, z.teamsPath); titlePath = c.lenient(.titlePath, z.titlePath); idField = c.lenient(.idField, z.idField)
        nameField = c.lenient(.nameField, z.nameField); statusField = c.lenient(.statusField, z.statusField); playersField = c.lenient(.playersField, z.playersField)
        playerStateField = c.lenient(.playerStateField, z.playerStateField); logoField = c.lenient(.logoField, z.logoField); rankField = c.lenient(.rankField, z.rankField)
        finishesField = c.lenient(.finishesField, z.finishesField); pointsField = c.lenient(.pointsField, z.pointsField); summaryPath = c.lenient(.summaryPath, z.summaryPath)
    }
    private enum K: String, CodingKey { case teamsPath, titlePath, idField, nameField, statusField, playersField, playerStateField, logoField, rankField, finishesField, pointsField, summaryPath }
}

struct TeamBoardSpec: Codable, Hashable, Sendable {
    var source = TeamBoardSourceKind.airbattleground
    /// Manual source: edited in the Inspector, saved with the scene (store.json / layer-scenes).
    var manualTeams: [TeamBoardData.Team] = TeamBoardSpec.defaultManualTeams(16)
    /// JSON source
    var url = ""
    var pollInterval = 3.0
    /// Optional request header, "Name: value" (e.g. "Authorization: Bearer abc").
    var header = ""
    var mapping = TeamBoardMapping()
    /// Mock source: number of teams (16 / 20 ...), statuses change every few seconds.
    var mockTeams = 16
    /// Line under the header: cross-fades the social strip (`handle`, with the Instagram / YouTube / web icons) and
    /// `subtitle` (bindings allowed; falls back to the data's title) every `carouselInterval` seconds.
    var handle = "airbattleground"
    var subtitle = "{{matchTitle}}"
    var carouselInterval = 5.0
    var playersPerTeam = 4
    /// Off: rows in slot order, rank column = slot. On: rows by TOT. PTS. (then FIN.), rank column = position.
    var sortByPoints = false
    /// More teams than fit: the rows scroll slowly up and down under the fixed header (off = rows shrink to fit).
    var autoScroll = true
    /// Scroll speed factor (1 = normal, ~40 px/s at 1080p; 0.5 = slow).
    var scrollSpeed = 1.0

    init(source: TeamBoardSourceKind = .airbattleground) { self.source = source }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); let z = TeamBoardSpec()
        source = c.lenient(.source, .airbattleground); manualTeams = c.lenient(.manualTeams, z.manualTeams)
        url = c.lenient(.url, ""); pollInterval = c.lenient(.pollInterval, 3); header = c.lenient(.header, ""); mapping = c.lenient(.mapping, TeamBoardMapping())
        mockTeams = c.lenient(.mockTeams, 16); handle = c.lenient(.handle, z.handle); subtitle = c.lenient(.subtitle, z.subtitle)
        carouselInterval = c.lenient(.carouselInterval, 5); playersPerTeam = max(1, min(6, c.lenient(.playersPerTeam, 4)))
        sortByPoints = c.lenient(.sortByPoints, false)
        autoScroll = c.lenient(.autoScroll, true); scrollSpeed = max(0.2, min(2, c.lenient(.scrollSpeed, 1.0)))
    }
    private enum K: String, CodingKey { case source, manualTeams, url, pollInterval, header, mapping, mockTeams, handle, subtitle, carouselInterval, playersPerTeam, sortByPoints, autoScroll, scrollSpeed }

    static func defaultManualTeams(_ n: Int) -> [TeamBoardData.Team] {
        (1...max(1, n)).map { TeamBoardData.Team(id: "team-\($0)", name: "TEAM \($0)", status: 4) }
    }
    static let maxTeams = 64
}

// MARK: - sources

/// Something that yields the board's current data. Never blocks (pollers keep their last good answer).
protocol TeamBoardSource: AnyObject, Sendable {
    func snapshot() -> TeamBoardData?
}

final class ManualTeamBoardSource: TeamBoardSource, @unchecked Sendable {
    let teams: [TeamBoardData.Team]
    let message: String?
    init(teams: [TeamBoardData.Team], message: String? = nil) { self.teams = teams; self.message = message }
    func snapshot() -> TeamBoardData? { TeamBoardData(title: "", teams: Array(teams.prefix(TeamBoardSpec.maxTeams)), message: message) }
}

/// Deterministic sample data for previews and tests. With `clock` the statuses change over time (one "tick" every `step` s).
final class MockTeamBoardSource: TeamBoardSource, @unchecked Sendable {
    let count: Int
    let clock: (@Sendable () -> Double)?
    let step: Double
    init(count: Int, clock: (@Sendable () -> Double)? = nil, step: Double = 4) { self.count = max(1, min(TeamBoardSpec.maxTeams, count)); self.clock = clock; self.step = step }
    static let names = ["SOUL", "GODLIKE", "TEAM XSPARK", "BLIND", "REVENANT", "ORANGUTAN", "GLOBAL ESPORTS", "8BIT", "MEDAL", "ENTITY",
                        "TEAM INSANE", "CHEMIN", "NEON", "SKYLIGHTZ", "RIVALRY", "TRUE RIPPERS", "OR ESPORTS", "INFINITY", "HYDRA", "FS ESPORTS",
                        "VELOCITY", "NIGHTOWLS", "STALWART", "TEAM TAMILAS", "MAMBA", "WOLFPACK", "PHOENIX", "TITANS", "VIPERS", "KRAKEN", "ZEUS", "AURORA",
                        "BLAZE", "STORM", "SPECTRE", "RAVENS", "TEAM ATLAS", "NOVA", "CYCLONE", "MIRAGE", "OUTLAWS", "VALKYRIE", "JAGUARS",
                        "ONYX", "FALCONS", "HAVOC", "ECLIPSE", "RONIN"]
    static func data(count n: Int, tick: Int = 0) -> TeamBoardData {
        let n = max(1, min(TeamBoardSpec.maxTeams, n))
        var teams: [TeamBoardData.Team] = []
        for i in 0..<n {
            // a fixed, varied pattern: ~1/4 eliminated, others mixed alive / knocked / eliminated players
            let h = (i &* 7 &+ tick &* 3 &+ 5) % 11
            var players: [PlayerState]
            switch h {
            case 0, 1: players = [.eliminated, .eliminated, .eliminated, .eliminated]
            case 2: players = [.alive, .eliminated, .eliminated, .eliminated]
            case 3: players = [.alive, .knocked, .eliminated, .eliminated]
            case 4: players = [.alive, .alive, .knocked, .eliminated]
            case 5: players = [.alive, .alive, .alive, .knocked]
            case 6: players = [.alive, .alive, .eliminated, .eliminated]
            case 7: players = [.knocked, .eliminated, .eliminated, .eliminated]
            default: players = [.alive, .alive, .alive, .alive]
            }
            let status = players.filter { $0 != .eliminated }.count
            // plausible FIN. / TOT. PTS.: 0...12 finishes growing slowly with the ticks, points = finishes + placement points
            let fin = (i &* 5 &+ 3) % 9 + (tick / 2 + i) % 3 + (i % 4 == 0 ? 3 : 0)
            let place = [10, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0][(i &* 7 &+ 2) % 12]
            teams.append(TeamBoardData.Team(id: "mock-\(i + 1)", name: names[i % names.count], status: status, players: players,
                                            finishes: fin, points: fin + place))
        }
        return TeamBoardData(title: "GRAND FINALS - MATCH 3", teams: teams)
    }
    func snapshot() -> TeamBoardData? {
        let tick = clock.map { Int(floor($0() / max(0.5, step))) } ?? 0
        return Self.data(count: count, tick: tick)
    }
}

/// Polls a JSON URL every `interval` seconds and maps it with `TeamBoardMapping`.
final class JSONTeamBoardSource: TeamBoardSource, @unchecked Sendable {
    struct Config: Hashable, Sendable {
        var url: String; var interval: Double; var header: String; var mapping: TeamBoardMapping
        /// Extra request headers (the AirBattleground source sends X-Studio-Key here; never stored in the scene).
        var headers: [String: String] = [:]
    }
    let config: Config
    private let lock = NSLock()
    private var latest: TeamBoardData?
    private var _lastError: String?
    private var _lastOK: Date?
    private var task: Task<Void, Never>?
    private var etag: String?
    private let created = Date()
    var lastError: String? { lock.withLock { _lastError } }
    var lastOK: Date? { lock.withLock { _lastOK } }
    /// Last time the renderer asked for data; the poller stops itself when nobody shows the board any more.
    private var _touched = Date()
    func touch() { lock.withLock { _touched = Date() } }
    var idleFor: TimeInterval { lock.withLock { Date().timeIntervalSince(_touched) } }

    init(config: Config) { self.config = config }
    deinit { task?.cancel() }

    func snapshot() -> TeamBoardData? {
        touch()
        return lock.withLock {
            let stale = Date().timeIntervalSince(_lastOK ?? created) > TeamBoardHub.staleAfter
            guard var d = latest else { return stale ? TeamBoardData(stale: true, message: _lastError.map { "NO DATA - " + $0.uppercased() }) : nil }
            d.stale = stale
            return d
        }
    }

    func start(onIdle: (@Sendable () -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let cfg = config
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                if self.idleFor > 30 { onIdle?(); return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, cfg.interval) * 1_000_000_000))
            }
        }
    }
    func stop() { lock.withLock { task?.cancel(); task = nil } }

    func pollOnce() async {
        guard let u = URL(string: config.url.trimmingCharacters(in: .whitespaces)), u.scheme != nil else {
            lock.withLock { _lastError = "Enter a valid URL" }; return
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: max(2, min(10, config.interval * 2)))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (k, v) = Self.header(config.header) { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let tag = lock.withLock({ latest != nil ? etag : nil }) { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304 { lock.withLock { _lastError = nil; _lastOK = Date() }; return }     // unchanged: keep the data
            if let h = http, h.statusCode == 401 || h.statusCode == 403 { throw TeamBoardError.auth }
            if let h = http, h.statusCode == 404 { throw TeamBoardError.notFound }
            if let h = http, !(200..<300).contains(h.statusCode) { throw TeamBoardError.http(h.statusCode) }
            let d = try Self.parse(data, mapping: config.mapping)
            var tag = http?.value(forHTTPHeaderField: "ETag")
            if tag == nil, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = Self.string(o["version"]) { tag = "\"" + v + "\"" }
            lock.withLock { latest = d; etag = tag; _lastError = nil; _lastOK = Date() }
        } catch {
            lock.withLock { _lastError = (error as? TeamBoardError)?.description ?? error.localizedDescription }
        }
    }
    /// "Name: value" -> (Name, value)
    static func header(_ s: String) -> (String, String)? {
        guard let i = s.firstIndex(of: ":") else { return nil }
        let k = s[..<i].trimmingCharacters(in: .whitespaces), v = s[s.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : (k, v)
    }

    // MARK: mapping

    static func value(_ root: Any?, path: String) -> Any? {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "." || p == "$" { return root }
        var cur: Any? = root
        for part in p.split(separator: ".").map(String.init) {
            if let d = cur as? [String: Any] { cur = d[part] }
            else if let a = cur as? [Any], let i = Int(part), a.indices.contains(i) { cur = a[i] }
            else { return nil }
        }
        return cur is NSNull ? nil : cur
    }
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    /// First field (dot path) holding a number or numeric string (decimals rounded); empty names skipped.
    static func number(_ o: Any?, _ fields: [String]) -> Int? {
        for f in fields where !f.isEmpty {
            let v = value(o, path: f)
            if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
            if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return Int(d.rounded()) }
        }
        return nil
    }
    static func parse(_ data: Data, mapping m: TeamBoardMapping) throws -> TeamBoardData {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw TeamBoardError.notJSON }
        guard let arr = value(root, path: m.teamsPath) as? [Any] else { throw TeamBoardError.noTeams(m.teamsPath) }
        var teams: [TeamBoardData.Team] = []
        for (i, item) in arr.prefix(TeamBoardSpec.maxTeams).enumerated() {
            guard let o = item as? [String: Any] else { continue }
            let name = string(value(o, path: m.nameField)) ?? "TEAM \(i + 1)"
            var players: [PlayerState]? = nil
            if let ps = value(o, path: m.playersField) as? [Any] {
                players = ps.compactMap { p in
                    if let d = p as? [String: Any] { return PlayerState(loose: value(d, path: m.playerStateField)) ?? .alive }
                    return PlayerState(loose: p)
                }
            }
            let status = int(value(o, path: m.statusField)) ?? players.map { $0.filter { $0 != .eliminated }.count } ?? 4
            let logo = string(value(o, path: m.logoField)).flatMap { $0.isEmpty ? nil : $0 }
            teams.append(TeamBoardData.Team(id: string(value(o, path: m.idField)) ?? "team-\(i + 1)", name: name, logoURL: logo,
                                            status: max(0, status), players: players, rank: int(value(o, path: m.rankField)),
                                            finishes: number(o, [m.finishesField, "kills", "finishes"]), points: number(o, [m.pointsField, "totalPoints", "points"])))
        }
        // FIN. / TOT. PTS. fallback: the summary standings entry with the same slot (else the same name)
        if teams.contains(where: { $0.finishes == nil || $0.points == nil }), !m.summaryPath.isEmpty, let sum = value(root, path: m.summaryPath) as? [Any] {
            let rows = sum.compactMap { $0 as? [String: Any] }
            for k in teams.indices where teams[k].finishes == nil || teams[k].points == nil {
                let t = teams[k]
                let hit = rows.first { t.rank != nil && int($0["slot"]) == t.rank }
                    ?? rows.first { string($0["name"])?.lowercased().trimmingCharacters(in: .whitespaces) == t.name.lowercased().trimmingCharacters(in: .whitespaces) }
                guard let hit else { continue }
                if teams[k].finishes == nil { teams[k].finishes = number(hit, ["kills", "finishes"]) }
                if teams[k].points == nil {
                    teams[k].points = number(hit, ["totalPoints", "points"])
                        ?? { let p = number(hit, ["placementPoints"]), q = number(hit, ["killPoints"]); return p == nil && q == nil ? nil : (p ?? 0) + (q ?? 0) }()
                }
            }
        }
        // order by slot / rank when the API gives one (stable; teams without a slot keep their order at the end)
        if teams.contains(where: { $0.rank != nil }) {
            teams = teams.enumerated().sorted { a, b in (a.element.rank ?? Int.max, a.offset) < (b.element.rank ?? Int.max, b.offset) }.map(\.element)
        }
        let title = string(value(root, path: m.titlePath)) ?? ""
        return TeamBoardData(title: title, teams: teams)
    }
}

enum TeamBoardError: Error, CustomStringConvertible, Equatable {
    case notJSON, noTeams(String), http(Int), auth, notFound
    var description: String {
        switch self {
        case .auth: "The studio key was not accepted (401/403)."
        case .notFound: "Match not found (404)."
        case .notJSON: "The URL did not return JSON."
        case .noTeams(let p): "No teams array at \"\(p)\"."
        case .http(let c): "Server answered \(c)."
        }
    }
}

// MARK: - hub (render thread entry point)

/// Process-wide registry: resolves a layer's spec to its current data. Thread-safe and non-blocking (called per frame).
final class TeamBoardHub: @unchecked Sendable {
    static let shared = TeamBoardHub()
    private let lock = NSLock()
    private var pollers: [JSONTeamBoardSource.Config: JSONTeamBoardSource] = [:]
    /// Seconds without a good answer before the board shows the "data stale" dot.
    static let staleAfter = 15.0
    /// AirBattleground Studio Link (host, key), installed by the integration; the key never goes into a scene file.
    var abgCredentials: @Sendable () -> (host: String, key: String)? = { nil }
    /// The match picked in the app (AppModel keeps it current).
    var abgMatchId: String? { get { lock.withLock { _abgMatch } } set { lock.withLock { _abgMatch = newValue } } }
    private var _abgMatch: String?
    /// Wall clock used by the live mock source (seconds).
    var mockClock: @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }

    func source(for spec: TeamBoardSpec) -> TeamBoardSource {
        switch spec.source {
        case .manual: return ManualTeamBoardSource(teams: spec.manualTeams)
        case .mock: return MockTeamBoardSource(count: spec.mockTeams, clock: mockClock)
        case .json: return poller(config(spec))
        case .airbattleground:
            // one shared poller (Core/MatchData.swift) feeds the board, the {{MatchKeys}} variables and the match journey
            let shared = MatchDataStore.shared
            if shared.simulated != nil { return shared }
            guard abgConfig() != nil else {
                let msg = abgCredentials() == nil ? "CONNECT AIRBATTLEGROUND" : "PICK AN AIRBATTLEGROUND MATCH"
                return ManualTeamBoardSource(teams: [], message: msg)
            }
            shared.start()
            return shared
        }
    }
    /// GET <host>/api/studio-link/matches/{matchId}/live with X-Studio-Key, default mapping, every 3 s.
    func abgConfig() -> JSONTeamBoardSource.Config? {
        guard let c = abgCredentials(), let m = abgMatchId, !m.isEmpty else { return nil }
        let host = c.host.hasSuffix("/") ? String(c.host.dropLast()) : c.host
        return JSONTeamBoardSource.Config(url: host + "/api/studio-link/matches/" + (m.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? m) + "/live", interval: 3, header: "",
                                          mapping: TeamBoardMapping(), headers: ["X-Studio-Key": c.key])
    }
    func data(for spec: TeamBoardSpec) -> TeamBoardData {
        let d = source(for: spec).snapshot() ?? TeamBoardData()
        return spec.sortByPoints ? Self.sortedByPoints(d) : d
    }
    /// Rows by TOT. PTS. (desc), then FIN. (desc), then slot / list order; unknown points last. Rank = position.
    static func sortedByPoints(_ d: TeamBoardData) -> TeamBoardData {
        var d = d
        d.teams = d.teams.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if (x.points ?? Int.min) != (y.points ?? Int.min) { return (x.points ?? Int.min) > (y.points ?? Int.min) }
            if (x.finishes ?? Int.min) != (y.finishes ?? Int.min) { return (x.finishes ?? Int.min) > (y.finishes ?? Int.min) }
            return (x.rank ?? Int.max, a.offset) < (y.rank ?? Int.max, b.offset)
        }.enumerated().map { i, e in var t = e.element; t.rank = i + 1; return t }
        return d
    }

    func config(_ spec: TeamBoardSpec) -> JSONTeamBoardSource.Config {
        JSONTeamBoardSource.Config(url: spec.url.trimmingCharacters(in: .whitespaces), interval: max(1, spec.pollInterval), header: spec.header, mapping: spec.mapping)
    }
    func poller(_ cfg: JSONTeamBoardSource.Config) -> JSONTeamBoardSource {
        lock.lock()
        if let p = pollers[cfg] { lock.unlock(); return p }
        let p = JSONTeamBoardSource(config: cfg)
        pollers[cfg] = p
        lock.unlock()
        p.start { [weak self] in self?.lock.withLock { _ = self?.pollers.removeValue(forKey: cfg) } }
        return p
    }
    /// Inspector status line for a JSON board.
    func status(for spec: TeamBoardSpec) -> (ok: Date?, error: String?) {
        switch spec.source {
        case .json: let p = poller(config(spec)); return (p.lastOK, p.lastError)
        case .airbattleground:
            if MatchDataStore.shared.simulated != nil { return (Date(), nil) }
            guard abgConfig() != nil else { return (nil, abgCredentials() == nil ? "Connect AirBattleground first." : "Pick the AirBattleground match first.") }
            MatchDataStore.shared.start()
            let st = MatchDataStore.shared.status; return (st.lastOK, st.lastError)
        default: return (nil, nil)
        }
    }
}

// MARK: - carousel (line under the header)

/// What the strip under the header shows: the social strip (icons + handle, as in the reference art) or the match title.
enum TeamBoardSlide: Hashable, Sendable {
    case social(String)
    case title(String)
    var key: String { switch self { case .social(let h): "s|" + h; case .title(let t): "t|" + t } }
}

enum TeamBoardCarousel {
    /// Length of the cross-fade between two slides (s).
    static let transition = 0.8
    struct State: Equatable { var index: Int; var previous: Int?; var progress: Double }
    /// Slide shown at `time`: switches every `interval` seconds; `progress` (0...1, eased) runs during the first `transition` s.
    static func state(time: Double, count: Int, interval: Double) -> State {
        guard count > 1 else { return State(index: 0, previous: nil, progress: 1) }
        let iv = max(1, interval)
        let t = max(0, time)
        let slot = Int(floor(t / iv))
        let idx = slot % count
        let phase = t - Double(slot) * iv
        if slot > 0, phase < transition {
            return State(index: idx, previous: (idx - 1 + count) % count, progress: Tween.ease(.easeInOut, phase / transition))
        }
        return State(index: idx, previous: nil, progress: 1)
    }
    /// The slides to alternate: the social strip (always first, even with an empty handle: the icons stay), then the
    /// match title (from the {{matchTitle}} binding, else the data's title) when there is one.
    static func slides(_ spec: TeamBoardSpec, data: TeamBoardData, vars: SceneVariables, defaults: [String: String] = [:]) -> [TeamBoardSlide] {
        let handle = vars.resolve(spec.handle, defaults: defaults).trimmingCharacters(in: .whitespacesAndNewlines)
        var sub = vars.resolve(spec.subtitle, defaults: defaults).trimmingCharacters(in: .whitespacesAndNewlines)
        if sub.isEmpty { sub = data.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [TeamBoardSlide] = [.social(handle)]
        if !sub.isEmpty, sub.lowercased() != handle.lowercased() { out.append(.title(sub.uppercased())) }
        return out
    }
}

// MARK: - cross-fade of data changes

/// Which board sprite is shown and whether a cross-fade from the previous one is running.
struct TeamBoardFade: Equatable {
    static let duration = 0.6
    var shown: String?
    var from: String?
    var start = 0.0
    /// `ready`: the sprite for `want` exists. Returns the new state.
    func step(want: String, ready: Bool, time: Double) -> TeamBoardFade {
        var s = self
        if s.shown != want, ready {
            if s.shown != nil { s.from = s.shown; s.start = time } else { s.from = nil }
            s.shown = want
        }
        if s.from != nil, time - s.start >= Self.duration || time < s.start { s.from = nil }
        return s
    }
    /// 0...1 opacity of the new sprite during a fade (1 when none).
    func mix(time: Double) -> Double {
        guard from != nil else { return 1 }
        return Tween.ease(.easeInOut, (time - start) / Self.duration)
    }
}

// MARK: - layout (reference art: 837 x 1879, 22 rows; everything is placed in reference units, uniformly scaled)

/// The board is drawn in reference units (837 wide) scaled uniformly by `scale` and centred horizontally (`originX`).
/// The panel ALWAYS fills the whole height of the layer box: header (brand + table head) at the top, the bottom decoration
/// (double gold rule + corner beams) closing the frame at the bottom edge, the table area in between.
/// Rows keep the reference height (~66 units = ~66 px per 837 px of width) and never shrink:
///  - few teams: rows grow evenly up to `maxGrow` x the reference height; any space left below the last team is drawn as
///    empty "filler" rows (styled continuation, see `fillerRows`), so the panel always looks complete;
///  - more teams than fit (`overflow`): the rows list is taller than the table area and scrolls inside it (`TeamBoardScroll`).
///    With `scroll: false` (auto-scroll off) the rows shrink to fit instead (the old behaviour).
struct TeamBoardLayout: Equatable {
    static let refW = 837.0, refH = 1879.0
    static let refRowsTop = 330.0, refRowsBottom = 1781.0, refRows = 22.0
    static var refRowH: Double { (refRowsBottom - refRowsTop) / refRows }
    /// Bottom decoration under the table area (double gold rule + corner beams).
    static let refFooter = refH - refRowsBottom
    /// Few teams: rows grow up to this factor of the reference height.
    static let maxGrow = 1.25
    /// Panels wider than the reference aspect are scaled so that at least this much height (header + footer + 6 rows) fits.
    static var minRefH: Double { refRowsTop + refFooter + refRowH * 6 }
    // header art (reference units)
    static let markRect = CGRect(x: 52, y: 78, width: 236, height: 236 * 210 / 397)
    static let dividerX = 303.0
    static let wordRect = CGRect(x: 323, y: 80, width: 470, height: 470 * 96 / 870)
    static let pillTop = 160.0, pillBottom = 212.0, pillLeft = 300.0, pillRight = 752.0, pillSlant = 34.0
    static let tableHeadRect = CGRect(x: 22, y: 263, width: 793, height: 54)
    // columns (reference units)
    static let rankL = 24.0, rankR = 106.0, logoX = 123.0, logoS = 48.0, nameX = 186.0
    static let sep1 = 409.0, sep2 = 520.0, sep3 = 679.0, rowR = 812.0
    static let finC = 464.5, ptsC = 599.5, statusL = 713.0, statusR = 785.0

    var size: CGSize
    var rows: Int
    /// reference unit -> board pixel
    var scale: CGFloat = 1
    var originX: CGFloat = 0
    /// row height (reference units)
    var rowHRef: CGFloat = 0
    /// bottom of the table area = top of the footer decoration (reference units); the panel always ends at the box bottom
    var rowsBottomRef: CGFloat = 0
    var panelHeightRef: CGFloat = 0
    /// height of the whole rows list (>= the table area; reference units)
    var contentHeightRef: CGFloat = 0
    /// the rows need more height than the table area: they scroll
    var overflow = false
    /// empty styled rows under the last team (few teams); the last one may be cut by the frame
    var fillerRows = 0

    init(size: CGSize, rows n: Int, scroll: Bool = true) {
        self.size = size; rows = max(0, n)
        let W = max(1, size.width), H = max(1, size.height)
        scale = min(W / Self.refW, H / Self.minRefH)
        originX = (W - Self.refW * scale) / 2
        panelHeightRef = H / scale
        rowsBottomRef = max(Self.refRowsTop + 1, panelHeightRef - Self.refFooter)
        let area = rowsBottomRef - Self.refRowsTop
        let r0 = CGFloat(Self.refRowH)
        let rowsN = CGFloat(rows)
        if rows > 0, r0 * rowsN > area + 0.5 {
            if scroll { overflow = true; rowHRef = r0; contentHeightRef = r0 * rowsN }
            else { rowHRef = area / rowsN; contentHeightRef = area }
        } else {
            rowHRef = rows > 0 ? min(r0 * CGFloat(Self.maxGrow), max(r0, area / rowsN)) : r0
            contentHeightRef = area
            let used = rows > 0 ? rowHRef * rowsN : 0
            let free = area - used
            fillerRows = free > 1 ? Int(ceil(free / rowHRef - 0.02)) : 0
        }
    }
    // reference rect -> board pixels
    func px(_ r: CGRect) -> CGRect { CGRect(x: originX + r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
    func px(x: CGFloat) -> CGFloat { originX + x * scale }

    // MARK: reference-unit rects (used by the art; rows of an overflowing list continue below the table area)
    func rowRef(_ i: Int) -> CGRect { CGRect(x: Self.rankL, y: Self.refRowsTop + CGFloat(i) * rowHRef, width: Self.rowR - Self.rankL, height: rowHRef) }
    func logoRef(_ i: Int) -> CGRect {
        let r = rowRef(i); let s = min(Self.logoS, r.height * 0.73)
        return CGRect(x: Self.logoX, y: r.midY - s / 2, width: s, height: s)
    }
    func barRefs(_ i: Int, count: Int) -> [CGRect] {
        let r = rowRef(i); let n = max(1, count)
        let w = Self.statusR - Self.statusL
        let gap = n == 4 ? 5.0 : w * 0.07
        let bw = (w - gap * CGFloat(n - 1)) / CGFloat(n)
        let bh = min(46, r.height * 0.7)
        return (0..<n).map { k in CGRect(x: Self.statusL + CGFloat(k) * (bw + gap), y: r.midY - bh / 2, width: bw, height: bh) }
    }
    func nameRef(_ i: Int) -> CGRect {
        let r = rowRef(i); let l = logoRef(i)
        let x = max(Self.nameX, l.maxX + 14)
        return CGRect(x: x, y: r.minY, width: Self.sep1 - 12 - x, height: r.height)
    }
    /// The slide window: the inside of the social strip (between the slanted ends, left of the red slash).
    static let slideRef = CGRect(x: pillLeft + pillSlant + 14, y: pillTop + 3, width: 690 - (pillLeft + pillSlant + 14) - 8, height: pillBottom - pillTop - 6)

    // MARK: board-pixel rects (renderer + tests)
    var titleRect: CGRect { px(Self.slideRef) }
    var headerRect: CGRect { px(Self.tableHeadRect) }
    /// The table area (rows viewport), full board width, rounded to whole pixels so a resting rows sprite maps 1:1.
    var viewportRect: CGRect {
        let top = (CGFloat(Self.refRowsTop) * scale).rounded(), bottom = (rowsBottomRef * scale).rounded()
        return CGRect(x: 0, y: top, width: size.width, height: max(1, bottom - top))
    }
    /// Height of the rows list in board pixels (>= the viewport height).
    var contentHeightPx: CGFloat { overflow ? max(viewportRect.height, (contentHeightRef * scale).rounded(.up)) : viewportRect.height }
    /// How far the rows list scrolls (board pixels; 0 = it fits).
    var travelPx: CGFloat { overflow ? max(0, contentHeightPx - viewportRect.height) : 0 }
    var rowsRect: CGRect { px(CGRect(x: Self.rankL, y: Self.refRowsTop, width: Self.rowR - Self.rankL, height: rowsBottomRef - Self.refRowsTop)) }
    /// Gold table frame (head + rows).
    var frameRect: CGRect { px(CGRect(x: 18, y: 254, width: 801, height: rowsBottomRef + 18 - 254)) }
    var panelRect: CGRect { px(CGRect(x: 0, y: 0, width: Self.refW, height: panelHeightRef)) }
    var rowH: CGFloat { rowHRef * scale }
    /// Row rect in board pixels at scroll offset 0 (overflowing rows lie below the viewport).
    func rowRect(_ i: Int) -> CGRect { px(rowRef(i)) }
    func logoRect(_ i: Int) -> CGRect { px(logoRef(i)) }
    func nameRect(_ i: Int) -> CGRect { px(nameRef(i)) }
    func barRects(_ i: Int, count: Int) -> [CGRect] { barRefs(i, count: count).map(px) }
    func finRect(_ i: Int) -> CGRect { let r = rowRef(i); return px(CGRect(x: Self.sep1 + 4, y: r.minY, width: Self.sep2 - Self.sep1 - 8, height: r.height)) }
    func ptsRect(_ i: Int) -> CGRect { let r = rowRef(i); return px(CGRect(x: Self.sep2 + 4, y: r.minY, width: Self.sep3 - Self.sep2 - 8, height: r.height)) }
}

// MARK: - overflow auto-scroll (pure functions of time; the renderer only keeps a phase anchor)

/// Slow ping-pong of an overflowing rows list: hold `hold` s at the top, glide down at `speed` px/s with smooth (C2,
/// smoothstep-velocity) ramps of `ramp` s at both ends, hold at the bottom, glide back up, repeat.
/// The offset (board pixels, 0 = first row at the top) is a pure function of (time, travel, speed, anchor), so stills
/// rendered with `renderStill(time:)` are deterministic. `State.retarget` keeps the visible position (and direction) when
/// the travel changes (rows added / removed) or the speed changes, so data updates never jump the list.
enum TeamBoardScroll {
    static let hold = 3.0
    static let ramp = 1.2
    /// px/s on a 1080 px tall board (scaled with the board height)
    static let baseSpeed = 40.0
    /// fade masks at the viewport edges (px on a 1080 px tall board)
    static let baseFade = 16.0

    static func speed(boardHeight h: CGFloat, factor: Double) -> Double { baseSpeed * max(0.1, factor) * Double(h) / 1080 }
    static func fade(boardHeight h: CGFloat) -> Double { baseFade * Double(h) / 1080 }

    /// Seconds of one glide over `travel` px.
    static func moveDuration(travel: Double, speed v: Double) -> Double {
        guard travel > 0, v > 0 else { return 0 }
        return travel / v + min(ramp, travel / v)
    }
    static func period(travel: Double, speed: Double) -> Double { 2 * (hold + moveDuration(travel: travel, speed: speed)) }

    /// Distance covered `t` s into a glide of `travel` px (cruise `speed`, smoothstep velocity ramps).
    static func moved(_ t: Double, travel D: Double, speed v: Double) -> Double {
        guard D > 0, v > 0 else { return 0 }
        let ta = min(ramp, D / v), T = D / v + ta
        let t = min(max(t, 0), T)
        func up(_ s: Double) -> Double { v * ta * (s * s * s - s * s * s * s / 2) }
        if t < ta { return up(t / ta) }
        if t > T - ta { return D - up((T - t) / ta) }
        return v * ta / 2 + v * (t - ta)
    }
    /// Inverse of `moved` (monotonic): the time into a glide at which `d` px are covered.
    static func timeFor(_ d: Double, travel D: Double, speed v: Double) -> Double {
        let T = moveDuration(travel: D, speed: v)
        guard D > 0, d > 0 else { return 0 }
        if d >= D { return T }
        var lo = 0.0, hi = T
        for _ in 0..<48 { let m = (lo + hi) / 2; if moved(m, travel: D, speed: v) < d { lo = m } else { hi = m } }
        return (lo + hi) / 2
    }
    /// Offset at phase `tau` (seconds into the cycle).
    static func offset(phase tau: Double, travel D: Double, speed v: Double) -> Double {
        guard D > 0, v > 0 else { return 0 }
        let M = moveDuration(travel: D, speed: v), P = 2 * (hold + M)
        var t = tau.truncatingRemainder(dividingBy: P); if t < 0 { t += P }
        if t < hold { return 0 }
        if t < hold + M { return moved(t - hold, travel: D, speed: v) }
        if t < 2 * hold + M { return D }
        return D - moved(t - 2 * hold - M, travel: D, speed: v)
    }
    /// Plain pure function of time (anchor 0): what stills and a fresh board show.
    static func offset(time: Double, travel: Double, speed: Double) -> Double { offset(phase: time, travel: travel, speed: speed) }

    /// Phase anchor of one board on air: phase(t) = phase0 + (t - t0).
    struct State: Equatable {
        var travel = 0.0, speed = 0.0, t0 = 0.0, phase0 = 0.0
        func phase(_ time: Double) -> Double { phase0 + (time - t0) }
        func offset(_ time: Double) -> Double { TeamBoardScroll.offset(phase: phase(time), travel: travel, speed: speed) }
        /// Same state for a new travel / speed, continuing from the position (and direction) shown at `time`.
        func retarget(travel D2: Double, speed v2: Double, time: Double) -> State {
            if D2 == travel && v2 == speed { return self }
            var s = State(travel: D2, speed: v2, t0: time, phase0: 0)
            guard travel > 0, speed > 0, D2 > 0, v2 > 0 else {
                // starting (or stopping) to scroll: begin with the hold at the top
                return s
            }
            let D = travel, M = TeamBoardScroll.moveDuration(travel: D, speed: speed), P = 2 * (hold + M)
            var t = phase(time).truncatingRemainder(dividingBy: P); if t < 0 { t += P }
            let o = offset(time)
            let M2 = TeamBoardScroll.moveDuration(travel: D2, speed: v2)
            if t < hold { s.phase0 = t }                                                      // holding at the top
            else if t < hold + M || (t < 2 * hold + M && D2 > o + 0.5) {                      // gliding down (or more to go)
                s.phase0 = o >= D2 ? hold + M2 : hold + TeamBoardScroll.timeFor(o, travel: D2, speed: v2)
            } else if t < 2 * hold + M { s.phase0 = hold + M2 + (t - hold - M) }              // holding at the bottom
            else { s.phase0 = 2 * hold + M2 + TeamBoardScroll.timeFor(D2 - min(o, D2), travel: D2, speed: v2) }   // gliding up
            return s
        }
    }
}
