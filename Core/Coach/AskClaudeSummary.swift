import Foundation

/// Turns the analysis into a compact, plain-text briefing the coach reasons over.
/// Only derived numbers are sent: no raw heart-rate streams, no names.
/// Builds the text the "Ask Claude" button hands to your own Claude app (on your subscription).
/// Only derived numbers: no raw heart-rate streams, no names.
public enum AskClaudeSummary {
    public static func build(analysis: Analysis, days: [String: DayRecord], settings: UserSettings, lookback: Int = 14) -> String {
        var lines: [String] = []
        lines.append("I use a personal recovery app with my Fitbit Air. Here is my data. Scores compare me with my own last 30 days. Please help me understand it and plan today.")
        lines.append("Profile: age \(settings.age), sex \(settings.sex.rawValue). Recovery is 1–99% (67+ primed, 34–66 steady, <34 run down). Strain is 0–21, logarithmic.")
        if let t = analysis.latest {
            lines.append("\nTODAY \(t.date)")
            if let r = t.recovery {
                lines.append("Recovery \(r.score)%.")
                for c in r.contributors { lines.append("  \(c.name): \(c.value)\(c.baseline.map { " (normal \($0))" } ?? "")") }
            }
            lines.append(String(format: "Strain %.1f, target %.1f. Load: %@%@.", t.strain.strain, t.strainTarget ?? 0, t.load.status.rawValue,
                                t.load.acwr.map { String(format: ", ratio %.2f", $0) } ?? ""))
            if let s = t.sleep {
                lines.append(String(format: "Slept %.1fh of %.1fh needed; debt %.0f min.", s.asleepMinutes / 60, s.needMinutes / 60, s.debtMinutes))
            }
            lines.append("Illness watch: \(t.illness.level.title). \(t.illness.message)")
        }
        if let f = analysis.forecast {
            lines.append(String(format: "My on-device forecast for tomorrow has ±%.0f points of error.", f.backtestError))
        }
        lines.append("\nLAST \(lookback) DAYS (date | recovery | HRV | resting HR | sleep h | strain | habits)")
        for s in analysis.recent(lookback) {
            let d = days[s.date]
            let rec: String = s.recovery.map { "\($0.score)%" } ?? "–"
            let hrvValue: Double? = d?.hrvRmssd ?? d?.hrvSdnn
            let hrv: String = hrvValue.map { String(format: "%.0f", $0) } ?? "–"
            let rhr: String = d?.restingHR.map { String(format: "%.0f", $0) } ?? "–"
            let sleep = String(format: "%.1f", (d?.totalSleepMinutes ?? 0) / 60)
            let strain = String(format: "%.1f", s.strain.strain)
            let parts: [String] = [s.date, rec, hrv, rhr, sleep, strain, s.factors.sorted().joined(separator: ",")]
            lines.append(parts.joined(separator: " | "))
        }
        let solid = analysis.effects.filter { $0.outcome == .recovery && $0.isSolid }
        if !solid.isEmpty {
            lines.append("\nHABIT EFFECTS ON NEXT-MORNING RECOVERY")
            for e in solid { lines.append(String(format: "%@: %+.1f (±%.1f)", e.factor.label, e.effect, e.ci)) }
        }
        return lines.joined(separator: "\n")
    }
}
