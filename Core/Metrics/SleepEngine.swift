import Foundation

public struct SleepResult: Codable, Sendable {
    public let needMinutes: Double
    public let asleepMinutes: Double
    /// Hours slept vs hours needed, 0–100.
    public let performance: Double
    public let efficiency: Double?
    /// 0–100; how closely bed and wake times match the prior four nights.
    public let consistency: Double?
    /// Debt carried INTO tonight, in minutes.
    public let debtMinutes: Double
    public let stagePercent: [SleepStage: Double]
    public let bedtime: Date?
    public let wake: Date?
}

/// Sleep need, debt and performance, in the spirit of WHOOP's sleep coach.
///
/// Need = base need + part of accumulated debt + extra after a strenuous day
/// (higher training load raises sleep need: Kölling et al. 2016, Sports Med).
/// Debt decays 30% per day so it reflects the past week, not the past year.
/// Consistency uses mean absolute deviation of bed/wake times, a simple stand-in for the
/// Sleep Regularity Index (Phillips et al. 2017, Sci Rep).
public enum SleepEngine {
    public static func need(base: Double, debtMinutes: Double, previousStrain: Double?) -> Double {
        let strainBonus = max(0, (previousStrain ?? 0) - 10) * 4 // up to ~44 min after strain 21
        return base * 60 + 0.25 * debtMinutes + strainBonus
    }

    public static func nextDebt(debt: Double, need: Double, asleep: Double) -> Double {
        Stats.clamp(debt * 0.7 + (need - asleep), 0, 600)
    }

    public static func score(day: DayRecord, need: Double, debt: Double, priorNights: [SleepSession]) -> SleepResult? {
        guard let main = day.mainSleep, day.totalSleepMinutes > 60 else { return nil }
        let asleep = day.totalSleepMinutes
        let perf = Stats.clamp(asleep / max(need, 1) * 100, 0, 100)

        var stages: [SleepStage: Double] = [:]
        let staged = main.stages.filter { $0.stage != .unknown }
        let total = staged.reduce(0) { $0 + $1.minutes }
        if total > 0 {
            for s in staged { stages[s.stage, default: 0] += s.minutes / total * 100 }
        }

        var consistency: Double?
        if priorNights.count >= 2 {
            let bedDev = priorNights.map { abs(minuteOfDay($0.start, pivot: 18) - minuteOfDay(main.start, pivot: 18)) }
            let wakeDev = priorNights.map { abs(minuteOfDay($0.end, pivot: 0) - minuteOfDay(main.end, pivot: 0)) }
            let mad = (Stats.mean(bedDev) + Stats.mean(wakeDev)) / 2
            consistency = Stats.clamp(100 - mad / 1.5, 0, 100)
        }

        return SleepResult(needMinutes: need, asleepMinutes: asleep, performance: perf, efficiency: main.efficiency,
                           consistency: consistency, debtMinutes: debt, stagePercent: stages,
                           bedtime: main.start, wake: main.end)
    }

    /// Minutes since `pivot` o'clock, so 23:30 and 00:30 are 60 minutes apart, not 23 hours.
    static func minuteOfDay(_ d: Date, pivot: Int) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        let shifted = m - Double(pivot * 60)
        return shifted < 0 ? shifted + 1440 : shifted
    }

    /// Bedtime that meets tonight's need, given your habitual wake time and efficiency.
    public static func recommendedBedtime(needMinutes: Double, recentNights: [SleepSession], on day: String) -> Date? {
        let wakes = recentNights.suffix(7).map { minuteOfDay($0.end, pivot: 0) }
        guard let wake = Stats.percentile(wakes, 0.5), let midnight = DayKey.date(from: DayKey.addDays(day, 1)) else { return nil }
        let eff = Stats.mean(recentNights.suffix(7).compactMap(\.efficiency)) / 100
        let inBed = needMinutes / (eff > 0.5 ? eff : 0.9)
        return midnight.addingTimeInterval((wake - inBed) * 60)
    }
}
