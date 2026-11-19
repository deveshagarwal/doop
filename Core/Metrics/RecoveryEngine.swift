import Foundation

public struct Contributor: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String
    public let baseline: String?
    /// 0–100 sub-score.
    public let score: Double
    public let weight: Double
    public let z: Double?
}

public struct RecoveryResult: Codable, Sendable {
    public let score: Int
    public let contributors: [Contributor]
    public let calibrating: Bool
    public let usedHRV: Bool
    public let notes: [String]

    public var zone: Zone { Zone(score: score) }

    public enum Zone: String, Codable, Sendable {
        case green, yellow, red
        public init(score: Int) {
            self = score >= 67 ? .green : (score >= 34 ? .yellow : .red)
        }
    }
}

/// Recovery (1–99%) from overnight physiology, each signal scored against your own 30-day baseline.
///
/// Weights follow the literature emphasis on HRV as the primary readiness marker
/// (Plews 2013, Sports Med; Buchheit 2014, Front Physiol), with resting HR, sleep
/// and respiratory rate as supporting signals. A z of 0 (a normal day) lands ~60%.
public enum RecoveryEngine {
    static func curve(_ z: Double) -> Double { 100 * Stats.logistic(0.4 + 1.1 * z) }

    public static func score(day: DayRecord, book: BaselineBook, sleepPerformance: Double?) -> RecoveryResult? {
        var parts: [(Contributor, Bool)] = []
        var notes: [String] = []
        var calibrating = false

        // HRV: prefer Google's RMSSD; fall back to SDNN only against an SDNN baseline.
        var usedHRV = false
        for metric in [Metric.hrvRmssd, .hrvSdnn] {
            guard let v = metric.value(day), let b = book.baseline(before: day.date, metric.value) else { continue }
            let z = b.z(v, minSD: metric.minSD)
            if !b.isReliable { calibrating = true }
            parts.append((Contributor(name: "HRV", value: fmt(metric.display(day), "ms"),
                                      baseline: fmt(exp(b.mean), "ms"), score: curve(z), weight: 0.45, z: z), true))
            usedHRV = true
            break
        }

        if let v = day.restingHR, let b = book.baseline(before: day.date, Metric.restingHR.value) {
            let z = b.z(v, minSD: Metric.restingHR.minSD)
            if !b.isReliable { calibrating = true }
            parts.append((Contributor(name: "Resting HR", value: fmt(v, "bpm"), baseline: fmt(b.mean, "bpm"),
                                      score: curve(-z), weight: 0.25, z: z), true))
        }

        if let perf = sleepPerformance {
            parts.append((Contributor(name: "Sleep", value: "\(Int(perf.rounded()))%", baseline: nil,
                                      score: perf, weight: 0.20, z: nil), true))
        }

        // Respiratory rate only penalizes when elevated; a low rate is not "extra recovered".
        if let v = day.respiratoryRate, let b = book.baseline(before: day.date, Metric.respiratoryRate.value) {
            let z = b.z(v, minSD: Metric.respiratoryRate.minSD)
            parts.append((Contributor(name: "Respiratory rate", value: fmt(v, "rpm", 1), baseline: fmt(b.mean, "rpm", 1),
                                      score: 100 * Stats.logistic(0.4 - 1.5 * max(0, z - 0.5)), weight: 0.10, z: z), true))
        }

        guard !parts.isEmpty, day.restingHR != nil || usedHRV else { return nil }

        // Re-weight whatever is present. Without HRV, resting HR and sleep carry it.
        var weights = parts.map { $0.0.weight }
        if !usedHRV {
            weights = parts.map { p in
                switch p.0.name {
                case "Resting HR": return 0.45
                case "Sleep": return 0.40
                default: return 0.15
                }
            }
            notes.append("No HRV for this night. Connect Google Health in Settings to add it.")
        }
        let total = weights.reduce(0, +)
        var score = zip(parts, weights).reduce(0) { $0 + $1.0.0.score * $1.1 } / total

        if let spo2Min = day.spo2Min, spo2Min < 90 {
            score -= 5
            notes.append("Blood oxygen dipped to \(Int(spo2Min))% overnight.")
        }
        if let t = day.skinTemp, let b = book.baseline(before: day.date, Metric.skinTemp.value),
           b.z(t, minSD: Metric.skinTemp.minSD) > 2 {
            score -= 5
            notes.append("Skin temperature is well above your baseline.")
        }

        let contributors = zip(parts, weights).map { p, w in
            Contributor(name: p.0.name, value: p.0.value, baseline: p.0.baseline, score: p.0.score, weight: w / total, z: p.0.z)
        }
        return RecoveryResult(score: Int(Stats.clamp(score, 1, 99).rounded()), contributors: contributors,
                              calibrating: calibrating, usedHRV: usedHRV, notes: notes)
    }

    static func fmt(_ v: Double?, _ unit: String, _ decimals: Int = 0) -> String {
        guard let v else { return "–" }
        return String(format: "%.\(decimals)f %@", v, unit)
    }
}
