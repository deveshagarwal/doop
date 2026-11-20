import Foundation

/// A line in the automatic day log.
public struct LogEvent: Sendable, Identifiable {
    public var id: String { "\(time.timeIntervalSince1970)-\(title)" }
    public let time: Date
    public let title: String
    public let source: String
    /// The factor this event sets, if any (shown in ember).
    public let factor: String?
}

/// A yes/no the app asks because the data alone can't tell.
public struct DailyQuestion: Sendable {
    public let day: String
    public let factor: String
    public let prompt: String
    public let evidence: String
}

/// Works out the day's habits from data you already create, so nothing needs logging.
/// Each rule is deliberately simple and named after its source so the log can show where it came from.
public enum AutoLog {
    static func hour(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    /// Factors detected for `day`. `nextMorning` holds the sleep that followed it (its start is the bedtime).
    public static func factors(day: DayRecord, previous: DayRecord?, nextMorning: DayRecord?, highStressMinutes: Double?) -> Set<String> {
        var f: Set<String> = []
        let bedtime = nextMorning?.mainSleep?.start
        let meals = day.meals ?? []

        if let last = meals.filter({ ($0.kcal ?? 0) >= 150 }).map(\.time).max() {
            if hour(last) >= 21 || (bedtime.map { $0.timeIntervalSince(last) < 2.5 * 3600 } ?? false) { f.insert("late_meal") }
        }
        if meals.filter({ hour($0.time) >= 17 }).compactMap(\.kcal).reduce(0, +) >= 1000 { f.insert("big_dinner") }
        if meals.contains(where: { ($0.caffeineMg ?? 0) >= 40 && hour($0.time) >= 14 }) { f.insert("late_caffeine") }
        if meals.compactMap(\.alcoholG).reduce(0, +) >= 14 { f.insert("alcohol") }
        if (day.proteinTotal ?? 0) >= 140 { f.insert("high_protein") }

        for w in day.workouts {
            let late = bedtime.map { $0.timeIntervalSince(w.end) < 3 * 3600 && $0 > w.end } ?? (hour(w.end) >= 19.5)
            if late { f.insert("late_workout") }
        }
        if let end = day.lastEventEnd, hour(end) >= 19 { f.insert("late_meeting") }
        if (day.eventHours ?? 0) >= 6 { f.insert("packed_day") }
        if let t = day.weather?.nightMinTempC, t >= 21 { f.insert("hot_night") }
        if let tz = day.timeZoneID, let prev = previous?.timeZoneID, tz != prev { f.insert("travel") }
        if (day.mindfulMinutes ?? 0) >= 5 { f.insert("mindful") }
        if (highStressMinutes ?? 0) >= 45 { f.insert("high_stress") }
        return f
    }

    /// How elevated heart rate stays in the first half of the night, relative to the night's floor.
    /// Alcohol keeps it high for hours after you fall asleep (Pietilä et al. 2018, JMIR Ment Health).
    public static func firstHalfElevation(_ d: DayRecord, evening: DayRecord?) -> Double? {
        guard let s = d.mainSleep, s.minutesInBed > 180 else { return nil }
        let samples = ((evening?.hrSamples ?? []) + d.hrSamples).filter { $0.t >= s.start && $0.t <= s.end }.map(\.bpm)
        guard samples.count > 60, let floor = Stats.percentile(samples, 0.05) else { return nil }
        let firstHalf = Array(samples.prefix(samples.count / 2))
        return Stats.mean(firstHalf) - floor
    }

    /// Asks about alcohol when last night carries its signature and nothing already answers it.
    public static func question(morning: DayRecord, evening: DayRecord?, book: BaselineBook,
                                journal: [String: JournalEntry], detected: Set<String>) -> DailyQuestion? {
        let day = DayKey.addDays(morning.date, -1)
        if detected.contains("alcohol") { return nil }
        if let j = journal[day], j.factors.contains("alcohol") || j.denied.contains("alcohol") { return nil }
        guard let e = firstHalfElevation(morning, evening: evening) else { return nil }

        let history = (1...30).compactMap { i -> Double? in
            let k = DayKey.addDays(morning.date, -i)
            guard let d = book.days[k] else { return nil }
            return firstHalfElevation(d, evening: book.days[DayKey.addDays(k, -1)])
        }
        guard let base = Stats.baseline(history), base.isReliable else { return nil }
        let z = base.z(e, minSD: 1.5)
        let rhrZ = morning.restingHR.flatMap { v in book.baseline(before: morning.date, Metric.restingHR.value).map { $0.z(v, minSD: 1.5) } } ?? 0
        let hrvZ = Metric.hrvRmssd.value(morning).flatMap { v in book.baseline(before: morning.date, Metric.hrvRmssd.value).map { $0.z(v, minSD: 0.06) } } ?? 0
        guard z >= 1.8, rhrZ >= 1 || hrvZ <= -1 else { return nil }
        let peakHour = elevatedUntil(morning, evening: evening)
        return DailyQuestion(day: day, factor: "alcohol", prompt: "Drinks last night?",
                             evidence: String(format: "Heart rate stayed %.0f bpm high%@", e - base.mean,
                                              peakHour.map { " until \($0)" } ?? ""))
    }

    static func elevatedUntil(_ d: DayRecord, evening: DayRecord?) -> String? {
        guard let s = d.mainSleep else { return nil }
        let samples = ((evening?.hrSamples ?? []) + d.hrSamples).filter { $0.t >= s.start && $0.t <= s.end }
        guard let floor = Stats.percentile(samples.map(\.bpm), 0.05) else { return nil }
        let last = samples.last { $0.bpm > floor + 8 && $0.t < s.start.addingTimeInterval(s.minutesInBed * 30) }
        return last.map { $0.t.formatted(date: .omitted, time: .shortened) }
    }

    /// The day's timeline for the Day log screen.
    public static func events(day: DayRecord, factors: Set<String>) -> [LogEvent] {
        var out: [LogEvent] = []
        let midnight = DayKey.date(from: day.date) ?? Date()
        if let w = day.weightKg {
            out.append(LogEvent(time: midnight.addingTimeInterval(7 * 3600), title: String(format: "Weighed %.1f kg", w), source: "Omada", factor: nil))
        }
        for m in day.meals ?? [] {
            let h = hour(m.time)
            if let c = m.caffeineMg, c >= 40 {
                out.append(LogEvent(time: m.time, title: "Coffee · \(Int(c)) mg caffeine", source: "Food log",
                                    factor: h >= 14 ? "late_caffeine" : nil))
            }
            if let k = m.kcal, k >= 150 {
                let name = h < 11 ? "Breakfast" : h < 16 ? "Lunch" : "Dinner"
                let late = factors.contains("late_meal") && h >= 19
                out.append(LogEvent(time: m.time, title: "\(name) · \(Int(k)) kcal" + (m.proteinG.map { " · \(Int($0))g protein" } ?? ""),
                                    source: late ? "Food log · late meal" : "Food log", factor: late ? "late_meal" : nil))
            }
            if let a = m.alcoholG, a > 0 {
                out.append(LogEvent(time: m.time, title: "Drink logged", source: "Food log", factor: "alcohol"))
            }
        }
        for w in day.workouts {
            let late = factors.contains("late_workout") && hour(w.end) >= 18
            out.append(LogEvent(time: w.start, title: "\(w.name) · \(Int(w.durationMinutes)) min" + (w.strain.map { String(format: " · strain %.1f", $0) } ?? ""),
                                source: late ? "Fitbit · late workout" : "Fitbit", factor: late ? "late_workout" : nil))
        }
        if let end = day.lastEventEnd {
            let late = hour(end) >= 19
            out.append(LogEvent(time: end, title: "Last meeting ended", source: late ? "Calendar · late meeting" : "Calendar", factor: late ? "late_meeting" : nil))
        }
        if let m = day.mindfulMinutes, m >= 1 {
            out.append(LogEvent(time: midnight.addingTimeInterval(22 * 3600), title: "Mindful \(Int(m)) min", source: "Apple Health", factor: m >= 5 ? "mindful" : nil))
        }
        if let t = day.weather?.nightMinTempC {
            out.append(LogEvent(time: midnight.addingTimeInterval(23.9 * 3600), title: String(format: "Overnight low %.0f°C", t),
                                source: t >= 21 ? "Weather · hot night" : "Weather", factor: t >= 21 ? "hot_night" : nil))
        }
        if factors.contains("travel") {
            out.append(LogEvent(time: midnight, title: "Changed time zone", source: "Time zone · travel", factor: "travel"))
        }
        return out.sorted { $0.time < $1.time }
    }
}
