import Foundation

// MARK: - Sleep

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case awake, light, deep, rem, unknown

    /// Maps Google Health enums and Fitbit legacy values.
    public init(apiValue: String) {
        switch apiValue.uppercased() {
        case "AWAKE", "WAKE", "RESTLESS": self = .awake
        case "LIGHT", "ASLEEP", "CORE": self = .light
        case "DEEP": self = .deep
        case "REM": self = .rem
        default: self = .unknown
        }
    }

    public var isAsleep: Bool { self == .light || self == .deep || self == .rem || self == .unknown }
}

public struct StageSpan: Codable, Hashable, Sendable {
    public var stage: SleepStage
    public var start: Date
    public var end: Date

    public init(stage: SleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var minutes: Double { max(0, end.timeIntervalSince(start) / 60) }
}

public struct SleepSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var minutesAsleep: Double
    public var minutesAwake: Double
    public var stages: [StageSpan]
    public var isMainSleep: Bool

    public init(id: String, start: Date, end: Date, minutesAsleep: Double, minutesAwake: Double,
                stages: [StageSpan] = [], isMainSleep: Bool = true) {
        self.id = id
        self.start = start
        self.end = end
        self.minutesAsleep = minutesAsleep
        self.minutesAwake = minutesAwake
        self.stages = stages
        self.isMainSleep = isMainSleep
    }

    public var minutesInBed: Double { max(0, end.timeIntervalSince(start) / 60) }

    public var efficiency: Double? {
        minutesInBed > 0 ? min(100, minutesAsleep / minutesInBed * 100) : nil
    }

    public func minutes(in stage: SleepStage) -> Double {
        stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }
    }

    /// Builds a session from stage spans alone (HealthKit delivers sleep that way).
    public static func from(stages: [StageSpan], id: String) -> SleepSession? {
        guard let start = stages.map(\.start).min(), let end = stages.map(\.end).max() else { return nil }
        let asleep = stages.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.minutes }
        let awake = stages.filter { $0.stage == .awake }.reduce(0) { $0 + $1.minutes }
        return SleepSession(id: id, start: start, end: end, minutesAsleep: asleep, minutesAwake: awake,
                            stages: stages.sorted { $0.start < $1.start })
    }
}

// MARK: - Heart rate, workouts

public struct HRSample: Codable, Hashable, Sendable {
    public var t: Date
    public var bpm: Double

    public init(t: Date, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

public struct Workout: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var start: Date
    public var end: Date
    public var averageHR: Double?
    public var calories: Double?
    public var strain: Double?

    public init(id: String, name: String, start: Date, end: Date, averageHR: Double? = nil,
                calories: Double? = nil, strain: Double? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.averageHR = averageHR
        self.calories = calories
        self.strain = strain
    }

    public var durationMinutes: Double { max(0, end.timeIntervalSince(start) / 60) }
}

public struct MinuteValue: Codable, Hashable, Sendable {
    public var t: Date
    public var v: Double
    public init(t: Date, v: Double) { self.t = t; self.v = v }
}

/// One logged meal or drink. Caffeine is tracked separately because its timing matters.
public struct Meal: Codable, Hashable, Sendable {
    public var time: Date
    public var kcal: Double?
    public var proteinG: Double?
    public var caffeineMg: Double?
    public var alcoholG: Double?
    public var carbG: Double?
    public var fatG: Double?
    public var fiberG: Double?
    public init(time: Date, kcal: Double? = nil, proteinG: Double? = nil, caffeineMg: Double? = nil, alcoholG: Double? = nil,
                carbG: Double? = nil, fatG: Double? = nil, fiberG: Double? = nil) {
        self.time = time
        self.kcal = kcal
        self.proteinG = proteinG
        self.caffeineMg = caffeineMg
        self.alcoholG = alcoholG
        self.carbG = carbG
        self.fatG = fatG
        self.fiberG = fiberG
    }
}

extension DayRecord {
    public var kcalTotal: Double? {
        let v = (meals ?? []).compactMap(\.kcal)
        return v.isEmpty ? nil : v.reduce(0, +)
    }
    public var proteinTotal: Double? {
        let v = (meals ?? []).compactMap(\.proteinG)
        return v.isEmpty ? nil : v.reduce(0, +)
    }
}

public struct DayWeather: Codable, Hashable, Sendable {
    public var maxTempC: Double?
    public var nightMinTempC: Double?
    public var aqi: Double?
    public init(maxTempC: Double?, nightMinTempC: Double?, aqi: Double?) {
        self.maxTempC = maxTempC
        self.nightMinTempC = nightMinTempC
        self.aqi = aqi
    }
}

// MARK: - Profile

public enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case male, female, unspecified

    public init(apiValue: String?) {
        switch apiValue?.uppercased() {
        case "MALE", "M": self = .male
        case "FEMALE", "F": self = .female
        default: self = .unspecified
        }
    }
}

public struct UserSettings: Codable, Sendable, Equatable {
    public var age: Int = 30
    public var sex: BiologicalSex = .unspecified
    public var maxHROverride: Double?
    /// Baseline nightly sleep need in hours before debt and strain adjustments.
    public var baseSleepNeedHours: Double = 7.6
    public var historyDays: Int = 90
    public var demoMode: Bool = false
    public var googleClientID: String = ""
    public var notifyIllness: Bool = true
    public var notifyRecovery: Bool = true
    public var notifyBedtime: Bool = true
    /// Weight goal pace, kg per week (negative to lose). nil tracks food with no calorie target.
    public var goalRateKgPerWeek: Double? = -0.75
    /// From Apple Health when set there; used for the starting burn estimate before DOOP has learned yours.
    public var heightCm: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings()
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? d.age
        sex = try c.decodeIfPresent(BiologicalSex.self, forKey: .sex) ?? d.sex
        maxHROverride = try c.decodeIfPresent(Double.self, forKey: .maxHROverride)
        baseSleepNeedHours = try c.decodeIfPresent(Double.self, forKey: .baseSleepNeedHours) ?? d.baseSleepNeedHours
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? d.historyDays
        demoMode = try c.decodeIfPresent(Bool.self, forKey: .demoMode) ?? d.demoMode
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? d.googleClientID
        notifyIllness = try c.decodeIfPresent(Bool.self, forKey: .notifyIllness) ?? d.notifyIllness
        notifyRecovery = try c.decodeIfPresent(Bool.self, forKey: .notifyRecovery) ?? d.notifyRecovery
        notifyBedtime = try c.decodeIfPresent(Bool.self, forKey: .notifyBedtime) ?? d.notifyBedtime
        goalRateKgPerWeek = c.contains(.goalRateKgPerWeek) ? try c.decodeIfPresent(Double.self, forKey: .goalRateKgPerWeek) : d.goalRateKgPerWeek
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
    }

    /// Tanaka et al. 2001: 208 − 0.7 × age.
    public var maxHR: Double { maxHROverride ?? (208 - 0.7 * Double(age)) }
}

// MARK: - Day record

public enum DataSource: String, Codable, Sendable {
    case appleHealth, google, demo
}

/// Every raw metric for one calendar day. Overnight metrics belong to the day you woke up.
public struct DayRecord: Codable, Sendable {
    public var date: String

    /// Nightly RMSSD in ms (Google Health API only; Apple Health does not receive it from Fitbit).
    public var hrvRmssd: Double?
    /// SDNN in ms, from Apple Health if any source writes it. Never mixed with RMSSD baselines.
    public var hrvSdnn: Double?
    public var restingHR: Double?
    public var respiratoryRate: Double?
    public var spo2Avg: Double?
    public var spo2Min: Double?
    /// Nightly skin temperature in °C (absolute or deviation, depending on source; scored vs own baseline).
    public var skinTemp: Double?
    public var vo2max: Double?

    public var steps: Int?
    public var activeEnergy: Double?
    public var sleepSessions: [SleepSession] = []
    public var workouts: [Workout] = []
    /// Intraday HR, reduced to one-minute means.
    public var hrSamples: [HRSample] = []

    public var syncedAt: Date?
    public var hrSyncedAt: Date?

    // Added in v0.2. Optional so older saved data still decodes.
    /// Steps per minute (non-zero minutes only), for telling stress apart from movement.
    public var stepMinutes: [MinuteValue]?
    /// Time zone the phone was in that day, for travel and jet-lag detection.
    public var timeZoneID: String?
    public var weather: DayWeather?
    /// Meals and drinks food apps write to Apple Health.
    public var meals: [Meal]?
    /// Weigh-ins other apps (Omada) write to Apple Health, kg.
    public var weightKg: Double?
    public var mindfulMinutes: Double?
    /// From the calendar: when the last timed event ended, and hours of events that day.
    public var lastEventEnd: Date?
    public var eventHours: Double?

    public init(date: String) { self.date = date }

    public var mainSleep: SleepSession? {
        sleepSessions.first(where: { $0.isMainSleep }) ?? sleepSessions.max(by: { $0.minutesAsleep < $1.minutesAsleep })
    }

    public var totalSleepMinutes: Double { sleepSessions.reduce(0) { $0 + $1.minutesAsleep } }

    /// Fills gaps in `self` from `other`; HRV RMSSD from Google always wins.
    public mutating func merge(_ other: DayRecord) {
        hrvRmssd = other.hrvRmssd ?? hrvRmssd
        hrvSdnn = hrvSdnn ?? other.hrvSdnn
        restingHR = restingHR ?? other.restingHR
        respiratoryRate = respiratoryRate ?? other.respiratoryRate
        spo2Avg = spo2Avg ?? other.spo2Avg
        spo2Min = spo2Min ?? other.spo2Min
        skinTemp = skinTemp ?? other.skinTemp
        vo2max = vo2max ?? other.vo2max
        steps = steps ?? other.steps
        activeEnergy = activeEnergy ?? other.activeEnergy
        if sleepSessions.isEmpty { sleepSessions = other.sleepSessions }
        if workouts.isEmpty { workouts = other.workouts }
        if hrSamples.count < other.hrSamples.count { hrSamples = other.hrSamples }
        syncedAt = [syncedAt, other.syncedAt].compactMap { $0 }.max()
        stepMinutes = stepMinutes ?? other.stepMinutes
        timeZoneID = timeZoneID ?? other.timeZoneID
        weather = weather ?? other.weather
        meals = meals ?? other.meals
        weightKg = weightKg ?? other.weightKg
        mindfulMinutes = mindfulMinutes ?? other.mindfulMinutes
        lastEventEnd = lastEventEnd ?? other.lastEventEnd
        eventHours = eventHours ?? other.eventHours
    }
}

extension Array where Element == HRSample {
    /// Collapses raw samples (down to ~5 s resolution) into one-minute means.
    public static func minuteMeans(_ raw: [(Date, Double)]) -> [HRSample] {
        var buckets: [Date: (Double, Int)] = [:]
        for (t, v) in raw {
            let b = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let e = buckets[b] ?? (0, 0)
            buckets[b] = (e.0 + v, e.1 + 1)
        }
        return buckets.map { HRSample(t: $0.key, bpm: $0.value.0 / Double($0.value.1)) }.sorted { $0.t < $1.t }
    }
}
