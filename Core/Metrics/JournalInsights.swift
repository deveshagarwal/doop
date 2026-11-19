import Foundation

public struct FactorInsight: Codable, Sendable, Identifiable {
    public var id: String { factor.id + outcome }
    public let factor: JournalFactor
    public let outcome: String
    public let withMean: Double
    public let withoutMean: Double
    public let withCount: Int
    public let withoutCount: Int
    public let t: Double
    public var difference: Double { withMean - withoutMean }

    public enum Strength: String, Codable, Sendable { case solid, trend, none }

    /// "Solid" when the difference is more than twice its standard error, roughly p < 0.05.
    public var strength: Strength { abs(t) >= 2 ? .solid : (abs(t) >= 1 ? .trend : .none) }
}

/// Compares the morning after a logged behavior against mornings after days without it.
/// Requires at least 5 logged days on each side (WHOOP's monthly assessment uses the same floor).
/// Correlation, not proof: alcohol nights are also late nights.
public enum JournalInsights {
    public static let minimumEach = 5

    public static func compute(journal: [String: JournalEntry], factors: [JournalFactor],
                               outcomes: [String: (recovery: Double?, hrv: Double?, sleep: Double?)]) -> [FactorInsight] {
        var result: [FactorInsight] = []
        let loggedDays = journal.keys.sorted()

        for factor in factors {
            for (name, pick) in [("Recovery", { (o: (recovery: Double?, hrv: Double?, sleep: Double?)) in o.recovery }),
                                 ("HRV", { $0.hrv }),
                                 ("Sleep performance", { $0.sleep })] {
                var with: [Double] = [], without: [Double] = []
                for day in loggedDays {
                    guard let entry = journal[day], let o = outcomes[DayKey.addDays(day, 1)], let v = pick(o) else { continue }
                    if entry.factors.contains(factor.id) { with.append(v) } else { without.append(v) }
                }
                guard with.count >= minimumEach, without.count >= minimumEach, let t = Stats.welchT(with, without) else { continue }
                result.append(FactorInsight(factor: factor, outcome: name, withMean: Stats.mean(with),
                                            withoutMean: Stats.mean(without), withCount: with.count,
                                            withoutCount: without.count, t: t))
            }
        }
        return result.sorted { abs($0.t) > abs($1.t) }
    }
}
