import Foundation

// Shared contract for studio presets and the match journey. Two modules build on it:
//  - presets + journey UI + server data feed (Core/, UI/, Integrations/)
//  - the "OPUS Advanced Studio" preset art and scenes (Props/AdvancedStudio/, new engine effects)
// Change only additively.

/// The stages of a match on stream, in order. A preset maps each stage to one of its scenes.
enum JourneyStage: String, Codable, CaseIterable, Identifiable {
    case preShow        // before the countdown: a looping branded scene (stinger) until `preShowLead` before the start
    case startsIn       // "Match starts in" countdown before the match
    case gameplay       // the live match (phones / spectator feed + team status board)
    case summary        // results after the match: standings, MVP
    case winner         // the winning team showcase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preShow: "Pre-show"
        case .startsIn: "Match starts in"
        case .gameplay: "Gameplay"
        case .summary: "Match summary"
        case .winner: "Winner"
        }
    }
    /// Server `match.state` that moves the journey to this stage when auto-follow is on.
    var matchState: String {
        switch self {
        case .preShow: "preshow"
        case .startsIn: "scheduled"
        case .gameplay: "live"
        case .summary: "summary"
        case .winner: "finished"
        }
    }
    static func forMatchState(_ s: String) -> JourneyStage? { allCases.first { $0.matchState == s } }
    /// Pre-show runs until this long before the start, then the journey moves to "Match starts in".
    static let preShowLead: TimeInterval = 15 * 60
    /// The studio presses Start by itself this long after the start time when the match is still `ready` (auto-start on).
    static let autoStartDelay: TimeInterval = 72
    /// additive: auto-start is tried again this often while the match is still `ready` (AirBattleground refuses Start
    /// until the lobby has been read from the auto-capture frames).
    static let autoStartRetry: TimeInterval = 15
    /// additive: auto capture (start-with-match) begins this long after the match start time and runs until every
    /// result is in (AirBattleground answers 409 CAPTURE_DONE) or the operator stops it.
    static let captureDelay: TimeInterval = 30
    /// The pre-show scene is re-played (its one-shot animations re-taken) this often while on Program.
    static let preShowRepeat: TimeInterval = 3.2
    /// additive: AirBattleground match `control.state` (preferred over `match.state` when present):
    /// locked | ready -> startsIn, live -> gameplay, ended -> summary, published -> winner.
    static func forControlState(_ s: String) -> JourneyStage? {
        switch s.lowercased().trimmingCharacters(in: .whitespaces) {
        case "locked", "ready": .startsIn
        case "live": .gameplay
        case "ended": .summary
        case "published": .winner
        default: nil
        }
    }
}

/// Scene variable keys filled from the server's match data (GET /api/studio-link/matches/{id}/live) so any text
/// layer can use them as {{key}}. Scenes must use these names; the feed fills them.
enum MatchKeys {
    // match header
    static let matchTitle = "matchTitle"          // "Grand Finals - Match 3"
    static let map = "map"                        // "Erangel"
    static let matchNumber = "matchNumber"        // "3"
    static let round = "round"                    // "Grand Finals"
    static let startsAt = "startsAt"              // ISO time the match starts
    /// additive: the start time in the studio's local time zone, "SAT 24 OCT · 7:30 PM" (YouTube thumbnail)
    static let startsAtLocal = "startsAtLocal"
    /// additive: "GRAND FINALS · MATCH 3 · ERANGEL" ({{round}} · MATCH {{matchNumber}} · {{map}}, missing parts left out)
    static let matchLine = "matchLine"
    static let countdown = "countdown"            // "04:59", ticking, derived from startsAt (empty when past)
    /// "PREPARING" once the countdown has run out but the match has not started yet (lobby being prepared), else "".
    static let preparing = "preparing"
    /// Faint "00:00" behind the countdown digits; "" while preparing.
    static let countdownGhost = "countdownGhost"
    /// "MIN  :  SEC" under the dial, "LOBBY" while preparing.
    static let countdownLabel = "countdownLabel"
    /// additive: "PROCESSING RESULTS" once the match has ended while AirBattleground is still reading the results
    /// screens (the journey stays on gameplay until every team has its rank), else "".
    static let processing = "processing"
    static let teamCount = "teamCount"            // "16"
    static let aliveTeams = "aliveTeams"          // "9" teams with status > 0
    static let elapsed = "elapsed"                // "12:34" match time since the match went live (empty before)
    static let matchState = "matchState"          // additive: "scheduled" | "live" | "summary" | "finished" (server match.state)
    // summary (state summary / finished): top N standings of this match, N = 1...16
    static func rankName(_ n: Int) -> String { "rank\(n)Name" }
    static func rankLogo(_ n: Int) -> String { "rank\(n)Logo" }      // https URL
    static func rankKills(_ n: Int) -> String { "rank\(n)Kills" }
    static func rankPlacePts(_ n: Int) -> String { "rank\(n)PlacePts" }
    static func rankTotal(_ n: Int) -> String { "rank\(n)Total" }
    // MVP of the match
    static let mvpName = "mvpName", mvpTeam = "mvpTeam", mvpKills = "mvpKills", mvpDamage = "mvpDamage", mvpPhoto = "mvpPhoto"
    // winner showcase
    static let winnerName = "winnerName", winnerLogo = "winnerLogo", winnerKills = "winnerKills", winnerTotal = "winnerTotal"
    static func winnerPlayer(_ n: Int) -> String { "winnerPlayer\(n)" }          // n = 1...4
    static func winnerPlayerKills(_ n: Int) -> String { "winnerPlayer\(n)Kills" }
    static func winnerPlayerDamage(_ n: Int) -> String { "winnerPlayer\(n)Damage" }

    /// Sample values for previews, editor canvases and tests.
    static var sample: [String: String] {
        var v: [String: String] = [matchTitle: "GRAND FINALS - MATCH 3", map: "ERANGEL", matchNumber: "3", round: "GRAND FINALS",
                                   countdown: "04:59", countdownGhost: "00:00", countdownLabel: "MIN  :  SEC", teamCount: "16", aliveTeams: "9", elapsed: "12:34",
                                   mvpName: "MORTAL", mvpTeam: "SOUL", mvpKills: "9", mvpDamage: "1,284",
                                   winnerName: "TEAM SOUL", winnerKills: "18", winnerTotal: "33",
                                   startsAtLocal: "SAT 24 OCT · 7:30 PM", matchLine: "GRAND FINALS · MATCH 3 · ERANGEL"]
        let teams = ["SOUL", "GODLIKE", "TEAM XSPARK", "REVENANT", "ORANGUTAN", "BLIND", "8BIT", "MEDAL",
                     "GLOBAL ESPORTS", "ENTITY", "TEAM INSANE", "CHEMIN", "NEON", "SKYLIGHTZ", "RIVALRY", "TRUE RIPPERS"]
        for (i, t) in teams.enumerated() {
            let n = i + 1
            v[rankName(n)] = t; v[rankKills(n)] = "\(max(0, 18 - n))"
            let place = [15, 12, 10, 8, 6, 4, 2, 1, 1][min(i, 8)]
            v[rankPlacePts(n)] = "\(n <= 9 ? place : 0)"; v[rankTotal(n)] = "\(max(0, 18 - n) + (n <= 9 ? place : 0))"
        }
        for (i, p) in ["MORTAL", "REGALTOS", "VIPER", "OWAIS"].enumerated() {
            v[winnerPlayer(i + 1)] = p; v[winnerPlayerKills(i + 1)] = "\([9, 5, 3, 1][i])"; v[winnerPlayerDamage(i + 1)] = "\([1284, 760, 512, 240][i])"
        }
        return v
    }
}

extension MatchKeys {
    /// "SAT 24 OCT · 7:30 PM" in `tz` (English, so the thumbnail reads the same on every Mac).
    static func localStart(_ d: Date, timeZone tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "EEE d MMM"
        let day = f.string(from: d).uppercased()
        f.dateFormat = "h:mm a"
        return "\(day) · \(f.string(from: d))"
    }
    /// {{round}} · MATCH {{matchNumber}} · {{map}} with the missing parts left out ("" when none).
    static func line(round: String?, matchNumber: String?, map: String?) -> String {
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        return [clean(round), clean(matchNumber).map { "MATCH \($0)" }, clean(map)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Names of the two built-in presets.
enum PresetNames {
    static let opusDefault = "OPUS Studio Default"
    static let opusAdvanced = "OPUS Advanced Studio"
}
