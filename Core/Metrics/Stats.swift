import Foundation

/// Rolling personal baseline (mean ± SD) of one metric.
public struct Baseline: Codable, Sendable {
    public let mean: Double
    public let sd: Double
    public let count: Int

    public init(mean: Double, sd: Double, count: Int) {
        self.mean = mean
        self.sd = sd
        self.count = count
    }

    /// Five data points is the minimum before a score is trusted.
    public var isReliable: Bool { count >= 5 }

    /// SD floor keeps a very stable metric from turning noise into huge z-scores.
    public func z(_ value: Double, minSD: Double) -> Double {
        (value - mean) / max(sd, minSD)
    }

    public var lower: Double { mean - sd }
    public var upper: Double { mean + sd }
}

public enum Stats {
    public static func mean(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    public static func sd(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return sqrt(v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1))
    }

    public static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let pos = clamp(p, 0, 1) * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        guard lo != hi else { return s[lo] }
        let f = pos - Double(lo)
        return s[lo] * (1 - f) + s[hi] * f
    }

    public static func baseline(_ v: [Double]) -> Baseline? {
        guard v.count >= 3 else { return nil }
        return Baseline(mean: mean(v), sd: sd(v), count: v.count)
    }

    public static func logistic(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// Exponentially weighted moving average with time constant `days`
    /// (Banister fitness-fatigue model form).
    public static func ewma(_ values: [Double], days: Double) -> [Double] {
        let k = 1 - exp(-1 / days)
        var out: [Double] = []
        var acc = 0.0
        for v in values {
            acc += k * (v - acc)
            out.append(acc)
        }
        return out
    }

    /// Welch's t statistic for two independent samples.
    public static func welchT(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let se = sqrt(pow(sd(a), 2) / Double(a.count) + pow(sd(b), 2) / Double(b.count))
        guard se > 0 else { return nil }
        return (mean(a) - mean(b)) / se
    }
}
