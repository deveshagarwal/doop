import Foundation

public struct DayScore: Sendable {
    public let date: String
    public let recovery: RecoveryResult?
    public let strain: StrainResult
    /// The day's workouts with per-workout strain filled in.
    public let workouts: [Workout]
    public let strainTarget: Double?
    public let sleep: SleepResult?
    /// Sleep need for the night AFTER this day (uses this day's strain and debt).
    public let sleepNeedTonight: Double
    public let bedtimeTonight: Date?
    public let illness: IllnessSignal
    public let load: LoadState
    /// Habits for this day: detected automatically, plus your answers.
    public let factors: Set<String>
}

/// One "For you" card. Every suggestion names the model behind it; no language model involved.
public struct Suggestion: Sendable, Identifiable {
    public var id: String { kind.rawValue + title }
    public enum Kind: String, Sendable { case illness, bedtime, habit, trend, load, debt, discovery }
    public let kind: Kind
    public let title: String
    public let why: String
    public let model: String
    /// Expected recovery points gained by acting on it.
    public let gain: Double
    /// 0–1, from how well the model has predicted your past.
    public let confidence: Double
    public var score: Double { gain * confidence }
}

/// Defaults the Tonight planner starts from.
public struct SleepHabits: Sendable {
    /// Hours after 18:00.
    public let typicalBedtime: Double
    /// Hours after 18:00 (so 6:30am = 12.5).
    public let typicalWake: Double
    public let efficiency: Double
    public let bedtimeSpreadMinutes: Double?
}

public struct Analysis: Sendable {
    public let scores: [String: DayScore]
    public let orderedKeys: [String]
    public let book: BaselineBook
    public let effects: [HabitEffect]
    public let forecast: RecoveryForecast?
    public let trends: [TrendChange]
    public let question: DailyQuestion?
    public let stressEnergy: StressEnergy?
    public let healthspan: Healthspan?
    public let costPerStrain: Double?
    public let weekly: WeeklyReport?
    public var suggestions: [Suggestion]
    public let habits: SleepHabits?
    public let computedAt: Date

    public static let empty = Analysis(scores: [:], orderedKeys: [], book: BaselineBook(days: [:]), effects: [], forecast: nil,
                                       trends: [], question: nil, stressEnergy: nil, healthspan: nil, costPerStrain: nil,
                                       weekly: nil, suggestions: [], habits: nil, computedAt: .distantPast)

    public var latestKey: String? { orderedKeys.last }
    public var latest: DayScore? { latestKey.flatMap { scores[$0] } }
    public func recent(_ n: Int) -> [DayScore] { orderedKeys.suffix(n).compactMap { scores[$0] } }

    /// Hours of sleep you'd get falling asleep at `bedtime` (hours after 18:00) before your usual wake.
    /// Capped at tonight's need plus 30 minutes: past that, extra time in bed isn't extra recovery.
    public func plannedSleepHours(bedtime: Double) -> Double? {
        guard let h = habits else { return nil }
        let cap = (latest?.sleepNeedTonight ?? 480) / 60 + 0.5
        return min(max(0, h.typicalWake - bedtime) * h.efficiency, cap)
    }

    /// Tomorrow's recovery if you fall asleep at `bedtime` with today's habits plus/minus some.
    public func forecastTomorrow(bedtime: Double, extra: Set<String> = [], removed: Set<String> = []) -> Double? {
        guard let f = forecast, let t = latest, let hours = plannedSleepHours(bedtime: bedtime) else { return nil }
        return f.predict(ForecastInput(sleepHours: hours, bedtimeClock: bedtime, strain: t.strain.strain,
                                       recovery: Double(t.recovery?.score ?? 60), factors: t.factors.union(extra).subtracting(removed)))
    }
}

/// Runs every engine across the full history in date order, since sleep debt and
/// training load depend on the days before.
public enum Analyzer {
    /// Hours after 18:00, so evening and early-morning times share one axis.
    public static func clock(_ d: Date) -> Double {
        let h = AutoLog.hour(d) - 18
        return h < 0 ? h + 24 : h
    }

    public static func run(days: [String: DayRecord], journal: [String: JournalEntry],
                           factors: [JournalFactor] = JournalFactor.all, settings: UserSettings,
                           today: String = DayKey.today(), now: Date = Date()) -> Analysis {
        guard let first = days.keys.min() else { return .empty }
        let keys = DayKey.keys(from: first, to: max(today, days.keys.max() ?? today))
        let book = BaselineBook(days: days)

        // Strain first: it feeds training load and next night's sleep need.
        var strains: [String: StrainResult] = [:]
        var workouts: [String: [Workout]] = [:]
        for k in keys {
            guard var d = days[k] else { strains[k] = .zero; continue }
            let rhr = d.restingHR ?? book.baseline(before: k, Metric.restingHR.value)?.mean
            for i in d.workouts.indices {
                d.workouts[i].strain = StrainEngine.workoutStrain(d.workouts[i], day: d, restingHR: rhr, settings: settings)
            }
            strains[k] = StrainEngine.compute(day: d, restingHR: rhr, settings: settings)
            workouts[k] = d.workouts
        }
        let loads = TrainingLoad.states(keys.map { strains[$0]?.trimp ?? 0 })

        // Habits: detected from data, then your answers on top.
        let calm = StressEnergy.calmHeartRate(days: days, before: today)
        var dayFactors: [String: Set<String>] = [:]
        for k in keys {
            guard let d = days[k], let midnight = DayKey.date(from: k) else { continue }
            var withStrain = d
            withStrain.workouts = workouts[k] ?? d.workouts
            let stress = StressEnergy.compute(day: d, evening: days[DayKey.addDays(k, -1)], recovery: 60, calmHR: calm,
                                              restingHR: d.restingHR, settings: settings, now: midnight.addingTimeInterval(24 * 3600))
            var f = AutoLog.factors(day: withStrain, previous: days[DayKey.addDays(k, -1)], nextMorning: days[DayKey.addDays(k, 1)],
                                    highStressMinutes: stress?.highStressMinutes)
            if let j = journal[k] {
                f.formUnion(j.factors)
                f.subtract(j.denied)
            }
            dayFactors[k] = f
        }

        var scores: [String: DayScore] = [:]
        var debt = 0.0
        var nights: [SleepSession] = []
        var needTonight = settings.baseSleepNeedHours * 60
        var previousIllness: IllnessSignal?

        for (i, k) in keys.enumerated() {
            let d = days[k] ?? DayRecord(date: k)
            let need = needTonight
            let sleep = SleepEngine.score(day: d, need: need, debt: debt, priorNights: Array(nights.suffix(4)))
            if let sleep {
                // Debt accrues against the base need only; counting the debt-inflated need would feed back on itself.
                let baseNeed = SleepEngine.need(base: settings.baseSleepNeedHours, debtMinutes: 0, previousStrain: strains[DayKey.addDays(k, -1)]?.strain)
                debt = SleepEngine.nextDebt(debt: debt, need: baseNeed, asleep: sleep.asleepMinutes)
                if let main = d.mainSleep { nights.append(main) }
            }
            let recovery = RecoveryEngine.score(day: d, book: book, sleepPerformance: sleep?.performance)
            let strain = strains[k] ?? .zero
            let raw = IllnessDetector.evaluate(day: d, book: book, previousDay: days[DayKey.addDays(k, -1)],
                                               loggedYesterday: dayFactors[DayKey.addDays(k, -1)] ?? [])
            let illness = IllnessDetector.withPersistence(today: raw, yesterday: previousIllness)
            previousIllness = days[k] == nil ? nil : raw
            needTonight = SleepEngine.need(base: settings.baseSleepNeedHours, debtMinutes: debt, previousStrain: strain.strain)

            scores[k] = DayScore(
                date: k, recovery: recovery, strain: strain, workouts: workouts[k] ?? [],
                strainTarget: TrainingLoad.strainTarget(recovery: recovery?.score, load: loads[i]),
                sleep: sleep, sleepNeedTonight: needTonight,
                bedtimeTonight: SleepEngine.recommendedBedtime(needMinutes: needTonight, recentNights: nights, on: k),
                illness: illness, load: loads[i], factors: dayFactors[k] ?? [])
        }

        // Rows linking each day to the next morning.
        var forecastRows: [RecoveryForecast.Row] = []
        var effectRows: [HabitEffects.Row] = []
        var costRows: [(strain: Double, recoveryChange: Double)] = []
        for (t, k) in keys.enumerated() where t + 1 < keys.count {
            let next = keys[t + 1]
            guard let s = scores[k], let n = scores[next], let date = DayKey.date(from: k) else { continue }
            let nightStart = days[next]?.mainSleep?.start
            let weekday = Calendar.current.component(.weekday, from: date)
            let nextHRV: Double? = days[next].flatMap { $0.hrvRmssd ?? $0.hrvSdnn }
            effectRows.append(HabitEffects.Row(factors: s.factors, strain: s.strain.strain, bedtimeClock: nightStart.map(clock),
                                               weekend: weekday == 6 || weekday == 7, recovery: n.recovery.map { Double($0.score) },
                                               hrv: nextHRV, sleep: n.sleep?.performance))
            guard let r0 = s.recovery, let r1 = n.recovery, let start = nightStart,
                  let asleep = days[next]?.totalSleepMinutes, asleep > 60 else { continue }
            let input = ForecastInput(sleepHours: asleep / 60, bedtimeClock: clock(start), strain: s.strain.strain,
                                      recovery: Double(r0.score), factors: s.factors)
            forecastRows.append(RecoveryForecast.Row(input: input, outcome: Double(r1.score)))
            costRows.append((s.strain.strain, Double(r1.score - r0.score)))
        }
        let forecast = RecoveryForecast.train(rows: forecastRows)
        let effects = HabitEffects.compute(rows: effectRows, factors: factors)

        let recentNights = Array(nights.suffix(21))
        var habits: SleepHabits?
        if recentNights.count >= 5 {
            let beds = recentNights.map { clock($0.start) }, wakes = recentNights.map { clock($0.end) }
            habits = SleepHabits(typicalBedtime: Stats.percentile(beds, 0.5) ?? 5, typicalWake: Stats.percentile(wakes, 0.5) ?? 12.5,
                                 efficiency: Stats.mean(recentNights.compactMap(\.efficiency)) / 100,
                                 bedtimeSpreadMinutes: Stats.sd(beds) * 60)
        }
        var sleepHours: [String: Double] = [:]
        for k in keys { if let h = days[k]?.totalSleepMinutes, h > 180 { sleepHours[k] = h / 60 } }
        let trends = TrendDetector.all(days: days, keys: keys, sleepHours: sleepHours)

        let morning = days[today] ?? days[keys.last!]
        var question: DailyQuestion?
        if let m = morning {
            question = AutoLog.question(morning: m, evening: days[DayKey.addDays(m.date, -1)], book: book, journal: journal,
                                        detected: dayFactors[DayKey.addDays(m.date, -1)] ?? [])
        }
        let latest = scores[keys.last!]
        var stress: StressEnergy?
        if let m = morning {
            stress = StressEnergy.compute(day: m, evening: days[DayKey.addDays(m.date, -1)], recovery: latest?.recovery?.score,
                                          calmHR: calm, restingHR: m.restingHR, settings: settings, now: now)
        }

        var analysis = Analysis(scores: scores, orderedKeys: keys, book: book, effects: effects, forecast: forecast, trends: trends,
                                question: question, stressEnergy: stress,
                                healthspan: Healthspan.compute(days: days, keys: keys, settings: settings),
                                costPerStrain: WorkoutCost.pointsPerStrain(days: costRows),
                                weekly: weeklyReport(keys: keys, scores: scores, days: days, effects: effects, today: today),
                                suggestions: [], habits: habits, computedAt: now)
        analysis.suggestions = Suggestions.rank(analysis)
        return analysis
    }

    static func weeklyReport(keys: [String], scores: [String: DayScore], days: [String: DayRecord],
                             effects: [HabitEffect], today: String) -> WeeklyReport? {
        guard let todayDate = DayKey.date(from: today) else { return nil }
        let weekday = Calendar.current.component(.weekday, from: todayDate) // 1 = Sunday
        let lastSunday = DayKey.addDays(today, weekday == 1 ? -7 : -(weekday - 1))
        let monday = DayKey.addDays(lastSunday, -6)
        let week = DayKey.keys(from: monday, to: lastSunday)
        let prev = week.map { DayKey.addDays($0, -7) }
        let recs = week.compactMap { scores[$0]?.recovery?.score }
        guard recs.count >= 4 else { return nil }
        let avg = Stats.mean(recs.map(Double.init))
        let prevRecs = prev.compactMap { scores[$0]?.recovery?.score }

        var weeklyAverages: [Double] = []
        for w in 0..<13 {
            let r = week.compactMap { scores[DayKey.addDays($0, -7 * w)]?.recovery?.score }
            if r.count >= 4 { weeklyAverages.append(Stats.mean(r.map(Double.init))) }
        }
        let rank = weeklyAverages.count >= 4 ? weeklyAverages.filter { $0 > avg + 0.01 }.count + 1 : nil

        func why(_ k: String) -> String {
            var parts: [String] = []
            let names = (scores[DayKey.addDays(k, -1)]?.factors ?? []).compactMap { JournalFactor.named($0)?.label.lowercased() }
            if !names.isEmpty { parts.append(names.prefix(2).joined(separator: ", ")) }
            if let d = days[k], let s = d.mainSleep {
                parts.append(String(format: "%.1fh sleep", d.totalSleepMinutes / 60))
                parts.append("bed " + s.start.formatted(date: .omitted, time: .shortened))
            }
            return parts.isEmpty ? "nothing notable logged" : parts.joined(separator: ", ")
        }
        let scored: [(String, Int)] = week.compactMap { k in scores[k]?.recovery.map { (k, $0.score) } }
        let best = scored.max { $0.1 < $1.1 }.map { (day: $0.0, score: $0.1, why: why($0.0)) }
        let worst = scored.min { $0.1 < $1.1 }.map { (day: $0.0, score: $0.1, why: why($0.0)) }
        let beds: [Double] = week.compactMap { k in days[k]?.mainSleep.map { clock($0.start) } }
        let strain = week.compactMap { scores[$0]?.strain.strain }.reduce(0, +)
        let prevStrain = prev.compactMap { scores[$0]?.strain.strain }.reduce(0, +)

        var tip: String?
        if let w = worst, let f = scores[DayKey.addDays(w.day, -1)]?.factors,
           let e = effects.filter({ $0.outcome == .recovery && $0.isSolid && $0.effect < 0 && f.contains($0.factor.id) }).min(by: { $0.effect < $1.effect }) {
            tip = String(format: "Watch the %@: it cost about %.0f points on %@.", e.factor.label.lowercased(), -e.effect, weekdayName(w.day))
        } else if beds.count > 3, Stats.sd(beds) * 60 > 45 {
            tip = "Steadier bedtimes would help most; they moved ±\(Int(Stats.sd(beds) * 60)) minutes."
        }
        return WeeklyReport(start: monday, end: lastSunday, averageRecovery: avg,
                            change: prevRecs.count >= 4 ? avg - Stats.mean(prevRecs.map(Double.init)) : nil,
                            rankInQuarter: rank, daily: week.map { ($0, scores[$0]?.recovery?.score) },
                            best: best, worst: worst, bedtimeSpreadMinutes: beds.count > 3 ? Stats.sd(beds) * 60 : nil,
                            strainTotal: strain, strainChange: prevStrain > 0 ? (strain - prevStrain) / prevStrain * 100 : nil, tip: tip)
    }

    public static func weekdayName(_ key: String) -> String {
        DayKey.date(from: key)?.formatted(.dateTime.weekday(.wide)) ?? key
    }
}

/// Ranks candidate suggestions by expected points gained × confidence. Sentences are templates.
public enum Suggestions {
    public static func rank(_ a: Analysis) -> [Suggestion] {
        guard let t = a.latest else { return [] }
        var out: [Suggestion] = []

        if t.illness.level == .alert {
            out.append(Suggestion(kind: .illness, title: "Take it easy: your vitals are off baseline", why: t.illness.message,
                                  model: "Illness watch", gain: 10, confidence: 0.8))
        }

        if let f = a.forecast, f.isUseful, let h = a.habits, let typical = a.forecastTomorrow(bedtime: h.typicalBedtime) {
            let options: [(Double, Double)] = stride(from: max(3.5, h.typicalBedtime - 1.0), through: h.typicalBedtime + 1, by: 1.0 / 6).compactMap { b in
                a.forecastTomorrow(bedtime: b).map { (b, $0) }
            }
            if let best = options.max(by: { $0.1 < $1.1 }) {
                // The latest bedtime that gets nearly all of the benefit is the easiest to keep.
                let earliestGood = options.last { $0.1 >= best.1 - 1 } ?? best
                let gain = earliestGood.1 - typical
                if gain >= 2 {
                    out.append(Suggestion(kind: .bedtime, title: "Bed by \(clockLabel(earliestGood.0)) → about +\(Int(gain.rounded())) tomorrow",
                                          why: "Your forecast peaks with lights out around \(clockLabel(earliestGood.0)); you usually sleep at \(clockLabel(h.typicalBedtime)).",
                                          model: "Forecast model", gain: gain, confidence: Stats.clamp(f.beatsNaiveBy * 2, 0.3, 0.9)))
                }
            }
        }

        if let s = t.sleep, s.debtMinutes > 90 {
            out.append(Suggestion(kind: .debt, title: "Bank sleep tonight: \(Int(s.debtMinutes / 60))h \(Int(s.debtMinutes) % 60)m of debt",
                                  why: "Recent short nights raise tonight's need to \(Int(t.sleepNeedTonight / 60))h \(Int(t.sleepNeedTonight) % 60)m.",
                                  model: "Sleep need model", gain: 3, confidence: 0.6))
        }

        let recentDays = a.orderedKeys.suffix(14).compactMap { a.scores[$0] }
        for e in a.effects where e.outcome == .recovery && e.isSolid && e.effect <= -3 {
            let times = recentDays.filter { $0.factors.contains(e.factor.id) }.count
            guard times >= 2 else { continue }
            out.append(Suggestion(kind: .habit, title: "\(e.factor.label) costs you about \(Int((-e.effect).rounded())) points",
                                  why: "Across \(e.withCount) days with it vs \(e.withoutCount) without, holding other habits steady. It happened \(times)× in the last two weeks.",
                                  model: "Habit model", gain: -e.effect * min(Double(times) / 7, 1), confidence: e.confidence))
        }
        for e in a.effects where e.outcome == .recovery && e.isSolid && e.effect >= 3 {
            out.append(Suggestion(kind: .discovery, title: "\(e.factor.label) is worth about +\(Int(e.effect.rounded()))",
                                  why: "Found automatically in \(e.withCount) days from \(e.factor.source).",
                                  model: "Natural experiment", gain: e.effect * 0.5, confidence: e.confidence))
        }
        for c in a.trends where !c.isGood {
            out.append(Suggestion(kind: .trend, title: c.sentence,
                                  why: String(format: "%+.0f%% vs your normal, since %@.", c.percent, Analyzer.weekdayName(c.since)),
                                  model: "Trend change detector", gain: 4, confidence: 0.6))
        }
        if let r = t.load.acwr, r > 1.3 {
            out.append(Suggestion(kind: .load, title: "Keep the next session easy",
                                  why: String(format: "Your load ratio is %.2f; past 1.5 is where injury and illness risk climbs.", r),
                                  model: "Load model", gain: 3, confidence: 0.55))
        }
        return out.sorted { $0.score > $1.score }
    }

    public static func clockLabel(_ hoursAfter18: Double) -> String {
        let m = Int(((hoursAfter18 + 18) * 60).rounded()) % 1440
        let h = m / 60, mm = m % 60
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", mm))\(h >= 12 ? "pm" : "am")"
    }
}
