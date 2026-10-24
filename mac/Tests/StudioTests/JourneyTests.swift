import Testing
import Foundation
@testable import Studio

/// Match journey: auto-follow state machine, match data JSON -> {{MatchKeys}}, countdown.
struct JourneyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func journeyStageMapping() {
        #expect(JourneyStage.forMatchState("scheduled") == .startsIn && JourneyStage.forMatchState("finished") == .winner)
        #expect(JourneyStage.forControlState("locked") == .startsIn && JourneyStage.forControlState("ready") == .startsIn)
        #expect(JourneyStage.forControlState("live") == .gameplay && JourneyStage.forControlState("ended") == .summary)
        #expect(JourneyStage.forControlState("published") == .winner && JourneyStage.forControlState("weird") == nil)
    }

    @Test func journeyAutoFollowDebouncesAndFiresOnce() {
        var j = JourneyAutoFollow(enabled: true)
        do { let r = j.observe("scheduled", now: t0); #expect(r == nil) }
        do { let r = j.observe("scheduled", now: t0 + 1.9); #expect(r == nil) }
        do { let r = j.observe("scheduled", now: t0 + 2); #expect(r == .startsIn) }
        do { let r = j.observe("scheduled", now: t0 + 5); #expect(r == nil) }            // once per stable state
        // flapping live / summary / live inside 2 s: nothing until it settles
        do { let r = j.observe("live", now: t0 + 10); #expect(r == nil) }
        do { let r = j.observe("summary", now: t0 + 11); #expect(r == nil) }
        do { let r = j.observe("live", now: t0 + 11.5); #expect(r == nil) }
        do { let r = j.observe("live", now: t0 + 13); #expect(r == nil) }
        do { let r = j.observe("live", now: t0 + 13.5); #expect(r == .gameplay) }
        do { let r = j.observe(nil, now: t0 + 20); #expect(r == nil) }
        do { let r = j.observe("bogus", now: t0 + 30); #expect(r == nil) }
    }

    @Test func journeyManualOverridePausesUntilNextStateChange() {
        var j = JourneyAutoFollow(enabled: true)
        _ = j.observe("live", now: t0)
        do { let r = j.observe("live", now: t0 + 2); #expect(r == .gameplay) }
        j.manualOverride()
        #expect(j.paused)
        do { let r = j.observe("live", now: t0 + 60); #expect(r == nil) }
        do { let r = j.observe("summary", now: t0 + 61); #expect(r == nil) }
        #expect(!j.paused)    // state changed: resumes (after debounce)
        do { let r = j.observe("summary", now: t0 + 63); #expect(r == .summary) }
        // override with the same stage taken by hand: acknowledge, no pause, no second switch
        _ = j.observe("finished", now: t0 + 70)
        j.acknowledge(.winner)
        do { let r = j.observe("finished", now: t0 + 80); #expect(r == nil) }
        #expect(!j.paused)
        // disabled: never fires; enabling restarts the debounce for the current state
        var k = JourneyAutoFollow(enabled: false)
        _ = k.observe("live", now: t0)
        do { let r = k.observe("live", now: t0 + 10); #expect(r == nil) }
        k.setEnabled(true, now: t0 + 10)
        do { let r = k.observe("live", now: t0 + 11); #expect(r == nil) }
        do { let r = k.observe("live", now: t0 + 12); #expect(r == .gameplay) }
        k.manualOverride(); k.setEnabled(false, now: t0 + 13); k.setEnabled(true, now: t0 + 13)
        #expect(!k.paused)
    }

    static let liveJSON = """
    {"version": 7,
     "match": {"id": "m1", "title": "Grand Finals - Match 3", "map": "Erangel", "state": "summary",
               "startsAt": "2026-10-23T18:00:00Z", "round": "Grand Finals", "matchNumber": 3},
     "teams": [{"slot": 2, "name": "Bravo", "status": 0}, {"slot": 1, "name": "Alpha", "status": 3}, {"slot": 3, "name": "Charlie", "status": 1}],
     "summary": {"teams": [
         {"slot": 2, "name": "Bravo", "logo": "https://x/b.png", "kills": 5, "placement": 2, "placementPoints": 12, "killPoints": 5, "totalPoints": 17},
         {"slot": 1, "name": "Alpha", "logo": "https://x/a.png", "kills": 12, "placement": 1, "placementPoints": 15, "killPoints": 12, "totalPoints": 27},
         {"slot": 3, "name": "Charlie", "kills": 9, "placementPoints": 8}],
       "mvp": {"name": "MORTAL", "team": "Alpha", "kills": 9, "damage": 1284.4, "photo": "https://x/m.png"}},
     "winner": {"slot": 1, "name": "Alpha", "logo": "https://x/a.png", "kills": 12, "totalPoints": 27,
                "players": [{"name": "P1", "kills": 6, "damage": 800}, {"name": "P2", "kills": 4, "damage": 512}]}}
    """

    @Test func journeyMatchDataJSONToVariables() throws {
        let s = try MatchDataParser.parse(Data(Self.liveJSON.utf8))
        let now = try #require(MatchDataParser.date("2026-10-23T17:55:30Z"))
        let v = MatchDataParser.variables(s, now: now)
        #expect(v[MatchKeys.matchTitle] == "Grand Finals - Match 3" && v[MatchKeys.map] == "Erangel")
        #expect(v[MatchKeys.round] == "Grand Finals" && v[MatchKeys.matchNumber] == "3" && v[MatchKeys.matchState] == "summary")
        #expect(v[MatchKeys.startsAt] == "2026-10-23T18:00:00Z" && v[MatchKeys.countdown] == "04:30")
        #expect(v[MatchKeys.teamCount] == "3" && v[MatchKeys.aliveTeams] == "2")
        // standings sorted by total points (desc)
        #expect(v[MatchKeys.rankName(1)] == "Alpha" && v[MatchKeys.rankTotal(1)] == "27" && v[MatchKeys.rankLogo(1)] == "https://x/a.png")
        #expect(v[MatchKeys.rankName(2)] == "Charlie" && v[MatchKeys.rankTotal(2)] == "17" && v[MatchKeys.rankPlacePts(2)] == "8")   // 8 + 9 kills
        #expect(v[MatchKeys.rankName(3)] == "Bravo" && v[MatchKeys.rankKills(3)] == "5")
        #expect(v[MatchKeys.rankLogo(2)] == nil && v[MatchKeys.rankName(4)] == nil)
        #expect(v[MatchKeys.mvpName] == "MORTAL" && v[MatchKeys.mvpDamage] == "1,284" && v[MatchKeys.mvpPhoto] == "https://x/m.png")
        #expect(v[MatchKeys.winnerName] == "Alpha" && v[MatchKeys.winnerTotal] == "27" && v[MatchKeys.winnerKills] == "12")
        #expect(v[MatchKeys.winnerPlayer(1)] == "P1" && v[MatchKeys.winnerPlayerDamage(2)] == "512" && v[MatchKeys.winnerPlayer(3)] == nil)
        // same answer feeds the team board (ordered by slot)
        #expect(s.board?.teams.map(\.name) == ["Alpha", "Bravo", "Charlie"])
        #expect(s.stage == .summary)
    }

    @Test func journeyControlStateWinsAndUnlocksAtDrivesCountdown() throws {
        let json = #"{"match": {"state": "live", "startsAt": "2026-10-23T18:00:00Z"}, "control": {"state": "locked", "unlocksAt": "2026-10-23T17:50:00Z"}}"#
        let s = try MatchDataParser.parse(Data(json.utf8))
        #expect(s.stage == .startsIn)
        let now = try #require(MatchDataParser.date("2026-10-23T17:49:00Z"))
        let v = MatchDataParser.variables(s, now: now)
        #expect(v[MatchKeys.countdown] == "01:00" && v[MatchKeys.matchState] == "scheduled")
        // finished without `winner`: the top of the standings is the winner
        let f = try MatchDataParser.parse(Data(#"{"match":{"state":"finished"},"summary":{"teams":[{"name":"A","totalPoints":3},{"name":"B","totalPoints":9}]}}"#.utf8))
        #expect(MatchDataParser.variables(f, now: now)[MatchKeys.winnerName] == "B")
    }

    @Test func journeyMatchDataStoreKeepsLastDataAndSimulates() throws {
        let m = MatchDataStore()
        m.config = { nil }
        try m.ingest(Data(Self.liveJSON.utf8))
        #expect(m.state == "summary" && m.snapshot()?.teams.count == 3)
        #expect(throws: (any Error).self) { try m.ingest(Data("<html>".utf8)) }
        #expect(m.latest?.title == "Grand Finals - Match 3")           // errors keep the last data
        // an answer without `teams` keeps the board rows
        try m.ingest(Data(#"{"match": {"state": "finished"}}"#.utf8))
        #expect(m.state == "finished" && m.snapshot()?.teams.count == 3)
        m.setControl(state: "live", unlocksAt: nil)
        #expect(m.state == "live")
        m.setControl(state: nil, unlocksAt: nil)
        m.simulate("scheduled")
        #expect(m.state == "scheduled" && m.status.connection == .simulated)
        let v = m.variables()
        #expect(v[MatchKeys.rankName(1)] == MatchKeys.sample[MatchKeys.rankName(1)] && v[MatchKeys.matchState] == "scheduled")
        #expect(v[MatchKeys.countdown] == "05:00" || v[MatchKeys.countdown] == "04:59")
        m.simulate("finished"); #expect(m.variables()[MatchKeys.countdown] == "")
        m.simulate(nil); #expect(m.state == "finished")
    }

    @Test func journeyCountdownFormatting() {
        #expect(MatchDataParser.countdown(to: t0 + 299, now: t0) == "04:59")
        #expect(MatchDataParser.countdown(to: t0 + 0.2, now: t0) == "00:01")
        #expect(MatchDataParser.countdown(to: t0 + 3725, now: t0) == "62:05")
        #expect(MatchDataParser.countdown(to: t0, now: t0) == "")
        #expect(MatchDataParser.countdown(to: t0 - 10, now: t0) == "")
        #expect(MatchDataParser.countdown(to: nil, now: t0) == "")
        #expect(MatchDataParser.date(1_800_000_000_000) == t0 && MatchDataParser.date("2026-10-23T18:00:00.000Z") != nil)
    }
}

@Suite struct JourneyPreShowTests {
    @Test func preShowStageOrderAndState() {
        #expect(JourneyStage.allCases.first == .preShow)
        #expect(JourneyStage.forMatchState("preshow") == .preShow)
        #expect(JourneyStage.preShowLead == 900)
        // the control state never maps to pre-show directly: it is derived from the time to start
        #expect(JourneyStage.forControlState("locked") == .startsIn)
    }
    @Test func autoFollowMovesFromPreShowToStartsIn() {
        var j = JourneyAutoFollow(enabled: true, debounce: 2)
        let t0 = Date()
        _ = j.observe("preshow", now: t0)
        #expect(j.observe("preshow", now: t0.addingTimeInterval(2.1)) == .preShow)
        _ = j.observe("scheduled", now: t0.addingTimeInterval(10))
        #expect(j.observe("scheduled", now: t0.addingTimeInterval(12.1)) == .startsIn)
    }
}

@Suite struct JourneyPreparingTests {
    @Test func countdownOverShowsPreparing() {
        let now = Date()
        var v: [String: String] = [:]
        MatchDataParser.applyPreparing(&v, target: now.addingTimeInterval(-1), startsInStage: true, now: now)
        #expect(v[MatchKeys.preparing] == "PREPARING" && v[MatchKeys.countdown] == "" && v[MatchKeys.countdownGhost] == "" && v[MatchKeys.countdownLabel] == "LOBBY")
        MatchDataParser.applyPreparing(&v, target: now.addingTimeInterval(30), startsInStage: true, now: now)
        #expect(v[MatchKeys.preparing] == "" && v[MatchKeys.countdownGhost] == "00:00")
        // once the match is live it never says preparing
        MatchDataParser.applyPreparing(&v, target: now.addingTimeInterval(-1), startsInStage: false, now: now)
        #expect(v[MatchKeys.preparing] == "")
        #expect(JourneyStage.autoStartDelay == 72)
    }
}
