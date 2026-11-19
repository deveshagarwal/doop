import Foundation

public struct IllnessSignal: Codable, Sendable {
    public enum Level: Int, Codable, Sendable, Comparable {
        case clear = 0, watch = 1, alert = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .clear: return "All clear"
            case .watch: return "Worth watching"
            case .alert: return "Your body may be fighting something"
            }
        }
    }

    public struct Deviation: Codable, Sendable, Identifiable {
        public var id: String { metric }
        public let metric: String
        /// Signed so that positive always means "in the worrying direction".
        public let z: Double
        public let detail: String
    }

    public let level: Level
    public let score: Double
    public let deviations: [Deviation]
    public let message: String
}

/// Early-warning from overnight vitals drifting together.
///
/// Wearable studies found resting HR rises, HRV falls, respiratory rate and skin
/// temperature rise in the days before and around symptom onset of respiratory infections:
/// Mishra et al. 2020 (Nat Biomed Eng), Radin et al. 2020 (Lancet Digit Health),
/// Natarajan et al. 2020 (npj Digit Med). No single signal is diagnostic, so this
/// requires several to agree, scored against a baseline that skips the last 2 days.
public enum IllnessDetector {
    static let threshold = 1.5

    /// Resting HR and HRV both read the autonomic nervous system, so they count as ONE
    /// signal group. Alcohol, a hard session or a late meal moves that group alone; an
    /// infection typically also moves respiratory rate or skin temperature. A full alert
    /// therefore needs one of those more specific markers to agree.
    enum Group: String { case autonomic, respiratory, temperature, oxygen }

    public static func evaluate(day: DayRecord, book: BaselineBook, previousDay: DayRecord?,
                                loggedYesterday: Set<String> = []) -> IllnessSignal {
        var devs: [IllnessSignal.Deviation] = []
        var groups: [Group: Double] = [:]

        func check(_ metric: Metric, direction: Double, _ d: DayRecord) -> Double? {
            guard let v = metric.value(d), let b = book.baseline(before: day.date, gap: 2, metric.value), b.isReliable else { return nil }
            return direction * b.z(v, minSD: metric.minSD)
        }

        let checks: [(Metric, Double, String, Group)] = [
            (.restingHR, 1, "above", .autonomic), (.hrvRmssd, -1, "below", .autonomic), (.hrvSdnn, -1, "below", .autonomic),
            (.respiratoryRate, 1, "above", .respiratory), (.skinTemp, 1, "above", .temperature), (.spo2, -1, "below", .oxygen),
        ]
        var sawHRV = false
        for (metric, dir, word, group) in checks {
            if metric == .hrvSdnn && sawHRV { continue }
            guard let z = check(metric, direction: dir, day) else { continue }
            if metric == .hrvRmssd { sawHRV = true }
            if z >= threshold {
                devs.append(.init(metric: metric.label, z: z, detail: String(format: "%.1f SD %@ your baseline", z, word)))
                groups[group] = max(groups[group] ?? 0, min(z, 4))
            }
        }

        let score = groups.values.reduce(0, +)
        let specific = groups[.respiratory] != nil || groups[.temperature] != nil
        let rhrPersistent: Bool = {
            guard let prev = previousDay, let zToday = check(.restingHR, direction: 1, day),
                  let zPrev = check(.restingHR, direction: 1, prev) else { return false }
            return zToday >= 1 && zPrev >= 1
        }()

        let level: IllnessSignal.Level
        if (specific && groups.count >= 2) || groups.count >= 3 {
            level = .alert
        } else if groups.count == 2 || groups.values.contains(where: { $0 >= 2.5 }) || rhrPersistent {
            level = .watch
        } else {
            level = .clear
        }

        let names = devs.map(\.metric).joined(separator: ", ")
        let explained = loggedYesterday.contains("alcohol") ? " You logged alcohol yesterday, which commonly does exactly this." : ""
        let message: String
        switch level {
        case .clear: message = "Overnight vitals are within your normal range."
        case .watch: message = (names.isEmpty
            ? "Resting HR has been elevated two nights running. Keep an eye on how you feel."
            : "\(names) out of range. Could be stress, alcohol, travel, a hard session or a late meal. Watch for a second night.") + explained
        case .alert: message = "\(names) are all off your baseline at once. This pattern often shows up early in an illness. Prioritize sleep, hydration and an easy day."
        }
        return IllnessSignal(level: level, score: score, deviations: devs, message: message)
    }

    /// Real wrist data is noisy (LifeSnaps, 71 Fitbit users: night-to-night skin temp SD ≈0.5 °C,
    /// breathing ≈1 rpm), so two signals line up by chance on ~3% of nights. Illness persists;
    /// noise doesn't. A full alert therefore needs the previous night to have been off too.
    public static func withPersistence(today: IllnessSignal, yesterday: IllnessSignal?) -> IllnessSignal {
        guard today.level == .alert, (yesterday?.level ?? .clear) == .clear else { return today }
        let names = today.deviations.map(\.metric).joined(separator: ", ")
        return IllnessSignal(level: .watch, score: today.score, deviations: today.deviations,
                             message: "\(names) all moved off your baseline last night. One night can be noise; if it repeats tonight this becomes an alert.")
    }
}
