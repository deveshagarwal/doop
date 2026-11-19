import Foundation

/// A sustained shift in a metric, found with a one-sided CUSUM (Page 1954): small daily
/// deviations add up, single bad nights reset. Reports when the drift started.
public struct TrendChange: Sendable, Identifiable {
    public var id: String { metric }
    public let metric: String
    public let direction: Direction
    public let since: String
    public let days: Int
    public let percent: Double
    public let isGood: Bool

    public enum Direction: String, Sendable { case up, down }

    public var sentence: String {
        let dir = direction == .up ? "up" : "down"
        return "\(metric) has drifted \(dir) for \(days) days"
    }
}

public enum TrendDetector {
    /// `series` is (dayKey, value) in date order. Baseline = days 60…15 before the end.
    static func detect(_ series: [(String, Double)], name: String, higherIsBetter: Bool, minSD: Double) -> TrendChange? {
        guard series.count >= 30 else { return nil }
        let base = Array(series.dropLast(14).suffix(45)).map(\.1)
        guard let b = Stats.baseline(base), b.isReliable else { return nil }
        let sd = max(b.sd, minSD), k = 0.5, h = 4.0
        for dir in [TrendChange.Direction.down, .up] {
            var s = 0.0, start: Int?
            var alarmed = false
            for (i, (_, v)) in series.enumerated().suffix(21) {
                let z = (v - b.mean) / sd * (dir == .up ? 1 : -1)
                s = max(0, s + z - k)
                if s == 0 { start = nil; alarmed = false } else if start == nil { start = i }
                if s > h { alarmed = true }
            }
            guard alarmed, let st = start else { continue }
            let recent = series[st...].map(\.1)
            let pct = (Stats.mean(recent) - b.mean) / max(abs(b.mean), 1e-6) * 100
            return TrendChange(metric: name, direction: dir, since: series[st].0, days: series.count - st,
                               percent: pct, isGood: (dir == .up) == higherIsBetter)
        }
        return nil
    }

    public static func all(days: [String: DayRecord], keys: [String], sleepHours: [String: Double]) -> [TrendChange] {
        func series(_ f: (DayRecord) -> Double?) -> [(String, Double)] { keys.compactMap { k in days[k].flatMap(f).map { (k, $0) } } }
        var out: [TrendChange] = []
        if let c = detect(series { $0.hrvRmssd ?? $0.hrvSdnn }, name: "HRV", higherIsBetter: true, minSD: 3) { out.append(c) }
        if let c = detect(series(\.restingHR), name: "Resting HR", higherIsBetter: false, minSD: 1) { out.append(c) }
        if let c = detect(keys.compactMap { k in sleepHours[k].map { (k, $0) } }, name: "Sleep", higherIsBetter: true, minSD: 0.3) { out.append(c) }
        return out
    }
}

/// Daytime stress from heart rate the body can't explain by movement, and an energy bank that
/// starts at the morning's recovery and drains or refills through the day (similar in spirit to
/// Garmin Body Battery and Bevel's Energy Bank; the coefficients here are our own and transparent).
public struct StressEnergy: Sendable {
    /// 15-minute buckets from wake to now: average stress level 0–3.
    public let stressBuckets: [(Date, Double)]
    public let highStressMinutes: Double
    /// Energy every 10 minutes from wake to now, 0–100.
    public let energy: [(Date, Double)]
    public let projectedBedtimeEnergy: Double?
    public var current: Double? { energy.last?.1 }

    public static func compute(day: DayRecord, evening: DayRecord?, recovery: Int?, calmHR: Double?, restingHR: Double?, settings: UserSettings, now: Date = Date()) -> StressEnergy? {
        guard let recovery, let calm = calmHR else { return nil }
        let wake = day.mainSleep?.end ?? DayKey.date(from: day.date)!.addingTimeInterval(7 * 3600)
        let moving = Set((day.stepMinutes ?? []).filter { $0.v > 15 }.flatMap { m in (-2...2).map { Int(m.t.timeIntervalSince1970 / 60) + $0 } })
        let inWorkout: (Date) -> Bool = { t in day.workouts.contains { t >= $0.start && t <= $0.end } }
        let naps = day.sleepSessions.filter { !$0.isMainSleep }
        let samples = day.hrSamples.filter { $0.t >= wake && $0.t <= now }
        guard samples.count > 20 else { return nil }

        var e = Double(recovery), energy: [(Date, Double)] = [], buckets: [Date: [Double]] = [:]
        var high = 0.0, lastT = wake
        let rest = restingHR ?? calm - 15
        let reserve = max(settings.maxHR - rest, 40)
        for s in samples {
            let dt = min(s.t.timeIntervalSince(lastT) / 60, 5)
            lastT = s.t
            let minute = Int(s.t.timeIntervalSince1970 / 60)
            let napping = naps.contains { s.t >= $0.start && s.t <= $0.end }
            var level = 0.0
            if !moving.contains(minute), !inWorkout(s.t), !napping {
                level = Stats.clamp((s.bpm - calm - 6) / 9, 0, 3)
                if level >= 2 { high += dt }
            }
            buckets[Date(timeIntervalSince1970: floor(s.t.timeIntervalSince1970 / 900) * 900), default: []].append(level)

            var delta = -0.055 * dt
            if napping { delta = 0.18 * dt }
            else if inWorkout(s.t) || moving.contains(minute) {
                let hrr = Stats.clamp((s.bpm - rest) / reserve, 0, 1)
                delta -= hrr * hrr * 0.6 * dt
            } else if level >= 1 { delta -= 0.05 * level * dt }
            else if s.bpm < calm - 3 { delta += 0.03 * dt }
            e = Stats.clamp(e + delta, 0, 100)
            if energy.last.map({ s.t.timeIntervalSince($0.0) >= 600 }) ?? true { energy.append((s.t, e)) }
        }
        let bedtime = DayKey.date(from: day.date)!.addingTimeInterval(22.5 * 3600)
        let projected = now < bedtime ? max(0, e - 0.055 * bedtime.timeIntervalSince(now) / 60) : nil
        return StressEnergy(stressBuckets: buckets.map { ($0.key, Stats.mean($0.value)) }.sorted { $0.0 < $1.0 },
                            highStressMinutes: high, energy: energy, projectedBedtimeEnergy: projected)
    }

    /// Typical heart rate while awake, still and not exercising, over recent days.
    public static func calmHeartRate(days: [String: DayRecord], before key: String) -> Double? {
        var values: [Double] = []
        for i in 1...14 {
            guard let d = days[DayKey.addDays(key, -i)] else { continue }
            let moving = Set((d.stepMinutes ?? []).filter { $0.v > 15 }.map { Int($0.t.timeIntervalSince1970 / 60) })
            for s in d.hrSamples {
                guard !d.sleepSessions.contains(where: { s.t >= $0.start && s.t <= $0.end }),
                      !d.workouts.contains(where: { s.t >= $0.start && s.t <= $0.end }),
                      !moving.contains(Int(s.t.timeIntervalSince1970 / 60)) else { continue }
                values.append(s.bpm)
            }
        }
        return values.count > 200 ? Stats.percentile(values, 0.4) : nil
    }
}

/// Body age and pace of aging. A transparent heuristic, not a clinical test:
/// anchored on VO₂max → fitness age via the FRIEND registry's 50th percentiles (Kaminsky et al.
/// 2015, Mayo Clin Proc), with capped adjustments for resting HR (Zhang et al. 2016, CMAJ),
/// daily steps (Paluch et al. 2022, Lancet Public Health), sleep duration and sleep regularity
/// (Windred et al. 2024, Sleep).
public struct Healthspan: Sendable {
    public let bodyAge: Double
    public let chronologicalAge: Double
    /// Body-age years gained per calendar year over the last ~6 months (1.0 = average).
    public let pace: Double?
    public let contributors: [(name: String, years: Double)]
    public let vo2Estimated: Bool

    static let friend: [BiologicalSex: [(Double, Double)]] = [
        .male: [(25, 48.0), (35, 42.4), (45, 37.8), (55, 32.6), (65, 28.2), (75, 24.4)],
        .female: [(25, 37.6), (35, 30.9), (45, 27.9), (55, 24.2), (65, 21.0), (75, 18.3)],
        .unspecified: [(25, 42.8), (35, 36.7), (45, 32.9), (55, 28.4), (65, 24.6), (75, 21.4)],
    ]

    static func fitnessAge(vo2: Double, sex: BiologicalSex) -> Double {
        let t = friend[sex]!
        if vo2 >= t[0].1 { return max(18, t[0].0 - (vo2 - t[0].1) / (t[0].1 - t[1].1) * 10) }
        for i in 0..<(t.count - 1) where vo2 <= t[i].1 && vo2 >= t[i + 1].1 {
            let f = (t[i].1 - vo2) / (t[i].1 - t[i + 1].1)
            return t[i].0 + f * 10
        }
        return min(90, t.last!.0 + (t.last!.1 - vo2) / 3.8 * 10)
    }

    static func estimate(days: [DayRecord], settings: UserSettings, maxObservedHR: Double?) -> (Double, [(String, Double)], Bool)? {
        guard days.count >= 14 else { return nil }
        let age = Double(settings.age)
        let rhrs = days.compactMap(\.restingHR)
        guard let rhr = Stats.percentile(rhrs, 0.5) else { return nil }
        var estimated = false
        var vo2 = days.compactMap(\.vo2max).last
        if vo2 == nil {
            // Uth et al. 2004: VO₂max ≈ 15.3 × HRmax / HRrest
            vo2 = 15.3 * (maxObservedHR ?? settings.maxHR) / rhr
            estimated = true
        }
        let fit = fitnessAge(vo2: vo2!, sex: settings.sex)
        // Capped so a strong VO₂max can't run past the reference table's range.
        var parts: [(String, Double)] = [(String(format: "VO₂max %.0f", vo2!), Stats.clamp((fit - age) * 0.6, -5, 6))]
        if !estimated { parts.append((String(format: "Resting HR %.0f", rhr), Stats.clamp((rhr - 60) / 5, -2, 3))) }
        let steps = Stats.mean(days.compactMap(\.steps).map(Double.init))
        if steps > 0 {
            let y = steps < 5000 ? 2.0 : steps < 7500 ? 0.5 : steps < 10000 ? -0.5 : -1.0
            parts.append((String(format: "Steps %.1fk", steps / 1000), y))
        }
        let hours = days.map { $0.totalSleepMinutes / 60 }.filter { $0 > 3 }
        if !hours.isEmpty {
            let h = Stats.mean(hours)
            parts.append((String(format: "Sleep %.1fh", h), h < 6.5 ? 1.0 : h > 9 ? 0.5 : -0.3))
            let beds = days.compactMap { $0.mainSleep.map { AutoLog.hour($0.start) < 12 ? AutoLog.hour($0.start) + 24 : AutoLog.hour($0.start) } }
            if beds.count > 7 {
                let sd = Stats.sd(beds) * 60
                parts.append(("Sleep regularity", sd > 60 ? 1.0 : sd < 30 ? -0.5 : 0.2))
            }
        }
        return (age + parts.reduce(0) { $0 + $1.1 }, parts, estimated)
    }

    public static func compute(days: [String: DayRecord], keys: [String], settings: UserSettings) -> Healthspan? {
        let recent = keys.suffix(42).compactMap { days[$0] }
        let maxHR = keys.compactMap { days[$0]?.hrSamples.map(\.bpm).max() }.max()
        guard let (now, parts, est) = estimate(days: recent, settings: settings, maxObservedHR: maxHR) else { return nil }
        var pace: Double?
        if keys.count >= 120 {
            var points: [(Double, Double)] = []
            var i = keys.count
            while i - 42 >= 0 && points.count < 6 {
                let window = keys[(i - 42)..<i].compactMap { days[$0] }
                if let e = estimate(days: window, settings: settings, maxObservedHR: maxHR) { points.append((Double(i) / 365, e.0)) }
                i -= 30
            }
            if points.count >= 3 {
                let xs = points.map(\.0), ys = points.map(\.1)
                let mx = Stats.mean(xs), my = Stats.mean(ys)
                let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / max(xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }, 1e-9)
                pace = Stats.clamp(1 + slope, 0.3, 2)
            }
        }
        return Healthspan(bodyAge: now, chronologicalAge: Double(settings.age), pace: pace, contributors: parts, vo2Estimated: est)
    }
}

/// How many recovery points a workout of a given strain costs you the next morning.
public enum WorkoutCost {
    /// Slope of next-morning recovery change against the day's strain, from your history.
    public static func pointsPerStrain(days: [(strain: Double, recoveryChange: Double)]) -> Double? {
        let rows = days.filter { $0.strain > 0 }
        guard rows.count >= 20 else { return nil }
        let xs = rows.map(\.strain), ys = rows.map(\.recoveryChange)
        let mx = Stats.mean(xs), my = Stats.mean(ys)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
    }
}

/// Last full Monday–Sunday week in one card.
public struct WeeklyReport: Sendable {
    public let start: String
    public let end: String
    public let averageRecovery: Double
    public let change: Double?
    public let rankInQuarter: Int?
    public let daily: [(String, Int?)]
    public let best: (day: String, score: Int, why: String)?
    public let worst: (day: String, score: Int, why: String)?
    public let bedtimeSpreadMinutes: Double?
    public let strainTotal: Double
    public let strainChange: Double?
    public let tip: String?
}
