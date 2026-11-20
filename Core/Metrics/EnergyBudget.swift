import Foundation

/// Daily calorie and macro targets for a weight goal, learned from your own intake and weight trend.
///
/// Burn starts from Mifflin-St Jeor (Mifflin et al. 1990, Am J Clin Nutr) plus the band's measured active energy
/// and ~10% for digesting food. Once there are enough logged days, it shifts to the energy-balance estimate:
/// burn = average intake − (change in trend weight × 7,700 kcal/kg) / days (Hall 2008, Int J Obes), the method
/// adaptive trackers like MacroFactor use. Trend weight is an exponentially smoothed weigh-in series.
public struct EnergyBudget: Sendable {
    public enum BurnBasis: Sendable, Equatable {
        /// Formula plus band activity; nothing learned yet.
        case estimated
        /// Blending in your intake-vs-weight data.
        case learning(loggedDays: Int)
        /// Mostly your own data.
        case learned
    }

    public let trendWeightKg: Double?
    /// Slope of trend weight over the last four weeks, kg per week.
    public let weeklyRateKg: Double?
    public let burnKcal: Double
    public let basis: BurnBasis
    public let targetKcal: Double?
    /// True when the goal pace would put the target under a safe floor, so the floor is used instead.
    public let targetFloored: Bool
    public let proteinG: Double
    public let carbG: Double
    public let fatG: Double
    public let fiberG: Double
    /// Days in the last four weeks with at least 800 kcal logged.
    public let loggedDays: Int

    static let kcalPerKg = 7700.0
    static let trendDays = 10.0

    /// `days` should be merged days (Apple Health + DOOP's own meals).
    public static func compute(days: [String: DayRecord], settings: UserSettings, today: String = DayKey.today()) -> EnergyBudget? {
        let keys = days.keys.sorted().filter { $0 <= today }
        let weighIns: [(String, Double)] = keys.compactMap { k in days[k]?.weightKg.map { (k, $0) } }
        guard let latestWeight = weighIns.last?.1 else { return nil }

        // Trend weight per weigh-in day, smoothing with a 10-day time constant that respects gaps.
        var trend: [(String, Double)] = []
        for (k, w) in weighIns {
            guard let prev = trend.last else { trend.append((k, w)); continue }
            let gap = Double(DayKey.daysBetween(prev.0, k))
            let a = 1 - exp(-max(gap, 1) / trendDays)
            trend.append((k, prev.1 + a * (w - prev.1)))
        }
        let trendNow = trend.last?.1 ?? latestWeight

        let bmr = mifflin(weight: trendNow, settings: settings)
        let recent = keys.suffix(14).compactMap { days[$0]?.activeEnergy }.filter { $0 > 0 }
        let prior = recent.count >= 5 ? (bmr + Stats.mean(recent)) * 1.1 : bmr * 1.45

        // Energy balance over the last 28 days of logging.
        let window = Array(keys.suffix(28))
        let logged = window.filter { (days[$0]?.kcalTotal ?? 0) >= 800 }
        var burn = prior, basis = BurnBasis.estimated
        let inWindow = trend.filter { $0.0 >= (window.first ?? today) }
        if logged.count >= 7, let first = inWindow.first, let last = inWindow.last, DayKey.daysBetween(first.0, last.0) >= 10 {
            let span = Double(DayKey.daysBetween(first.0, last.0))
            let intake = Stats.mean(logged.compactMap { days[$0]?.kcalTotal })
            let observed = Stats.clamp(intake - (last.1 - first.1) * kcalPerKg / span, bmr * 1.1, bmr * 2.5)
            let w = min(Double(logged.count) / 21, 1) * 0.85
            burn = w * observed + (1 - w) * prior
            basis = logged.count >= 21 ? .learned : .learning(loggedDays: logged.count)
        }

        var target: Double?, floored = false
        if let rate = settings.goalRateKgPerWeek {
            let floor: Double = settings.sex == .female ? 1200 : 1500
            let raw = burn + rate * kcalPerKg / 7
            floored = raw < floor
            target = max(raw, floor)
        }
        let kcal = target ?? burn
        let protein = Stats.clamp(1.8 * trendNow, 90, 220)
        let fat = kcal * 0.27 / 9
        let carb = max(kcal - protein * 4 - fat * 9, 0) / 4

        return EnergyBudget(trendWeightKg: trendNow, weeklyRateKg: weeklySlope(trend), burnKcal: burn, basis: basis,
                            targetKcal: target, targetFloored: floored, proteinG: protein, carbG: carb, fatG: fat,
                            fiberG: kcal / 1000 * 14, loggedDays: logged.count)
    }

    /// Mifflin-St Jeor resting energy. Height defaults to a population average when Health doesn't have it.
    static func mifflin(weight: Double, settings: UserSettings) -> Double {
        let h = settings.heightCm ?? (settings.sex == .female ? 162 : 176)
        let base = 10 * weight + 6.25 * h - 5 * Double(settings.age)
        switch settings.sex {
        case .male: return base + 5
        case .female: return base - 161
        case .unspecified: return base - 78
        }
    }

    static func weeklySlope(_ trend: [(String, Double)]) -> Double? {
        guard let last = trend.last else { return nil }
        let recent = trend.filter { DayKey.daysBetween($0.0, last.0) <= 28 }
        guard recent.count >= 4 else { return nil }
        let xs = recent.map { Double(DayKey.daysBetween(last.0, $0.0)) / 7 }, ys = recent.map(\.1)
        let mx = Stats.mean(xs), my = Stats.mean(ys)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
    }

    /// Date the trend reaches `goal` at the goal pace, or nil if it's the wrong direction.
    public func projectedDate(goal: Double, rate: Double, from: Date = Date()) -> Date? {
        guard let w = trendWeightKg, rate != 0, (goal - w) / rate > 0 else { return nil }
        return from.addingTimeInterval((goal - w) / rate * 7 * 86400)
    }
}
