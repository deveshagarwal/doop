import Foundation

public struct StrainResult: Codable, Sendable {
    /// WHOOP-style 0–21 scale.
    public let strain: Double
    /// Banister TRIMP for the day; feeds the training-load model.
    public let trimp: Double
    /// Minutes per heart-rate-reserve zone (see `StrainEngine.zoneBounds`).
    public let zoneMinutes: [Double]
    public let peakHR: Double?
    public let estimated: Bool

    public static let zero = StrainResult(strain: 0, trimp: 0, zoneMinutes: Array(repeating: 0, count: 5), peakHR: nil, estimated: true)
}

/// Cardiovascular strain from minute-level heart rate.
///
/// Each minute contributes Banister's TRIMP (Banister 1991; Morton, Fitz-Clarke & Banister 1990):
/// `HRR × 0.64 × e^(k × HRR)`, k = 1.92 (male) / 1.67 (female), HRR from Karvonen.
/// Minutes under 30% HRR are ignored so a day of sitting doesn't accumulate load.
/// TRIMP maps to 0–21 with `21 × (1 − e^(−TRIMP/110))`: the top of the scale gets
/// progressively harder to reach, as on WHOOP. Calibration: ~1h easy ≈ 5, 1h steady
/// run ≈ 13, 90 min hard ≈ 18.
public enum StrainEngine {
    public static let zoneBounds: [Double] = [0.30, 0.50, 0.60, 0.70, 0.80]
    public static let zoneLabels = ["Very light", "Light", "Moderate", "Hard", "Max"]
    public static let tau = 110.0

    public static func strain(fromTRIMP t: Double) -> Double { t > 0 ? 21 * (1 - exp(-t / tau)) : 0 }

    static func k(for sex: BiologicalSex) -> Double {
        switch sex {
        case .male: return 1.92
        case .female: return 1.67
        case .unspecified: return 1.8
        }
    }

    static func minuteTRIMP(hrr: Double, sex: BiologicalSex) -> Double {
        hrr * 0.64 * exp(k(for: sex) * hrr)
    }

    public static func compute(day: DayRecord, restingHR: Double?, settings: UserSettings) -> StrainResult {
        let rest = restingHR ?? 60
        let reserve = max(settings.maxHR - rest, 40)

        guard day.hrSamples.count >= 60 else { return estimate(day: day, rest: rest, reserve: reserve, settings: settings) }

        var trimp = 0.0
        var zones = Array(repeating: 0.0, count: zoneBounds.count)
        for s in day.hrSamples {
            let hrr = Stats.clamp((s.bpm - rest) / reserve, 0, 1.1)
            guard hrr >= zoneBounds[0] else { continue }
            trimp += minuteTRIMP(hrr: hrr, sex: settings.sex)
            if let z = zoneBounds.lastIndex(where: { hrr >= $0 }) { zones[z] += 1 }
        }
        return StrainResult(strain: strain(fromTRIMP: trimp), trimp: trimp, zoneMinutes: zones,
                            peakHR: day.hrSamples.map(\.bpm).max(), estimated: false)
    }

    /// Without intraday HR: workouts at their average HR plus a small credit for steps.
    static func estimate(day: DayRecord, rest: Double, reserve: Double, settings: UserSettings) -> StrainResult {
        var trimp = 0.0
        for w in day.workouts {
            let hrr = Stats.clamp(((w.averageHR ?? (rest + 0.55 * reserve)) - rest) / reserve, 0, 1)
            trimp += w.durationMinutes * minuteTRIMP(hrr: hrr, sex: settings.sex)
        }
        trimp += Double(day.steps ?? 0) / 1000 * 1.5
        return StrainResult(strain: strain(fromTRIMP: trimp), trimp: trimp,
                            zoneMinutes: Array(repeating: 0, count: zoneBounds.count), peakHR: nil, estimated: true)
    }

    /// Strain for one workout window, computed from the day's minute HR.
    public static func workoutStrain(_ w: Workout, day: DayRecord, restingHR: Double?, settings: UserSettings) -> Double? {
        let rest = restingHR ?? 60
        let reserve = max(settings.maxHR - rest, 40)
        let samples = day.hrSamples.filter { $0.t >= w.start && $0.t <= w.end }
        guard samples.count >= 5 else { return nil }
        let t = samples.reduce(0) { acc, s in
            let hrr = Stats.clamp((s.bpm - rest) / reserve, 0, 1.1)
            return acc + (hrr >= zoneBounds[0] ? minuteTRIMP(hrr: hrr, sex: settings.sex) : 0)
        }
        return strain(fromTRIMP: t)
    }
}
