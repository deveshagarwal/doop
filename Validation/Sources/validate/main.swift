import Foundation
import BaselineCore

/// Converts LifeSnaps daily rows into DayRecords, runs the full Analyzer per participant,
/// and writes every score next to the reference signals for report.py to compare.
struct Row: Decodable {
    let date: String
    let rmssd, rhr, temp, resp, spo2, asleep, awake, inBedMs, z1, z2, z3, steps: Double?
}
struct User: Decodable { let id: String; let age: String; let gender: String; let days: [Row] }

let users = try JSONDecoder().decode([User].self, from: Data(contentsOf: URL(fileURLWithPath: "data/lifesnaps.json")))
var out: [[String: Any]] = []
var forecasts: [(Double, Double, Int)] = []

for u in users {
    var settings = UserSettings()
    settings.age = u.age.hasPrefix(">=30") ? 33 : 25   // LifeSnaps reports age bands only
    settings.sex = u.gender == "MALE" ? .male : (u.gender == "FEMALE" ? .female : .unspecified)

    var days: [String: DayRecord] = [:]
    for r in u.days {
        guard let midnight = DayKey.date(from: r.date) else { continue }
        var d = DayRecord(date: r.date)
        d.hrvRmssd = r.rmssd; d.restingHR = r.rhr; d.skinTemp = r.temp; d.respiratoryRate = r.resp
        d.spo2Avg = r.spo2
        if let s = r.steps { d.steps = Int(s) }
        // No bedtimes in the daily file: anchor wake at 07:00 so durations are right (consistency isn't testable).
        if let asleep = r.asleep, asleep > 60 {
            let wake = midnight.addingTimeInterval(7 * 3600)
            let inBed = (r.inBedMs ?? (asleep + (r.awake ?? 0)) * 60_000) / 60_000
            d.sleepSessions = [SleepSession(id: r.date, start: wake.addingTimeInterval(-inBed * 60), end: wake,
                                            minutesAsleep: asleep, minutesAwake: r.awake ?? 0)]
        }
        // No intraday HR: express Fitbit zone minutes as workouts at each zone's HRR midpoint.
        let maxHR = settings.maxHR, rest = r.rhr ?? 62
        var start = midnight.addingTimeInterval(17 * 3600)
        for (mins, hrr) in [(r.z1, 0.5), (r.z2, 0.7), (r.z3, 0.88)] {
            guard let m = mins, m > 0 else { continue }
            d.workouts.append(Workout(id: "\(r.date)-\(hrr)", name: "Zone", start: start, end: start.addingTimeInterval(m * 60),
                                      averageHR: rest + hrr * (maxHR - rest)))
            start = start.addingTimeInterval(m * 60)
        }
        days[r.date] = d
    }

    guard let last = days.keys.max() else { continue }
    let a = Analyzer.run(days: days, journal: [:], factors: [], settings: settings, today: last)
    if let f = a.forecast { forecasts.append((f.backtestError, f.naiveError, f.trainedOn)) }
    for (k, s) in a.scores where days[k] != nil {
        var row: [String: Any] = ["id": u.id, "date": k, "strain": s.strain.strain, "illness": s.illness.level.rawValue,
                                  "loadStatus": s.load.status.rawValue]
        if let r = s.recovery { row["recovery"] = r.score; row["usedHRV"] = r.usedHRV; row["calibrating"] = r.calibrating }
        if let sl = s.sleep { row["sleepPerf"] = sl.performance; row["debt"] = sl.debtMinutes }
        if let acwr = s.load.acwr { row["acwr"] = acwr }
        out.append(row)
    }
}
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: "data/scores.json"))
print("scored \(out.count) participant-days")
if !forecasts.isEmpty {
    let model = forecasts.map(\.0).reduce(0, +) / Double(forecasts.count), naive = forecasts.map(\.1).reduce(0, +) / Double(forecasts.count)
    let wins = forecasts.filter { $0.0 < $0.1 }.count
    print(String(format: "forecast: %d people with enough nights; error ±%.1f vs naive ±%.1f (%.0f%% better); beats naive for %d of %d",
                 forecasts.count, model, naive, (1 - model / naive) * 100, wins, forecasts.count))
}
