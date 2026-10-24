// Live values for {{bindings}}: AirBattleground match (team names, title), the on-air timer and operator-edited fields.
import Foundation

extension SceneVariables {
    /// "ALPHA vs BRAVO" -> ("ALPHA", "BRAVO") for the usual separators.
    static func splitTeams(_ s: String) -> (String, String)? {
        for sep in [" vs. ", " vs ", " VS ", " v ", " \u{2013} ", " - ", " x "] {
            if let r = s.range(of: sep) {
                let a = s[s.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let b = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty { return (a, b) }
            }
        }
        return nil
    }
    /// matchTitle / team1 / team2 from the picked AirBattleground match (empty when none is picked).
    static func fromMatch(_ link: ShowLink?) -> [String: String] {
        guard let link else { return [:] }
        var v: [String: String] = [:]
        if let t = link.eventTitle { v["matchTitle"] = t }
        let sub = link.eventSubtitle ?? ""
        if let (a, b) = splitTeams(sub.isEmpty ? (link.eventTitle ?? "") : sub) { v["team1"] = a; v["team2"] = b }
        return v
    }
    /// "h:mm:ss" / "mm:ss" for the on-air timer.
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
