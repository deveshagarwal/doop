import Foundation

/// Apple Health metrics that can act as habits in "What moves you": a day counts when it lands in your own
/// top third for that metric, so "long walking day" means long for you, in whatever units your phone uses.
public enum ExtraHabits {
    struct Def { let key: String; let label: String; let symbol: String }

    static let defs: [Def] = [
        .init(key: "HKQuantityTypeIdentifierDistanceWalkingRunning", label: "Long walking day", symbol: "figure.walk"),
        .init(key: "HKQuantityTypeIdentifierFlightsClimbed", label: "Lots of stairs", symbol: "stairs"),
        .init(key: "HKQuantityTypeIdentifierTimeInDaylight", label: "Lots of daylight", symbol: "sun.max"),
        .init(key: "HKQuantityTypeIdentifierHeadphoneAudioExposure", label: "Loud headphones", symbol: "headphones"),
        .init(key: "HKQuantityTypeIdentifierDietaryWater", label: "Well hydrated", symbol: "drop"),
        .init(key: "HKQuantityTypeIdentifierAppleExerciseTime", label: "Lots of exercise minutes", symbol: "flame"),
    ]

    static let prefix = "x:"

    public static func factor(_ id: String) -> JournalFactor? {
        guard id.hasPrefix(prefix), let d = defs.first(where: { prefix + $0.key == id }) else { return nil }
        return JournalFactor(id: id, label: d.label, symbol: d.symbol, source: "Apple Health")
    }

    /// Top-third threshold per metric, for metrics with at least two weeks of data.
    public static func thresholds(days: [String: DayRecord]) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in defs {
            let v = days.values.compactMap { $0.extras?[d.key] }.filter { $0 > 0 }
            if v.count >= 14, let p = Stats.percentile(v, 0.67) { out[d.key] = p }
        }
        return out
    }

    public static func detect(_ day: DayRecord, thresholds: [String: Double]) -> Set<String> {
        Set(thresholds.compactMap { key, t in (day.extras?[key] ?? 0) >= t && t > 0 ? prefix + key : nil })
    }

    public static func factors(thresholds: [String: Double]) -> [JournalFactor] {
        thresholds.keys.sorted().compactMap { factor(prefix + $0) }
    }
}

/// A change in how you walk, which often shows up before a strain or tweak hurts.
public struct GaitAlert: Sendable {
    public let metric: String
    public let recent: Double
    public let baseline: Double
    /// Percentage points above normal.
    public let rise: Double
    public let since: String
}

/// Watches iPhone gait metrics (walking asymmetry and double-support time) against your 30-day normal.
/// A sustained rise in asymmetry is a validated marker of altered gait after injury (Apple Mobility white paper,
/// 2022; Moon et al. 2021, Gait & Posture). Needs three recent days above normal, so one odd day is ignored.
public enum GaitWatch {
    public static func check(days: [String: DayRecord], keys: [String]) -> GaitAlert? {
        let metrics: [(String, (DayRecord) -> Double?, Double)] = [
            ("Walking asymmetry", { $0.walkingAsymmetryPct }, 3),
            ("Both feet on the ground", { $0.doubleSupportPct }, 2),
        ]
        for (name, f, minRise) in metrics {
            let recentKeys = Array(keys.suffix(3))
            let recent = recentKeys.compactMap { days[$0].flatMap(f) }
            let base = keys.dropLast(3).suffix(30).compactMap { days[$0].flatMap(f) }
            guard recent.count == 3, base.count >= 10 else { continue }
            let mean = Stats.mean(base), sd = max(Stats.sd(base), 0.5)
            let threshold = mean + max(2 * sd, minRise)
            if recent.allSatisfy({ $0 >= threshold }) {
                return GaitAlert(metric: name, recent: Stats.mean(recent), baseline: mean, rise: Stats.mean(recent) - mean,
                                 since: recentKeys.first ?? "")
            }
        }
        return nil
    }
}
