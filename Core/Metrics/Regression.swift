import Foundation

/// Ridge regression on standardized features, small enough to retrain on the phone every night.
public struct RidgeModel: Sendable {
    public let names: [String]
    let means: [Double]
    let sds: [Double]
    let beta: [Double]
    let intercept: Double
    /// Standard errors of the coefficients, in original units.
    public let standardErrors: [Double]
    public let residualSD: Double
    public let n: Int

    /// Coefficients in original units (change in y per unit of each feature).
    public var coefficients: [Double] { zip(beta, sds).map { $0 / $1 } }

    public func predict(_ x: [Double]) -> Double {
        intercept + zip(zip(x, means), zip(beta, sds)).reduce(0) { acc, p in acc + (p.0.0 - p.0.1) / p.1.1 * p.1.0 }
    }

    public static func fit(_ rows: [[Double]], _ y: [Double], names: [String], lambda: Double = 2) -> RidgeModel? {
        let n = rows.count, p = names.count
        guard n > p + 2, p > 0 else { return nil }
        let means = (0..<p).map { j in Stats.mean(rows.map { $0[j] }) }
        let sds = (0..<p).map { j in max(Stats.sd(rows.map { $0[j] }), 1e-6) }
        let z = rows.map { r in (0..<p).map { (r[$0] - means[$0]) / sds[$0] } }
        let ym = Stats.mean(y)

        var a = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        var b = Array(repeating: 0.0, count: p)
        for (r, yi) in zip(z, y) {
            for i in 0..<p {
                b[i] += r[i] * (yi - ym)
                for j in 0..<p { a[i][j] += r[i] * r[j] }
            }
        }
        for i in 0..<p { a[i][i] += lambda }
        guard let inv = invert(a) else { return nil }
        let beta = (0..<p).map { i in (0..<p).reduce(0) { $0 + inv[i][$1] * b[$1] } }

        let resid = zip(z, y).map { r, yi in yi - ym - (0..<p).reduce(0) { $0 + r[$1] * beta[$1] } }
        let sigma2 = resid.reduce(0) { $0 + $1 * $1 } / Double(max(n - p - 1, 1))
        let se = (0..<p).map { sqrt(max(sigma2 * inv[$0][$0], 0)) / sds[$0] }
        return RidgeModel(names: names, means: means, sds: sds, beta: beta, intercept: ym,
                          standardErrors: se, residualSD: sqrt(sigma2), n: n)
    }

    /// Gauss-Jordan inversion with partial pivoting.
    static func invert(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        var a = m, inv = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for c in 0..<n {
            guard let piv = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 else { return nil }
            a.swapAt(c, piv); inv.swapAt(c, piv)
            let d = a[c][c]
            for j in 0..<n { a[c][j] /= d; inv[c][j] /= d }
            for r in 0..<n where r != c {
                let f = a[r][c]
                guard f != 0 else { continue }
                for j in 0..<n { a[r][j] -= f * a[c][j]; inv[r][j] -= f * inv[c][j] }
            }
        }
        return inv
    }
}

/// Inputs to the tomorrow forecast: what you plan tonight plus how today went.
public struct ForecastInput: Sendable {
    public var sleepHours: Double
    /// Hours after 18:00 that you fall asleep (22:30 = 4.5).
    public var bedtimeClock: Double
    public var strain: Double
    public var recovery: Double
    public var factors: Set<String>

    public init(sleepHours: Double, bedtimeClock: Double, strain: Double, recovery: Double, factors: Set<String>) {
        self.sleepHours = sleepHours
        self.bedtimeClock = bedtimeClock
        self.strain = strain
        self.recovery = recovery
        self.factors = factors
    }
}

/// Predicts tomorrow's recovery from tonight's plan, trained only on your own nights.
/// Backtested by walking forward through your history (train on the past, predict the next day),
/// and compared with the naive guess "tomorrow equals today".
public struct RecoveryForecast: Sendable {
    public let model: RidgeModel
    public let factorNames: [String]
    /// Mean absolute error of walk-forward predictions, in recovery points.
    public let backtestError: Double
    /// Same for "tomorrow = today".
    public let naiveError: Double
    public let trainedOn: Int

    public var beatsNaiveBy: Double { naiveError > 0 ? 1 - backtestError / naiveError : 0 }
    public var isUseful: Bool { backtestError < naiveError }

    public func predict(_ i: ForecastInput) -> Double {
        Stats.clamp(model.predict(Self.vector(i, factorNames)), 1, 99)
    }

    static func vector(_ i: ForecastInput, _ factors: [String]) -> [Double] {
        [i.sleepHours, i.bedtimeClock, i.strain, i.recovery] + factors.map { i.factors.contains($0) ? 1 : 0 }
    }

    public struct Row: Sendable {
        public let input: ForecastInput
        public let outcome: Double
    }

    public static func train(rows: [Row], minimum: Int = 21) -> RecoveryForecast? {
        guard rows.count >= minimum else { return nil }
        let counts = Dictionary(rows.flatMap { $0.input.factors.map { ($0, 1) } }, uniquingKeysWith: +)
        let factors = counts.filter { $0.value >= 5 && $0.value <= rows.count - 5 }.sorted { $0.value > $1.value }.prefix(8).map(\.key)
        let names = ["sleep_hours", "bedtime", "strain", "recovery"] + factors
        let x = rows.map { vector($0.input, factors) }, y = rows.map(\.outcome)
        guard let model = RidgeModel.fit(x, y, names: names, lambda: 3) else { return nil }

        var errs: [Double] = [], naive: [Double] = []
        let start = max(minimum, rows.count - 30)
        for j in start..<rows.count {
            guard let m = RidgeModel.fit(Array(x[..<j]), Array(y[..<j]), names: names, lambda: 3) else { continue }
            errs.append(abs(Stats.clamp(m.predict(x[j]), 1, 99) - y[j]))
            naive.append(abs(rows[j].input.recovery - y[j]))
        }
        guard !errs.isEmpty else { return nil }
        return RecoveryForecast(model: model, factorNames: factors, backtestError: Stats.mean(errs),
                                naiveError: Stats.mean(naive), trainedOn: rows.count)
    }
}

/// One habit's effect on the next morning, holding other habits, strain and bedtime steady.
public struct HabitEffect: Sendable, Identifiable {
    public var id: String { factor.id + outcome.rawValue }
    public let factor: JournalFactor
    public let outcome: Outcome
    public let effect: Double
    /// Half-width of the 95% interval.
    public let ci: Double
    public let withCount: Int
    public let withoutCount: Int

    public enum Outcome: String, CaseIterable, Sendable { case recovery = "Recovery", hrv = "HRV", sleep = "Sleep" }

    public var isSolid: Bool { abs(effect) > ci }
    /// 0–1: how far the interval sits from zero.
    public var confidence: Double { Stats.clamp(abs(effect) / max(ci, 0.01) / 2, 0, 1) }
}

public enum HabitEffects {
    public struct Row: Sendable {
        public let factors: Set<String>
        public let strain: Double
        public let bedtimeClock: Double?
        public let weekend: Bool
        public let recovery: Double?
        public let hrv: Double?
        public let sleep: Double?
    }

    public static func compute(rows: [Row], factors: [JournalFactor]) -> [HabitEffect] {
        var out: [HabitEffect] = []
        for outcome in HabitEffect.Outcome.allCases {
            let usable = rows.filter { value($0, outcome) != nil }
            let present = factors.filter { f in
                let c = usable.filter { $0.factors.contains(f.id) }.count
                return c >= 5 && usable.count - c >= 5
            }
            guard !present.isEmpty else { continue }
            let names = present.map(\.id) + ["strain", "bedtime", "weekend"]
            let medianBed = Stats.percentile(usable.compactMap(\.bedtimeClock), 0.5) ?? 5
            let x: [[Double]] = usable.map { r in
                let flags: [Double] = present.map { r.factors.contains($0.id) ? 1.0 : 0.0 }
                let controls: [Double] = [r.strain, r.bedtimeClock ?? medianBed, r.weekend ? 1.0 : 0.0]
                return flags + controls
            }
            let y = usable.compactMap { value($0, outcome) }
            guard let m = RidgeModel.fit(x, y, names: names, lambda: 1) else { continue }
            for (i, f) in present.enumerated() {
                let with = usable.filter { $0.factors.contains(f.id) }.count
                out.append(HabitEffect(factor: f, outcome: outcome, effect: m.coefficients[i], ci: 1.96 * m.standardErrors[i],
                                       withCount: with, withoutCount: usable.count - with))
            }
        }
        return out.sorted { $0.effect < $1.effect }
    }

    static func value(_ r: Row, _ o: HabitEffect.Outcome) -> Double? {
        switch o {
        case .recovery: return r.recovery
        case .hrv: return r.hrv
        case .sleep: return r.sleep
        }
    }
}
