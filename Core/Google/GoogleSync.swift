import Foundation

public struct SyncLogEntry: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public let source: String
    public let metric: String
    public let detail: String
    public let isError: Bool

    public init(source: String, metric: String, detail: String, isError: Bool = false) {
        self.source = source
        self.metric = metric
        self.detail = detail
        self.isError = isError
    }
}

/// Pulls the overnight metrics Apple Health doesn't get from Fitbit (HRV above all),
/// plus a few nightly vitals to fill gaps. Each metric is isolated: one failure only
/// lands in the log. Intraday heart rate comes from Apple Health instead (far fewer requests).
public enum GoogleSync {
    public static func sync(client: HealthAPIClient, daysBack: Int) async -> (days: [String: DayRecord], log: [SyncLogEntry]) {
        var days: [String: DayRecord] = [:]
        var log: [SyncLogEntry] = []
        let end = Date()
        let start = DayKey.date(from: DayKey.addDays(DayKey.today(), -(daysBack - 1))) ?? end
        let nightStart = start.addingTimeInterval(-12 * 3600)

        func update(_ key: String, _ f: (inout DayRecord) -> Void) {
            var r = days[key] ?? DayRecord(date: key)
            f(&r)
            r.syncedAt = Date()
            days[key] = r
        }
        func note(_ m: String, _ d: String, _ err: Bool = false) { log.append(.init(source: "Google", metric: m, detail: d, isError: err)) }

        // HRV: the reason this connection exists. Samples first, daily aggregate as fallback.
        do {
            let s = try await client.samples(type: "heart-rate-variability", payloadKey: "heartRateVariability",
                                             valueKeys: ["rmssd", "rmssdMilliseconds", "milliseconds", "value"], start: nightStart, end: end)
            var byNight: [String: [Double]] = [:]
            for (t, v) in s { byNight[DayKey.nightKey(for: t), default: []].append(v) }
            for (k, v) in byNight { update(k) { $0.hrvRmssd = Stats.mean(v) } }
            if byNight.isEmpty {
                let d = try await client.daily(type: "daily-heart-rate-variability", payloadKey: "dailyHeartRateVariability",
                                               valueKeys: ["rmssdMilliseconds", "rmssd", "milliseconds", "value"], start: start, end: end)
                for (k, v) in d { update(k) { $0.hrvRmssd = v } }
                note("HRV", "\(d.count) nights (daily aggregate)")
            } else {
                note("HRV", "\(byNight.count) nights")
            }
        } catch { note("HRV", error.localizedDescription, true) }

        let dailies: [(String, String, String, [String], WritableKeyPath<DayRecord, Double?>)] = [
            ("Resting HR", "daily-resting-heart-rate", "dailyRestingHeartRate", ["beatsPerMinute", "bpm", "value"], \.restingHR),
            ("Respiratory rate", "daily-respiratory-rate", "dailyRespiratoryRate", ["breathsPerMinute", "rate", "value"], \.respiratoryRate),
            ("Skin temperature", "daily-sleep-temperature-derivations", "dailySleepTemperatureDerivations",
             ["nightlyTemperatureCelsius", "celsius", "value"], \.skinTemp),
            ("VO₂max", "daily-vo2-max", "dailyVo2Max", ["vo2Max", "vo2max", "value"], \.vo2max),
        ]
        for (label, type, key, valueKeys, path) in dailies {
            do {
                let d = try await client.daily(type: type, payloadKey: key, valueKeys: valueKeys, start: start, end: end)
                for (k, v) in d { update(k) { $0[keyPath: path] = v } }
                note(label, "\(d.count) days")
            } catch { note(label, error.localizedDescription, true) }
        }

        do {
            let s = try await client.samples(type: "oxygen-saturation", payloadKey: "oxygenSaturation",
                                             valueKeys: ["percentage", "averagePercentage", "value"], start: nightStart, end: end)
            var byNight: [String: [Double]] = [:]
            for (t, v) in s { byNight[DayKey.nightKey(for: t), default: []].append(v) }
            for (k, v) in byNight { update(k) { $0.spo2Avg = Stats.mean(v); $0.spo2Min = v.min() } }
            note("SpO₂", "\(byNight.count) nights")
        } catch { note("SpO₂", error.localizedDescription, true) }

        do {
            let sessions = try await client.sleepSessions(start: nightStart, end: end)
            var byDay: [String: [SleepSession]] = [:]
            for s in sessions { byDay[DayKey.string(from: s.end), default: []].append(s) }
            for (k, list) in byDay {
                var sorted = list.sorted { $0.start < $1.start }
                if !sorted.contains(where: \.isMainSleep), let i = sorted.indices.max(by: { sorted[$0].minutesAsleep < sorted[$1].minutesAsleep }) {
                    sorted[i].isMainSleep = true
                }
                update(k) { $0.sleepSessions = sorted }
            }
            note("Sleep", "\(sessions.count) sessions")
        } catch { note("Sleep", error.localizedDescription, true) }

        return (days, log)
    }
}
