import Foundation

public struct LoadState: Codable, Sendable {
    /// Acute load (fatigue): 7-day EWMA of daily TRIMP.
    public let acute: Double
    /// Chronic load (fitness): 42-day EWMA of daily TRIMP.
    public let chronic: Double
    /// Form = chronic − acute. Negative means you're carrying fatigue.
    public var form: Double { chronic - acute }
    /// Acute:chronic workload ratio, 7-day mean over 28-day mean.
    public let acwr: Double?
    public let status: Status

    public enum Status: String, Codable, Sendable {
        case building = "Not enough history"
        case detraining = "Detraining"
        case maintaining = "Maintaining"
        case productive = "Productive"
        case overreaching = "Overreaching"
        case highRisk = "High injury risk"

        public var advice: String {
            switch self {
            case .building: return "Needs about 3 weeks of heart-rate data from the band, including the last few days. Steps alone can't tell training from a quiet week."
            case .detraining: return "Your recent load is well below what you're used to. Fitness will slowly drift down."
            case .maintaining: return "Load is steady. Add a harder session if you want to build."
            case .productive: return "You're in the productive range: building load at a sustainable rate."
            case .overreaching: return "Load jumped faster than your base. Fine for a short block; plan an easier day soon."
            case .highRisk: return "Load spiked far above your chronic base. This is where injury and illness risk climbs. Back off."
            }
        }
    }
}

/// Banister fitness-fatigue model (Banister 1975; Busso 2003) with the acute:chronic
/// workload ratio (Gabbett 2016, Br J Sports Med: 0.8–1.3 "sweet spot", >1.5 danger zone).
public enum TrainingLoad {
    /// `series` is daily TRIMP in chronological order, missing days as 0. `measured` marks days whose load came from
    /// heart rate rather than a step-count estimate; a status needs 14 measured days in the last 28 and 3 in the last 7,
    /// so a stretch without the band never reads as detraining.
    public static func states(_ series: [Double], measured: [Bool]? = nil) -> [LoadState] {
        let measured = measured ?? Array(repeating: true, count: series.count)
        let acute = Stats.ewma(series, days: 7)
        let chronic = Stats.ewma(series, days: 42)
        return series.indices.map { i in
            var acwr: Double?
            let enough = measured[max(0, i - 27)...i].filter { $0 }.count >= 14 && measured[max(0, i - 6)...i].filter { $0 }.count >= 3
            if i >= 20, enough {
                let last7 = Stats.mean(Array(series[max(0, i - 6)...i]))
                let last28 = Stats.mean(Array(series[max(0, i - 27)...i]))
                acwr = last28 > 1 ? last7 / last28 : nil
            }
            let status: LoadState.Status
            switch acwr {
            case nil: status = .building
            case let r? where r < 0.8: status = .detraining
            case let r? where r < 1.0: status = .maintaining
            case let r? where r <= 1.3: status = .productive
            case let r? where r <= 1.5: status = .overreaching
            default: status = .highRisk
            }
            return LoadState(acute: acute[i], chronic: chronic[i], acwr: acwr, status: status)
        }
    }

    /// Today's strain target: recovery sets the ceiling, load status trims it.
    public static func strainTarget(recovery: Int?, load: LoadState?) -> Double? {
        guard let recovery else { return nil }
        var target = Stats.clamp(4 + 0.15 * Double(recovery), 5, 19)
        switch load?.status {
        case .highRisk: target -= 3
        case .overreaching: target -= 1.5
        case .detraining: target += 1
        default: break
        }
        return Stats.clamp(target, 4, 19)
    }
}
