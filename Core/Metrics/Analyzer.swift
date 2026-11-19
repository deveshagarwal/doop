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
}

public struct Analysis: Sendable {
    public let scores: [String: DayScore]
    public let orderedKeys: [String]
    public let insights: [FactorInsight]
    public let book: BaselineBook

    public static let empty = Analysis(scores: [:], orderedKeys: [], insights: [], book: BaselineBook(days: [:]))

    public var latestKey: String? { orderedKeys.last }
    public var latest: DayScore? { latestKey.flatMap { scores[$0] } }

    public func recent(_ n: Int) -> [DayScore] { orderedKeys.suffix(n).compactMap { scores[$0] } }
}

/// Runs every engine across the full history in date order, since sleep debt and
/// training load depend on the days before.
public enum Analyzer {
    public static func run(days: [String: DayRecord], journal: [String: JournalEntry],
                           factors: [JournalFactor], settings: UserSettings, today: String = DayKey.today()) -> Analysis {
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
                debt = SleepEngine.nextDebt(debt: debt, need: need, asleep: sleep.asleepMinutes)
                if let main = d.mainSleep { nights.append(main) }
            }

            let recovery = RecoveryEngine.score(day: d, book: book, sleepPerformance: sleep?.performance)
            let strain = strains[k] ?? .zero
            let rawIllness = IllnessDetector.evaluate(day: d, book: book, previousDay: days[DayKey.addDays(k, -1)],
                                                      loggedYesterday: journal[DayKey.addDays(k, -1)]?.factors ?? [])
            let illness = IllnessDetector.withPersistence(today: rawIllness, yesterday: previousIllness)
            previousIllness = days[k] == nil ? nil : rawIllness
            needTonight = SleepEngine.need(base: settings.baseSleepNeedHours, debtMinutes: debt, previousStrain: strain.strain)

            scores[k] = DayScore(
                date: k, recovery: recovery, strain: strain, workouts: workouts[k] ?? [],
                strainTarget: TrainingLoad.strainTarget(recovery: recovery?.score, load: loads[i]),
                sleep: sleep, sleepNeedTonight: needTonight,
                bedtimeTonight: SleepEngine.recommendedBedtime(needMinutes: needTonight, recentNights: nights, on: k),
                illness: illness,
                load: loads[i])
        }

        var outcomes: [String: (recovery: Double?, hrv: Double?, sleep: Double?)] = [:]
        for (k, s) in scores {
            outcomes[k] = (s.recovery.map { Double($0.score) }, days[k]?.hrvRmssd ?? days[k]?.hrvSdnn, s.sleep?.performance)
        }
        let insights = JournalInsights.compute(journal: journal, factors: factors, outcomes: outcomes)

        return Analysis(scores: scores, orderedKeys: keys, insights: insights, book: book)
    }
}
