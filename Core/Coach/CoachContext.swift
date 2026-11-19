import Foundation

/// Turns the analysis into a compact, plain-text briefing the coach reasons over.
/// Only derived numbers are sent: no raw heart-rate streams, no names.
public enum CoachContext {
    public static let systemPrompt = """
    You are the coach inside Baseline, a personal recovery app for one person who wears a Fitbit Air. \
    You see their nightly physiology, strain, sleep, training load, illness signals and habit journal, \
    all scored against their own baselines.

    How to coach:
    - Lead with the answer. Mornings are busy; two or three short paragraphs or a tight list is right.
    - Ground every claim in a specific number from the data, and compare to their own baseline rather than population norms.
    - Give one or two concrete actions for today (training intensity, bedtime, what to skip).
    - Say plainly when data is missing or a pattern is too weak to trust. Journal correlations are correlations.
    - You are not a doctor. If signals suggest illness, or they report symptoms like chest pain, fainting or \
    shortness of breath, say so directly and suggest seeing a clinician.
    - Plain prose, no headers, no emoji.

    Scales: recovery 1–99% (green ≥67, yellow 34–66, red <34). Strain 0–21, logarithmic (10 moderate, 14 hard, 18+ all-out). \
    Sleep performance = hours slept / hours needed. ACWR 0.8–1.3 is productive, >1.5 high risk.
    """

    public static func build(analysis: Analysis, days: [String: DayRecord], journal: [String: JournalEntry],
                             factors: [JournalFactor], settings: UserSettings, lookback: Int = 14) -> String {
        var lines: [String] = []
        lines.append("Today is \(DayKey.today()). Profile: age \(settings.age), sex \(settings.sex.rawValue), max HR \(Int(settings.maxHR)).")

        if let t = analysis.latest {
            lines.append("\nTODAY")
            if let r = t.recovery {
                lines.append("Recovery \(r.score)% (\(r.zone.rawValue))\(r.calibrating ? ", still calibrating" : "").")
                for c in r.contributors {
                    lines.append("  \(c.name): \(c.value)\(c.baseline.map { " vs baseline \($0)" } ?? "") → \(Int(c.score))/100, weight \(Int(c.weight * 100))%")
                }
                r.notes.forEach { lines.append("  Note: \($0)") }
            } else {
                lines.append("No recovery score yet today (no overnight data synced).")
            }
            lines.append(String(format: "Strain so far %.1f%@.", t.strain.strain, t.strainTarget.map { String(format: ", target %.1f", $0) } ?? ""))
            if let s = t.sleep {
                lines.append(String(format: "Last night: slept %@ of %@ needed (%.0f%%), efficiency %.0f%%, debt carried %@.",
                                    hm(s.asleepMinutes), hm(s.needMinutes), s.performance, s.efficiency ?? 0, hm(s.debtMinutes)))
                let stages = s.stagePercent.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \(Int($0.value))%" }
                if !stages.isEmpty { lines.append("  Stages: \(stages.joined(separator: ", "))") }
            }
            lines.append("Sleep need tonight \(hm(t.sleepNeedTonight))\(t.bedtimeTonight.map { ", recommended bedtime \(clock($0))" } ?? "").")
            lines.append("Illness check: \(t.illness.level.title). \(t.illness.message)")
            for d in t.illness.deviations { lines.append("  \(d.metric): \(d.detail)") }
            let l = t.load
            lines.append(String(format: "Training load: %@, acute %.0f, chronic %.0f, form %.0f%@.", l.status.rawValue, l.acute, l.chronic, l.form,
                                l.acwr.map { String(format: ", ACWR %.2f", $0) } ?? ""))
        }

        lines.append("\nLAST \(lookback) DAYS (date | recovery | HRV ms | RHR | resp | sleep h (perf) | strain | workouts | journal)")
        for s in analysis.recent(lookback) {
            let d = days[s.date]
            let factorsText = journal[s.date]?.factors.sorted().joined(separator: ",") ?? ""
            let workouts = s.workouts.map { "\($0.name) \(Int($0.durationMinutes))m" }.joined(separator: "+")
            lines.append([
                s.date,
                s.recovery.map { "\($0.score)%" } ?? "–",
                num(d?.hrvRmssd ?? d?.hrvSdnn),
                num(d?.restingHR),
                num(d?.respiratoryRate, 1),
                s.sleep.map { String(format: "%.1f (%.0f%%)", $0.asleepMinutes / 60, $0.performance) } ?? "–",
                String(format: "%.1f", s.strain.strain),
                workouts.isEmpty ? "–" : workouts,
                factorsText.isEmpty ? "–" : factorsText,
            ].joined(separator: " | "))
        }

        if let today = analysis.latestKey {
            let b = analysis.book
            lines.append("\n30-DAY BASELINES")
            for m in Metric.allCases {
                guard let base = b.baseline(before: today, m.value) else { continue }
                let isLog = m == .hrvRmssd || m == .hrvSdnn
                let mean = isLog ? exp(base.mean) : base.mean
                lines.append(String(format: "%@: %.1f %@ (n=%d)", m.label, mean, m.unit, base.count))
            }
        }

        let solid = analysis.insights.filter { $0.strength != .none }.prefix(8)
        if !solid.isEmpty {
            lines.append("\nJOURNAL PATTERNS (next-morning effect, with vs without)")
            for i in solid {
                lines.append(String(format: "%@ → %@ %+.1f (%.1f vs %.1f, n=%d/%d, %@)", i.factor.label, i.outcome, i.difference,
                                    i.withMean, i.withoutMean, i.withCount, i.withoutCount, i.strength.rawValue))
            }
        }
        if let note = journal[DayKey.today()]?.note, !note.isEmpty { lines.append("\nToday's journal note: \(note)") }
        return lines.joined(separator: "\n")
    }

    public static let morningBriefPrompt =
        "Give me my morning brief: how recovered I am and why, what kind of training today should be, and one thing to do tonight."

    static func hm(_ minutes: Double) -> String { "\(Int(minutes) / 60)h\(String(format: "%02d", Int(minutes) % 60))" }
    static func num(_ v: Double?, _ dec: Int = 0) -> String { v.map { String(format: "%.\(dec)f", $0) } ?? "–" }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
