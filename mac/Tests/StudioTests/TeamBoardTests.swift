import Testing
import Foundation
import CoreGraphics
@testable import Studio

/// Team Status board: layout, data mapping, carousel, cross-fade, Codable, rendering (stills go to /tmp/board2-shots).
struct TeamBoardTests {
    // MARK: helpers

    struct Pixels {
        let w: Int, h: Int; var buf: [UInt8]
        init(_ img: CGImage) {
            w = img.width; h = img.height; buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        /// (r, g, b) 0...1 at top-left-origin pixel
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * w + x) * 4
            return (Double(buf[i]) / 255, Double(buf[i + 1]) / 255, Double(buf[i + 2]) / 255)
        }
        func mean(_ r: CGRect) -> (Double, Double, Double) {
            var s = (0.0, 0.0, 0.0); var n = 0.0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { let p = rgb(x, y); s.0 += p.0; s.1 += p.1; s.2 += p.2; n += 1 } }
            return (s.0 / n, s.1 / n, s.2 / n)
        }
    }
    static func teams(_ statuses: [Int]) -> [TeamBoardData.Team] {
        statuses.enumerated().map { TeamBoardData.Team(id: "t\($0.offset)", name: "TEAM \($0.offset + 1)", status: $0.element) }
    }
    static func boardScene(_ spec: TeamBoardSpec) -> LayerScene {
        LayerScene(id: "board-test", name: "Board", background: .solid(.black), layers: [LayerFactory.teamBoard(canvas: CanvasSize(), spec: spec)])
    }

    // MARK: layout

    @Test func boardLayoutFullHeightRowsNeverShrink() {
        typealias T = TeamBoardLayout
        let ref = CGSize(width: T.refW, height: T.refH), hd = CGSize(width: 481, height: 1080)
        let r0 = CGFloat(T.refRowH)
        // 22 rows = the reference art exactly (rows 330...1781, panel = the whole art), no scrolling, no filler
        let l22 = T(size: ref, rows: 22)
        #expect(abs(l22.rowHRef - r0) < 0.01 && !l22.overflow && l22.fillerRows == 0 && l22.travelPx == 0)
        #expect(abs(Double(l22.rowRect(21).maxY) - T.refRowsBottom) < 0.01)
        // the table area is the box height minus the fixed header and footer
        for size in [ref, hd, CGSize(width: 246, height: 760), CGSize(width: 962, height: 2160)] {
            let L = T(size: size, rows: 10)
            #expect(abs(L.panelRect.maxY - size.height) < 0.01, "panel fills the box height")
            #expect(abs((L.rowsBottomRef - T.refRowsTop) - (size.height / L.scale - T.refRowsTop - T.refFooter)) < 0.01)
            #expect(abs(L.viewportRect.minY - (T.refRowsTop * L.scale).rounded()) < 0.01 && abs(L.viewportRect.maxY - (L.rowsBottomRef * L.scale).rounded()) < 0.01)
        }
        // a wider-than-reference box keeps a sane scale (header + footer + 6 rows fit) and is centred
        let wide = T(size: CGSize(width: 1920, height: 1080), rows: 16)
        #expect(wide.panelRect.minX > 0 && abs(wide.panelRect.midX - 960) < 0.5 && wide.viewportRect.height >= T.refRowH * 6 * wide.scale - 1)
        for n in [1, 12, 16, 20, 22, 28, 40, 64] {
            let L = T(size: hd, rows: n), area = L.rowsBottomRef - T.refRowsTop
            #expect(abs(L.panelRect.maxY - 1080) < 0.01 && L.frameRect.maxY < 1080 && L.frameRect.maxY > 1080 - 60, "frame closes at the bottom (\(n))")
            #expect(L.rowHRef >= r0 - 0.001, "rows never shrink (\(n))")
            #expect(L.rowHRef <= r0 * CGFloat(T.maxGrow) + 0.001, "rows grow at most 1.25x (\(n))")
            #expect(L.overflow == (CGFloat(n) * r0 > area + 0.5))
            if L.overflow {
                #expect(abs(L.rowHRef - r0) < 0.001 && L.fillerRows == 0)
                #expect(abs(L.travelPx - (CGFloat(n) * r0 * L.scale - L.viewportRect.height)) < 1.01)
            } else {
                #expect(L.travelPx == 0 && abs(L.contentHeightPx - L.viewportRect.height) < 0.01)
                // rows + empty filler rows cover the whole table area; fillers only when the grown rows leave space
                let used = L.rowHRef * CGFloat(n)
                #expect(used + L.rowHRef * CGFloat(L.fillerRows) >= area - 0.5)
                #expect(L.fillerRows == 0 || used + L.rowHRef * CGFloat(L.fillerRows - 1) < area)
                if L.rowHRef < r0 * CGFloat(T.maxGrow) - 0.001 { #expect(abs(used - area) < 0.01 && L.fillerRows == 0) }   // grown to fill exactly
            }
            for i in 1..<max(1, n) { #expect(abs(L.rowRect(i).minY - L.rowRect(i - 1).maxY) < 0.001) }
            #expect(L.rowRect(0).minY >= L.headerRect.maxY && L.titleRect.maxY <= L.headerRect.minY)
            let bars = L.barRects(n - 1, count: 4)
            #expect(bars.count == 4 && bars.allSatisfy { L.rowRect(n - 1).contains($0) })
            #expect(L.nameRect(0).maxX < L.finRect(0).minX && L.finRect(0).maxX < L.ptsRect(0).minX && L.ptsRect(0).maxX < bars[0].minX)
        }
        // specific counts at the normal 1080p size (22 reference rows fit)
        #expect(abs(T(size: hd, rows: 12).rowHRef - r0 * 1.25) < 0.001 && T(size: hd, rows: 12).fillerRows == 6)
        #expect(abs(T(size: hd, rows: 16).rowHRef - r0 * 1.25) < 0.001 && T(size: hd, rows: 16).fillerRows == 2)
        #expect(abs(T(size: hd, rows: 20).rowHRef - (T(size: hd, rows: 20).rowsBottomRef - T.refRowsTop) / 20) < 0.001 && T(size: hd, rows: 20).fillerRows == 0)
        #expect(!T(size: hd, rows: 22).overflow && T(size: hd, rows: 23).overflow && T(size: hd, rows: 40).overflow)
        #expect(T(size: hd, rows: 0).fillerRows > 0)                              // no teams: an empty, still complete table
        // auto-scroll off: the old behaviour, rows shrink to fit the table area
        let shrink = T(size: hd, rows: 40, scroll: false)
        #expect(!shrink.overflow && shrink.travelPx == 0 && abs(shrink.rowHRef * 40 - (shrink.rowsBottomRef - T.refRowsTop)) < 0.01)
    }

    // MARK: auto-scroll

    @Test func boardScrollPingPong() {
        typealias S = TeamBoardScroll
        let D = 600.0, v = S.speed(boardHeight: 1080, factor: 1)
        #expect(v == 40 && S.speed(boardHeight: 2160, factor: 1) == 80 && S.speed(boardHeight: 1080, factor: 0.5) == 20)
        let M = S.moveDuration(travel: D, speed: v), P = S.period(travel: D, speed: v)
        #expect(abs(M - (D / v + S.ramp)) < 1e-9 && abs(P - 2 * (S.hold + M)) < 1e-9)
        // holds: 3 s at the top, 3 s at the bottom
        for t in [0, 1, 2.999] { #expect(S.offset(time: t, travel: D, speed: v) == 0) }
        for t in [S.hold + M, S.hold + M + 1.5, 2 * S.hold + M - 0.001] { #expect(abs(S.offset(time: t, travel: D, speed: v) - D) < 1e-6) }
        // period: back at the top, then repeats
        #expect(S.offset(time: P, travel: D, speed: v) == 0 && abs(S.offset(time: P + 7, travel: D, speed: v) - S.offset(time: 7, travel: D, speed: v)) < 1e-9)
        // easing: starts / ends at rest, cruises at ~40 px/s in the middle
        let dt = 0.05
        #expect(S.offset(time: S.hold + dt, travel: D, speed: v) < v * dt * 0.05)
        #expect(D - S.offset(time: S.hold + M - dt, travel: D, speed: v) < v * dt * 0.05)
        let mid = S.hold + M / 2
        #expect(abs((S.offset(time: mid + 0.1, travel: D, speed: v) - S.offset(time: mid, travel: D, speed: v)) / 0.1 - v) < 0.01)
        #expect(abs(S.offset(time: mid, travel: D, speed: v) - D / 2) < 0.01)        // symmetric glide
        // smooth at 60 fps: no step above the cruise speed, no velocity jump above the ramp's acceleration
        var prev = 0.0, prevV = 0.0, maxStep = 0.0, maxDV = 0.0
        for f in 1...Int(2 * P * 60) {
            let o = S.offset(time: Double(f) / 60, travel: D, speed: v)
            let vel = (o - prev) * 60
            maxStep = max(maxStep, abs(o - prev)); maxDV = max(maxDV, abs(vel - prevV))
            prev = o; prevV = vel
        }
        #expect(maxStep <= v / 60 * 1.001, "max \(maxStep) px per frame")
        #expect(maxDV < v * 1.5 / S.ramp / 60 * 1.05, "velocity changes by \(maxDV) px/s per frame")
        // short travel (ramps meet): still ends exactly at the bottom, never overshoots
        let small = 20.0
        #expect(abs(S.offset(time: S.hold + S.moveDuration(travel: small, speed: v), travel: small, speed: v) - small) < 1e-9)
        for i in 0...400 { let o = S.offset(time: Double(i) * 0.05, travel: small, speed: v); #expect(o >= 0 && o <= small + 1e-9) }
        // inverse
        for d in [0.0, 1, 10, 300, 599, 600] { #expect(abs(S.moved(S.timeFor(d, travel: D, speed: v), travel: D, speed: v) - d) < 1e-6) }
        // nothing to scroll
        #expect(S.offset(time: 12, travel: 0, speed: v) == 0)
    }

    @Test func boardScrollKeepsPositionWhenRowsChange() {
        typealias S = TeamBoardScroll
        let v = 40.0, D = 600.0, row = 38.0
        let M = S.moveDuration(travel: D, speed: v)
        let st = S.State().retarget(travel: D, speed: v, time: 0)
        #expect(st.offset(5) == S.offset(time: 5, travel: D, speed: v))          // a fresh board = the pure function of time
        // a row added / removed at any point of the cycle: the visible offset stays (unless the list got shorter than it), direction kept
        for t in stride(from: 0.5, to: 2 * (S.hold + M), by: 0.37) {
            let o = st.offset(t), dir = st.offset(t + 0.05) - st.offset(t - 0.05)
            for D2 in [D + row, D - row, D + 5 * row] {
                let s2 = st.retarget(travel: D2, speed: v, time: t)
                let o2 = s2.offset(t)
                if o <= D2 { #expect(abs(o2 - o) < 0.01, "t \(t) D2 \(D2): \(o) -> \(o2)") } else { #expect(abs(o2 - D2) < 0.01) }
                let dir2 = s2.offset(t + 0.05) - o2
                if abs(dir) > 0.5, o < D2 - 2 { #expect(dir2 * dir >= 0, "direction kept at t \(t)") }
                // and it keeps going smoothly afterwards
                var p = o2
                for f in 1...120 { let q = s2.offset(t + Double(f) / 60); #expect(abs(q - p) <= v / 60 * 1.001 + 1e-6); p = q }
            }
        }
        // speed change mid-glide: same position
        let t = S.hold + 4
        #expect(abs(st.retarget(travel: D, speed: 20, time: t).offset(t) - st.offset(t)) < 0.01)
        // unchanged inputs: the same anchor (deterministic)
        #expect(st.retarget(travel: D, speed: v, time: 99) == st)
    }

    // MARK: rendering

    // MARK: rendering

    @Test func eliminatedRowIsGreyedOut() throws {
        let data = TeamBoardData(teams: Self.teams([0, 4, 0, 4]) + Self.teams(Array(repeating: 4, count: 12)))
        let w = 836, h = 1881
        let img = try #require(TeamBoardArt.board(data, players: 4, w: w, h: h))
        let px = Pixels(img)
        let L = TeamBoardLayout(size: CGSize(width: w, height: h), rows: 16)
        func barMean(_ row: Int) -> (Double, Double, Double) { px.mean(L.barRects(row, count: 4)[0].insetBy(dx: 2, dy: 4)) }
        let out = barMean(0), alive = barMean(1)
        // alive bars are gold (warm, bright); an eliminated team's bars are dim and colourless
        #expect(alive.0 > 0.55 && alive.0 - alive.2 > 0.25)
        #expect(out.0 < alive.0 * 0.6)
        #expect(abs(out.0 - out.2) < 0.08)
        // the name text of an eliminated team is dimmer than an alive one
        func brightest(_ row: Int) -> Double {
            let r = L.nameRect(row); var m = 0.0
            for y in stride(from: Int(r.minY) + 2, to: Int(r.maxY) - 2, by: 1) { for x in stride(from: Int(r.minX), to: Int(r.minX + 120), by: 1) { let p = px.rgb(x, y); m = max(m, (p.0 + p.1 + p.2) / 3) } }
            return m
        }
        #expect(brightest(1) > 0.8)
        #expect(brightest(0) < 0.5)
    }

    @Test func knockedBarIsRed() throws {
        let t = TeamBoardData.Team(name: "X", status: 3, players: [.alive, .knocked, .eliminated, .alive])
        let img = try #require(TeamBoardArt.board(TeamBoardData(teams: [t]), players: 4, w: 836, h: 1881))
        let px = Pixels(img), L = TeamBoardLayout(size: CGSize(width: 836, height: 1881), rows: 1)
        let bars = L.barRects(0, count: 4).map { px.mean($0.insetBy(dx: 2, dy: 6)) }
        #expect(bars[1].0 > 0.5 && bars[1].1 < 0.3)                   // red
        #expect(bars[0].0 > 0.55 && bars[0].0 - bars[0].2 > 0.25)    // gold
        #expect(abs(bars[2].0 - bars[2].2) < 0.08)                    // grey
    }

    @Test func barsFromStatusOrPlayers() {
        #expect(TeamBoardData.Team(name: "A", status: 2).bars(4) == [.alive, .alive, .eliminated, .eliminated])
        #expect(TeamBoardData.Team(name: "A", status: 0).bars(4) == [.eliminated, .eliminated, .eliminated, .eliminated])
        #expect(TeamBoardData.Team(name: "A", status: 1, players: [.knocked]).bars(4) == [.knocked, .eliminated, .eliminated, .eliminated])
    }

    // MARK: JSON

    static let documented = """
    { "match": { "title": "Grand Finals - Match 3" },
      "teams": [
        { "id": "t1", "name": "Team Alpha", "status": 4, "logo": "https://example.com/a.png",
          "players": [ {"state": "alive"}, {"state": "alive"}, {"state": "knocked"}, {"state": "alive"} ] },
        { "id": 2, "name": "Bravo", "status": 0, "players": [ {"state": "eliminated"}, {"state": "eliminated"}, {"state": "eliminated"}, {"state": "eliminated"} ] },
        { "name": "Charlie", "players": [ {"state": "dead"}, {"state": "down"}, {"state": "alive"}, {"state": "out"} ] },
        { "name": "Delta", "status": "3" }
      ] }
    """
    @Test func boardJSONMappingParsesDocumentedShape() throws {
        let d = try JSONTeamBoardSource.parse(Data(Self.documented.utf8), mapping: TeamBoardMapping())
        #expect(d.title == "Grand Finals - Match 3")
        #expect(d.teams.count == 4)
        #expect(d.teams[0].name == "Team Alpha" && d.teams[0].status == 4 && d.teams[0].logoURL == "https://example.com/a.png")
        #expect(d.teams[0].players == [.alive, .alive, .knocked, .alive])
        #expect(d.teams[1].id == "2" && d.teams[1].isEliminated)
        #expect(d.teams[2].players == [.eliminated, .knocked, .alive, .eliminated] && d.teams[2].status == 2)   // derived from players
        #expect(d.teams[3].status == 3 && d.teams[3].players == nil)
    }
    @Test func boardJSONCustomMapping() throws {
        let json = #"{ "data": { "event": { "name": "Finals" }, "squads": [ { "team": { "label": "Zed" }, "alive": 1, "members": [true, false, false, false] } ] } }"#
        var m = TeamBoardMapping()
        m.teamsPath = "data.squads"; m.titlePath = "data.event.name"; m.nameField = "team.label"; m.statusField = "alive"; m.playersField = "members"
        let d = try JSONTeamBoardSource.parse(Data(json.utf8), mapping: m)
        #expect(d.title == "Finals" && d.teams.first?.name == "Zed" && d.teams.first?.status == 1)
        #expect(d.teams.first?.players == [.alive, .eliminated, .eliminated, .eliminated])
        #expect(throws: TeamBoardError.noTeams("teams")) { try JSONTeamBoardSource.parse(Data(json.utf8), mapping: TeamBoardMapping()) }
        #expect(throws: TeamBoardError.notJSON) { try JSONTeamBoardSource.parse(Data("<html>".utf8), mapping: m) }
        #expect(JSONTeamBoardSource.header("Authorization: Bearer a:b")! == ("Authorization", "Bearer a:b"))
        #expect(JSONTeamBoardSource.header("nonsense") == nil)
    }
    @Test func boardJSONPollerServesLocalFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString).json")
        try Data(Self.documented.utf8).write(to: url)
        let src = JSONTeamBoardSource(config: .init(url: url.absoluteString, interval: 1, header: "X-Key: 1", mapping: TeamBoardMapping()))
        await src.pollOnce()
        #expect(src.lastError == nil)
        #expect(src.snapshot()?.teams.count == 4)
    }

    static let abgLive = """
    { "version": 42, "updatedAt": "2026-10-23T18:00:00Z",
      "match": { "id": "m1", "title": "Grand Finals - Match 3", "state": "live", "map": "Erangel" },
      "teams": [
        { "id": "b", "slot": 2, "name": "Bravo", "status": 0 },
        { "id": "a", "slot": 1, "name": "Alpha", "logo": "https://example.com/a.png", "status": 3,
          "players": [ {"name": "P1", "state": "alive"}, {"state": "knocked"}, {"state": "eliminated"}, {"state": "alive"} ] },
        { "id": "c", "slot": 3, "name": "Charlie", "status": 2 }
      ] }
    """
    @Test func boardAirBattlegroundContract() throws {
        let d = try JSONTeamBoardSource.parse(Data(Self.abgLive.utf8), mapping: TeamBoardMapping())
        #expect(d.title == "Grand Finals - Match 3")
        #expect(d.teams.map(\.name) == ["Alpha", "Bravo", "Charlie"])          // ordered by slot
        #expect(d.teams.map(\.rank) == [1, 2, 3])
        #expect(d.teams[1].isEliminated && d.teams[0].players?[1] == .knocked)
        #expect(d.teams[2].bars(4) == [.alive, .alive, .eliminated, .eliminated])   // no players: status gold, rest grey
        // the AirBattleground source builds the live URL from the Studio Link host + picked match, key in a header only
        let hub = TeamBoardHub()
        #expect(hub.abgConfig() == nil)
        if case let empty = hub.data(for: TeamBoardSpec()), true { #expect(empty.teams.isEmpty && empty.message == "CONNECT AIRBATTLEGROUND") }
        hub.abgCredentials = { ("https://airbattleground.com/", "sw_test") }
        #expect(hub.data(for: TeamBoardSpec()).message == "PICK AN AIRBATTLEGROUND MATCH")
        hub.abgMatchId = "match 7"
        let cfg = try #require(hub.abgConfig())
        #expect(cfg.url == "https://airbattleground.com/api/studio-link/matches/match%207/live")
        #expect(cfg.headers == ["X-Studio-Key": "sw_test"] && cfg.interval == 3 && !cfg.url.contains("sw_test"))
    }
    @Test func boardStaleKeepsLastGoodData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString).json")
        try Data(Self.abgLive.utf8).write(to: url)
        let src = JSONTeamBoardSource(config: .init(url: url.absoluteString, interval: 1, header: "", mapping: TeamBoardMapping()))
        await src.pollOnce()
        #expect(src.snapshot()?.stale == false)
        try FileManager.default.removeItem(at: url)          // source goes away: error, data kept
        await src.pollOnce()
        #expect(src.lastError != nil)
        #expect(src.snapshot()?.teams.count == 3)
    }

    // MARK: FIN. / TOT. PTS.

    static let finPts = """
    { "match": { "title": "M" },
      "teams": [
        { "slot": 1, "name": "Alpha", "status": 4, "kills": 7, "totalPoints": 19 },
        { "slot": 2, "name": "Bravo", "status": 2, "finishes": "3", "points": 8.6 },
        { "slot": 3, "name": "Charlie", "status": 0 },
        { "slot": 4, "name": "Delta", "status": 1, "kills": 2 },
        { "name": "Echo", "status": 3 },
        { "slot": 6, "name": "Foxtrot", "status": 3 }
      ],
      "summary": { "teams": [
        { "slot": 3, "name": "Charlie", "kills": 11, "totalPoints": 26 },
        { "slot": 4, "name": "Delta", "kills": 9, "totalPoints": 14 },
        { "name": "echo", "kills": 1, "placementPoints": 3, "killPoints": 1 },
        { "slot": 1, "name": "Alpha", "kills": 99, "totalPoints": 99 }
      ] } }
    """
    @Test func boardFinishesAndPointsMapping() throws {
        let d = try JSONTeamBoardSource.parse(Data(Self.finPts.utf8), mapping: TeamBoardMapping())
        func t(_ n: String) -> TeamBoardData.Team? { d.teams.first { $0.name == n } }
        #expect(t("Alpha")?.finishes == 7 && t("Alpha")?.points == 19)            // team values win over the summary
        #expect(t("Bravo")?.finishes == 3 && t("Bravo")?.points == 9)             // aliases, strings and decimals
        #expect(t("Charlie")?.finishes == 11 && t("Charlie")?.points == 26)       // summary fallback by slot
        #expect(t("Delta")?.finishes == 2 && t("Delta")?.points == 14)            // partly from the team, partly from the summary
        #expect(t("Echo")?.finishes == 1 && t("Echo")?.points == 4)               // by name (case-insensitive); placement + kill points
        #expect(t("Foxtrot")?.finishes == nil && t("Foxtrot")?.points == nil)     // unknown: drawn as "-"
        // the documented contract without any numbers keeps them unknown
        let plain = try JSONTeamBoardSource.parse(Data(Self.abgLive.utf8), mapping: TeamBoardMapping())
        #expect(plain.teams.allSatisfy { $0.finishes == nil && $0.points == nil })
        // custom fields; an empty summary path disables the fallback
        var m = TeamBoardMapping(); m.finishesField = "stats.f"; m.pointsField = "stats.p"; m.summaryPath = ""
        let custom = #"{ "teams": [ { "name": "Z", "stats": { "f": 4, "p": 12 } }, { "slot": 3, "name": "Charlie" } ], "summary": { "teams": [ { "slot": 3, "kills": 1 } ] } }"#
        let c = try JSONTeamBoardSource.parse(Data(custom.utf8), mapping: m)
        #expect(c.teams.first { $0.name == "Z" }?.points == 12 && c.teams.first { $0.name == "Z" }?.finishes == 4)
        #expect(c.teams.first { $0.name == "Charlie" }?.finishes == nil)
        // the shared /live poller feeds the same numbers to the board
        let snap = try MatchDataParser.parse(Data(Self.finPts.utf8))
        #expect(snap.board?.teams.first { $0.name == "Charlie" }?.points == 26)
    }
    @Test func boardSortByPoints() {
        let teams = [TeamBoardData.Team(id: "a", name: "A", rank: 1, finishes: 2, points: 10), TeamBoardData.Team(id: "b", name: "B", rank: 2, finishes: 5, points: 21),
                     TeamBoardData.Team(id: "c", name: "C", rank: 3), TeamBoardData.Team(id: "d", name: "D", rank: 4, finishes: 6, points: 10)]
        let s = TeamBoardHub.sortedByPoints(TeamBoardData(teams: teams))
        #expect(s.teams.map(\.name) == ["B", "D", "A", "C"])      // points desc, FIN. breaks ties, unknown last
        #expect(s.teams.map(\.rank) == [1, 2, 3, 4])               // rank = position
        var spec = TeamBoardSpec(source: .manual); spec.manualTeams = teams
        #expect(TeamBoardHub.shared.data(for: spec).teams.map(\.name) == ["A", "B", "C", "D"])   // default OFF: slot order
        spec.sortByPoints = true
        #expect(TeamBoardHub.shared.data(for: spec).teams.first?.name == "B")
    }
    @Test func boardMockHasPlausibleNumbers() {
        let d = MockTeamBoardSource.data(count: 22, tick: 3)
        #expect(d.teams.allSatisfy { ($0.finishes ?? -1) >= 0 && ($0.finishes ?? 99) <= 15 && ($0.points ?? -1) >= ($0.finishes ?? 0) })
        #expect(Set(d.teams.compactMap(\.points)).count > 5)
    }

    // MARK: carousel & fade

    @Test func boardCarouselTiming() {
        typealias C = TeamBoardCarousel
        #expect(C.state(time: 0, count: 2, interval: 5) == .init(index: 0, previous: nil, progress: 1))
        #expect(C.state(time: 4.9, count: 2, interval: 5).index == 0)
        let mid = C.state(time: 5 + C.transition / 2, count: 2, interval: 5)
        #expect(mid.index == 1 && mid.previous == 0 && mid.progress > 0.2 && mid.progress < 0.8)
        #expect(C.state(time: 5 + C.transition + 0.01, count: 2, interval: 5) == .init(index: 1, previous: nil, progress: 1))
        let back = C.state(time: 10.1, count: 2, interval: 5)
        #expect(back.index == 0 && back.previous == 1)
        #expect(C.state(time: 123, count: 1, interval: 5) == .init(index: 0, previous: nil, progress: 1))
        // slides: social handle + {{matchTitle}}, falling back to the data title; an empty title leaves the social strip alone
        var spec = TeamBoardSpec()
        #expect(C.slides(spec, data: TeamBoardData(), vars: SceneVariables(["matchTitle": "Finals"])) == [.social("airbattleground"), .title("FINALS")])
        #expect(C.slides(spec, data: TeamBoardData(title: "Match 4"), vars: SceneVariables()) == [.social("airbattleground"), .title("MATCH 4")])
        #expect(C.slides(spec, data: TeamBoardData(), vars: SceneVariables()) == [.social("airbattleground")])
        spec.handle = ""
        #expect(C.slides(spec, data: TeamBoardData(title: "M"), vars: SceneVariables()) == [.social(""), .title("M")])
    }
    @Test func boardFadeOnDataChange() {
        var f = TeamBoardFade().step(want: "a", ready: true, time: 1)
        #expect(f.shown == "a" && f.from == nil && f.mix(time: 1) == 1)
        f = f.step(want: "b", ready: false, time: 2)              // not rasterised yet: keep showing a
        #expect(f.shown == "a" && f.from == nil)
        f = f.step(want: "b", ready: true, time: 3)
        #expect(f.shown == "b" && f.from == "a" && f.mix(time: 3) == 0)
        #expect(f.mix(time: 3 + TeamBoardFade.duration / 2) > 0.3)
        f = f.step(want: "b", ready: true, time: 3 + TeamBoardFade.duration + 0.01)
        #expect(f.from == nil && f.mix(time: 10) == 1)
    }

    // MARK: Codable

    @Test func boardCodableRoundTrip() throws {
        var spec = TeamBoardSpec(source: .json)
        spec.url = "https://example.com/match.json"; spec.header = "Authorization: Bearer x"; spec.pollInterval = 2
        spec.mapping.teamsPath = "data.teams"; spec.manualTeams = Self.teams([4, 0, 2]); spec.carouselInterval = 7
        spec.manualTeams[0].finishes = 5; spec.manualTeams[0].points = 17; spec.sortByPoints = true; spec.handle = "abg"; spec.mapping.pointsField = "pts"
        spec.autoScroll = false; spec.scrollSpeed = 0.6
        let scene = Self.boardScene(spec)
        let enc = try JSONEncoder().encode(scene)
        let back = try JSONDecoder().decode(LayerScene.self, from: enc)
        #expect(back == scene)
        guard case .teamBoard(let s2) = back.layers[0].kind else { Issue.record("kind lost"); return }
        #expect(s2 == spec)
        // lenient: a bare board layer gets defaults; an unknown future layer type still decodes (as an empty group)
        let bare = #"{"id":"x","name":"B","kind":{"type":"teamBoard"}}"#
        let l = try JSONDecoder().decode(Layer.self, from: Data(bare.utf8))
        #expect(l.kind == .teamBoard(TeamBoardSpec()))
        let partial = #"{"type":"teamBoard","board":{"source":"mock","mockTeams":20,"manualTeams":[{"name":"Solo","status":"oops"}]}}"#
        let k = try JSONDecoder().decode(LayerKind.self, from: Data(partial.utf8))
        guard case .teamBoard(let s3) = k else { Issue.record("partial"); return }
        #expect(s3.source == .mock && s3.mockTeams == 20 && s3.manualTeams.first?.name == "Solo" && s3.manualTeams.first?.status == 4)
        #expect(s3.manualTeams.first?.finishes == nil && s3.manualTeams.first?.points == nil && !s3.sortByPoints && s3.handle == "airbattleground")
        // an older scene (brandTitle, no finishes / points) still decodes and takes the new look
        let old = #"{"type":"teamBoard","board":{"source":"manual","brandTitle":"AIRBATTLEGROUND","subtitle":"{{matchTitle}}","manualTeams":[{"id":"a","name":"A","status":2}],"mapping":{"teamsPath":"teams"}}}"#
        guard case .teamBoard(let s4) = try JSONDecoder().decode(LayerKind.self, from: Data(old.utf8)) else { Issue.record("old"); return }
        #expect(s4.autoScroll && s4.scrollSpeed == 1)                // older scenes: auto-scroll on, normal speed
        #expect(s3.autoScroll && s3.scrollSpeed == 1)
        #expect(s4.manualTeams.count == 1 && s4.manualTeams[0].status == 2 && s4.mapping.finishesField == "kills" && s4.mapping.summaryPath == "summary.teams")
        let future = #"{"id":"y","kind":{"type":"hologram","x":1}}"#
        #expect(try JSONDecoder().decode(Layer.self, from: Data(future.utf8)).kind == .group([]))
    }

    // MARK: engine stills (LOOK at them: /tmp/board3-shots)

    static func manual(_ n: Int) -> TeamBoardSpec {
        var spec = TeamBoardSpec(source: .manual); spec.manualTeams = MockTeamBoardSource.data(count: n).teams; return spec
    }

    @Test func boardEngineStills() throws {
        let dir = "/tmp/board3-shots"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let e = StudioEngine()
        let vars = SceneVariables(["matchTitle": "Grand Finals - Match 3"])
        for n in [12, 16, 22, 28, 40] {
            let scene = Self.boardScene(Self.manual(n))
            let layer = scene.layers[0].transform
            let L = TeamBoardLayout(size: CGSize(width: layer.w, height: layer.h), rows: n)
            let times: [Double] = L.overflow ? [0, 3, 8, 15, 25] : [1]
            var shots: [Double: Pixels] = [:]
            for t in times {
                let img = try #require(e.renderStill(scene, size: CGSize(width: 1920, height: 1080), variables: vars, time: t))
                let tag = L.overflow ? "t\(Int(t))" : "still"
                ShotsTests.writePNG(img, "\(dir)/board-\(n)-\(tag).png")
                if let crop = img.cropping(to: CGRect(x: Int(layer.x), y: 0, width: Int(layer.w), height: 1080)) { ShotsTests.writePNG(crop, "\(dir)/board-\(n)-\(tag)-crop.png") }
                let px = Pixels(img)
                shots[t] = px
                let hr = L.headerRect.offsetBy(dx: layer.x, dy: layer.y)
                let head = px.mean(CGRect(x: hr.minX + 140, y: hr.minY + 6, width: 60, height: 6))
                #expect(head.0 > 0.6 && head.0 - head.2 > 0.2, "gold table head visible (\(n) t \(t))")
                #expect(px.mean(CGRect(x: 100, y: 100, width: 200, height: 200)).0 < 0.02)
                // full height: the gold frame's bottom rule sits near the bottom edge of the canvas
                let fy = Int(L.frameRect.maxY.rounded())
                var gold = 0.0
                for y in (fy - 4)...min(1079, fy + 2) { gold = max(gold, px.mean(CGRect(x: layer.x + layer.w / 2 - 20, y: CGFloat(y), width: 40, height: 1)).0) }
                #expect(gold > 0.45, "frame closed at the bottom (\(n))")
                // the table area is never empty (rows or filler rows down to the bottom)
                let low = px.mean(CGRect(x: layer.x + L.viewportRect.width * 0.3, y: L.viewportRect.maxY - L.rowH * 0.9, width: L.viewportRect.width * 0.4, height: L.rowH * 0.6))
                #expect(low.0 + low.1 + low.2 > 0.03, "bottom of the table is drawn (\(n))")
            }
            if L.overflow, let a = shots[0], let b = shots[8], let c = shots[25] {
                // header + frame stay put, the rows move
                // (the strip under the logo alternates handle / title on its own clock: compare the logo block and the table head)
                let logo = CGRect(x: layer.x + 10, y: 10, width: layer.w - 20, height: L.titleRect.minY - 14)
                let head = CGRect(x: layer.x + 10, y: L.headerRect.minY - 4, width: layer.w - 20, height: L.viewportRect.minY - L.headerRect.minY + 2)
                #expect(Self.diff(a, b, logo) < 0.002 && Self.diff(a, b, head) < 0.002 && Self.diff(a, c, head) < 0.002, "header fixed")
                let vp = CGRect(x: layer.x + 20, y: L.viewportRect.minY + 30, width: layer.w - 40, height: L.viewportRect.height - 60)
                #expect(Self.diff(a, b, vp) > 0.01, "rows scrolled")
                #expect(Self.diff(a, c, vp) > 0.01)
            }
        }
        // deterministic: the same time renders the same pixels
        let scene = Self.boardScene(Self.manual(40))
        let x = try #require(e.renderStill(scene, size: CGSize(width: 960, height: 540), variables: vars, time: 11.3))
        let y = try #require(e.renderStill(scene, size: CGSize(width: 960, height: 540), variables: vars, time: 11.3))
        #expect(Self.diff(Pixels(x), Pixels(y), CGRect(x: 0, y: 0, width: 960, height: 540)) == 0)
        // CPU preview path (editor / template thumbnails) at the reference size
        for n in [12, 22, 40] {
            if let img = TeamBoardArt.composite(Self.manual(n), vars: vars, w: 837, h: 1879, time: 9) { ShotsTests.writePNG(img, "\(dir)/board-\(n)-ref-size.png") }
        }
    }
    static func diff(_ a: Pixels, _ b: Pixels, _ r: CGRect) -> Double {
        var s = 0.0, n = 0.0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) {
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) { let p = a.rgb(x, y), q = b.rgb(x, y); s += abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2); n += 3 }
        }
        return n > 0 ? s / n : 0
    }

    /// GPU time the board adds to a frame (sprites warm): 40 teams scrolling vs. the same scene without the board.
    @Test func boardScrollGPUCost() throws {
        guard let c = MetalCompositor() else { return }
        c.layers.sprites.sync = true
        defer { c.layers.sprites.sync = false }
        func frame(_ s: LayerScene, _ t: Double) -> Double {
            var r = FrameRequest(); r.layerProgram = s; r.time = t; r.variables = SceneVariables(["matchTitle": "Grand Finals"])
            r.programClock = AnimClock(sinceShow: t, sinceTake: t, time: t)
            let out = c.makeOutputBuffer()!
            let sem = DispatchSemaphore(value: 0); var ms = 0.0
            _ = c.render(r, to: FrameTargets(output: out)) { g in ms = g; sem.signal() }
            sem.wait(); return ms
        }
        let board = Self.boardScene(Self.manual(40))
        var empty = board; empty.layers = []
        for t in [0.0, 5, 9] { _ = frame(board, t); _ = frame(empty, t) }
        var withB: [Double] = [], without: [Double] = []
        for i in 0..<90 {
            let t = 3 + Double(i) / 60 * 4
            withB.append(frame(board, t)); without.append(frame(empty, t))
        }
        withB.sort(); without.sort()
        let p50 = withB[45] - without[45]
        let line = String(format: "BOARD GPU 40 teams scrolling: p50 %.3f ms vs empty %.3f ms -> board adds %.3f ms (p90 %.3f vs %.3f)", withB[45], without[45], p50, withB[81], without[81])
        print(line)
        try? FileManager.default.createDirectory(atPath: "/tmp/board3-shots", withIntermediateDirectories: true)
        try? line.write(toFile: "/tmp/board3-shots/gpu.txt", atomically: true, encoding: .utf8)
        #expect(p50 < 0.5, "the board adds \(p50) ms of GPU per frame")
    }

    /// Dev: BOARD_RECORD=1 records ~30 s of the 40-team board scrolling through the real StudioEngine + OutputPipeline into
    /// /tmp/board3-shots/board-40-scroll.mp4.
    @Test func boardRecordScroll() async throws {
        guard ProcessInfo.processInfo.environment["BOARD_RECORD"] != nil else { return }
        guard let ff = FFmpegLocator.locate() else { Issue.record("no ffmpeg"); return }
        let url = URL(fileURLWithPath: "/tmp/board3-shots/board-40-scroll.mp4")
        try? FileManager.default.createDirectory(atPath: "/tmp/board3-shots", withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let out = OutputPipeline()
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = url
        try out.start(cfg)
        let engine = StudioEngine()
        engine.setSceneVariables(["matchTitle": "Grand Finals - Match 3"])
        #expect(engine.start(fps: 60, sink: out, provider: BoardNoSources()))
        engine.setProgram(Self.boardScene(Self.manual(40)), fade: false)
        try await Task.sleep(nanoseconds: 31_000_000_000)
        let st = engine.stats
        print(String(format: "BOARD RECORD fps %.1f missed %d gpuAvg %.2f ms gpuP99 %.2f ms frameP99 %.2f ms", st.fps, st.missedDeadlines, st.gpuAvgMs, st.gpuP99Ms, st.frameP99Ms))
        engine.stop()
        await out.stop()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class BoardNoSources: SourceProvider { func source(for ref: SourceRef) -> FrameSource? { nil } }
