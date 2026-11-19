import Foundation

/// Looks up personal baselines over a trailing window that excludes the day being scored.
public struct BaselineBook: Sendable {
    public let days: [String: DayRecord]
    public let window: Int

    public init(days: [String: DayRecord], window: Int = 30) {
        self.days = days
        self.window = window
    }

    /// Values of `metric` from the `window` days before `key`, skipping the most recent `gap` days.
    /// The gap keeps an illness that started two days ago from dragging its own baseline up.
    public func values(before key: String, gap: Int = 0, _ metric: (DayRecord) -> Double?) -> [Double] {
        let end = DayKey.addDays(key, -(1 + gap))
        let start = DayKey.addDays(key, -(window + gap))
        return DayKey.keys(from: start, to: end).compactMap { days[$0].flatMap(metric) }
    }

    public func baseline(before key: String, gap: Int = 0, _ metric: (DayRecord) -> Double?) -> Baseline? {
        Stats.baseline(values(before: key, gap: gap, metric))
    }
}

/// The metrics everything else scores against. HRV is log-transformed because its
/// distribution is right-skewed (Plews et al. 2012, Int J Sports Physiol Perform).
public enum Metric: String, CaseIterable, Sendable {
    case hrvRmssd, hrvSdnn, restingHR, respiratoryRate, skinTemp, spo2

    public func value(_ d: DayRecord) -> Double? {
        switch self {
        case .hrvRmssd: return d.hrvRmssd.flatMap { $0 > 0 ? log($0) : nil }
        case .hrvSdnn: return d.hrvSdnn.flatMap { $0 > 0 ? log($0) : nil }
        case .restingHR: return d.restingHR
        case .respiratoryRate: return d.respiratoryRate
        case .skinTemp: return d.skinTemp
        case .spo2: return d.spo2Avg
        }
    }

    /// Floor on SD so a very stable metric doesn't turn noise into large z-scores.
    public var minSD: Double {
        switch self {
        case .hrvRmssd, .hrvSdnn: return 0.06
        case .restingHR: return 1.5
        case .respiratoryRate: return 0.4
        case .skinTemp: return 0.2
        case .spo2: return 0.6
        }
    }

    public var label: String {
        switch self {
        case .hrvRmssd: return "HRV"
        case .hrvSdnn: return "HRV (SDNN)"
        case .restingHR: return "Resting HR"
        case .respiratoryRate: return "Respiratory rate"
        case .skinTemp: return "Skin temperature"
        case .spo2: return "Blood oxygen"
        }
    }

    public var unit: String {
        switch self {
        case .hrvRmssd, .hrvSdnn: return "ms"
        case .restingHR: return "bpm"
        case .respiratoryRate: return "rpm"
        case .skinTemp: return "°C"
        case .spo2: return "%"
        }
    }

    /// Raw display value (undoes the log for HRV).
    public func display(_ d: DayRecord) -> Double? {
        switch self {
        case .hrvRmssd: return d.hrvRmssd
        case .hrvSdnn: return d.hrvSdnn
        default: return value(d)
        }
    }
}
