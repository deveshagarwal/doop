import Foundation

/// Deterministic generator so results are reproducible in tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func normal(_ mean: Double, _ sd: Double) -> Double {
        let u1 = Double.random(in: 0.0001..<1, using: &self), u2 = Double.random(in: 0..<1, using: &self)
        return mean + sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// 90 days of plausible data with known effects baked in, so every screen and insight has
/// something real to show: alcohol drops next-morning HRV, meditation nudges it up,
/// a training block builds load, and an illness hits ~2 weeks ago.
public enum DemoData {
    public static func generate(days count: Int = 90, endingOn end: String = DayKey.today(), seed: UInt64 = 7)
        -> (days: [String: DayRecord], journal: [String: JournalEntry]) {
        var rng = SeededRNG(seed: seed)
        var days: [String: DayRecord] = [:]
        var journal: [String: JournalEntry] = [:]
        let keys = DayKey.keys(from: DayKey.addDays(end, -(count - 1)), to: end)
        let illnessStart = keys.count - 16
        var prevFactors: Set<String> = []
        var prevHard = false

        for (i, key) in keys.enumerated() {
            guard let midnight = DayKey.date(from: key) else { continue }
            var d = DayRecord(date: key)

            // Overnight physiology reflects what happened the previous day.
            let fitness = Double(i) / Double(count) // slowly improving
            var hrv = 62 + 6 * fitness
            var rhr = 54 - 2 * fitness
            var resp = 14.2, temp = 33.9, spo2 = 96.5
            if prevFactors.contains("alcohol") { hrv *= 0.88; rhr += 2.5 }
            if prevFactors.contains("late_meal") { hrv *= 0.95; rhr += 1 }
            if prevFactors.contains("late_meeting") { hrv *= 0.97 }
            if prevFactors.contains("mindful") { hrv *= 1.03 }
            if prevFactors.contains("hot_night") { hrv *= 0.96; rhr += 0.8 }
            if prevFactors.contains("travel") { hrv *= 0.92; rhr += 2 }
            if prevHard { hrv *= 0.93; rhr += 1.5 }
            let sick = i - illnessStart
            if (0...4).contains(sick) {
                let sev = [0.5, 1.0, 1.0, 0.7, 0.35][sick]
                hrv *= 1 - 0.3 * sev; rhr += 7 * sev; resp += 1.6 * sev; temp += 0.7 * sev; spo2 -= 1.2 * sev
            }
            d.hrvRmssd = max(20, rng.normal(hrv, 8))
            d.restingHR = rng.normal(rhr, 2.0)
            d.respiratoryRate = rng.normal(resp, 0.25)
            d.skinTemp = rng.normal(temp, 0.12)
            d.spo2Avg = rng.normal(spo2, 0.4)
            d.spo2Min = (d.spo2Avg ?? 96) - abs(rng.normal(3, 1))
            d.vo2max = 46 + 2 * fitness

            // Sleep: bed around 23:15, ~7h asleep, shorter after alcohol.
            var asleep = rng.normal(425, 35)
            if prevFactors.contains("alcohol") { asleep -= 25 }
            if prevFactors.contains("late_caffeine") { asleep -= 22 }
            let bed = midnight.addingTimeInterval(rng.normal(-45, 25) * 60)
            d.sleepSessions = [makeSleep(bed: bed, asleepMinutes: asleep, deepBoost: prevFactors.contains("alcohol") ? -0.4 : 0, rng: &rng, id: key)]

            // Daytime activity. Training block in weeks 7–10, nothing while sick.
            let weekday = Calendar.current.component(.weekday, from: midnight)
            let block = i > count - 40 && i < count - 18
            var workout: (start: Double, minutes: Double, hrr: Double, name: String)?
            if !(0...4).contains(sick) {
                if [2, 4, 6].contains(weekday) || (block && weekday == 7) {
                    workout = (18, block ? rng.normal(65, 10) : rng.normal(45, 8), block ? 0.72 : 0.62, "Run")
                } else if weekday == 1 && rng.chance(0.6) {
                    workout = (10, rng.normal(90, 15), 0.55, "Cycling")
                }
            }
            let mainRHR = d.restingHR ?? 55
            d.hrSamples = makeHR(midnight: midnight, sleep: d.sleepSessions[0], rhr: mainRHR, workout: workout, rng: &rng)
            if let w = workout {
                let start = midnight.addingTimeInterval(w.start * 3600)
                let end = start.addingTimeInterval(w.minutes * 60)
                let inWindow = d.hrSamples.filter { $0.t >= start && $0.t <= end }.map(\.bpm)
                d.workouts = [Workout(id: "demo-\(key)", name: w.name, start: start, end: end,
                                      averageHR: Stats.mean(inWindow), calories: w.minutes * 11)]
            }
            prevHard = (workout?.hrr ?? 0) >= 0.7
            d.steps = Int(rng.normal(workout?.name == "Run" ? 12_500 : 7_800, 1_800))
            d.activeEnergy = Double(d.steps ?? 0) * 0.045 + (workout.map { $0.minutes * 9 } ?? 0)
            d.syncedAt = Date()
            d.hrSyncedAt = Date()
            days[key] = d

            // The day's habits. Only alcohol goes in the journal (as if you answered the one question);
            // everything else is planted as data the auto-logger has to find.
            var f: Set<String> = []
            let weekend = weekday == 6 || weekday == 7
            if rng.chance(weekend ? 0.55 : 0.12) { f.insert("alcohol") }
            let lateDinner = rng.chance(0.25), lateCoffee = rng.chance(weekend ? 0.1 : 0.3)
            if lateDinner { f.insert("late_meal") }
            if lateCoffee { f.insert("late_caffeine") }
            var meals = [Meal(time: midnight.addingTimeInterval(rng.normal(7.8, 0.4) * 3600), kcal: rng.normal(480, 80), proteinG: rng.normal(28, 6), caffeineMg: 95),
                         Meal(time: midnight.addingTimeInterval(rng.normal(12.6, 0.4) * 3600), kcal: rng.normal(700, 120), proteinG: rng.normal(40, 10)),
                         Meal(time: midnight.addingTimeInterval((lateDinner ? rng.normal(21.6, 0.3) : rng.normal(19.0, 0.4)) * 3600),
                              kcal: rng.normal(lateDinner ? 950 : 780, 120), proteinG: rng.normal(45, 12))]
            if lateCoffee { meals.append(Meal(time: midnight.addingTimeInterval(rng.normal(15.3, 0.4) * 3600), caffeineMg: 120)) }
            d.meals = meals
            d.weightKg = rng.chance(0.8) ? 80.6 - 2.2 * fitness + rng.normal(0, 0.35) : nil
            let lateMeeting = !weekend && rng.chance(0.2)
            if lateMeeting { f.insert("late_meeting") }
            d.lastEventEnd = weekend ? nil : midnight.addingTimeInterval((lateMeeting ? rng.normal(20.2, 0.4) : rng.normal(17.2, 0.6)) * 3600)
            d.eventHours = weekend ? 0 : max(0, rng.normal(4.2, 1.6))
            let hot = rng.chance(0.12)
            if hot { f.insert("hot_night") }
            d.weather = DayWeather(maxTempC: rng.normal(hot ? 31 : 22, 3), nightMinTempC: hot ? rng.normal(23, 1) : rng.normal(13, 3), aqi: nil)
            let trip = (25...29).contains(i)
            d.timeZoneID = trip ? "America/New_York" : "America/Los_Angeles"
            if i == 25 || i == 30 { f.insert("travel") }
            if rng.chance(0.35) { f.insert("mindful"); d.mindfulMinutes = rng.normal(12, 4) }
            // Steps per minute: a few walks plus the workout, for the stress engine.
            var steps: [MinuteValue] = []
            for _ in 0..<5 {
                let startMin = Int(rng.normal(13 * 60, 160))
                for m in 0..<Int(max(5, rng.normal(14, 5))) { steps.append(MinuteValue(t: midnight.addingTimeInterval(Double(startMin + m) * 60), v: rng.normal(95, 15))) }
            }
            for w in d.workouts where w.name == "Run" {
                var t = w.start
                while t < w.end { steps.append(MinuteValue(t: t, v: 160)); t = t.addingTimeInterval(60) }
            }
            d.stepMinutes = steps
            days[key] = d

            if i < keys.count - 1, f.contains("alcohol") { journal[key] = JournalEntry(date: key, factors: ["alcohol"]) }
            prevFactors = f
        }
        return (days, journal)
    }

    static func makeSleep(bed: Date, asleepMinutes: Double, deepBoost: Double, rng: inout SeededRNG, id: String) -> SleepSession {
        var spans: [StageSpan] = []
        var t = bed
        // Fall asleep
        spans.append(StageSpan(stage: .awake, start: t, end: t.addingTimeInterval(rng.normal(12, 4) * 60)))
        t = spans.last!.end
        var slept = 0.0
        var cycle = 0
        while slept < asleepMinutes {
            // Deep front-loaded, REM back-loaded across ~90-minute cycles.
            let early = max(0, 1 - Double(cycle) / 4)
            let deep = max(3, rng.normal(25 * early * (1 + deepBoost) + 4, 4))
            let rem = max(5, rng.normal(12 + 9 * Double(cycle), 4))
            let light = max(20, rng.normal(48, 8))
            for (stage, m) in [(SleepStage.light, light), (.deep, deep), (.light, 8), (.rem, rem)] {
                let mins = min(m, asleepMinutes - slept)
                guard mins > 0 else { break }
                spans.append(StageSpan(stage: stage, start: t, end: t.addingTimeInterval(mins * 60)))
                t = t.addingTimeInterval(mins * 60)
                slept += mins
            }
            if rng.chance(0.5) {
                let wake = rng.normal(4, 2)
                spans.append(StageSpan(stage: .awake, start: t, end: t.addingTimeInterval(max(1, wake) * 60)))
                t = spans.last!.end
            }
            cycle += 1
        }
        return SleepSession.from(stages: spans, id: "demo-sleep-\(id)")!
    }

    static func makeHR(midnight: Date, sleep: SleepSession, rhr: Double,
                       workout: (start: Double, minutes: Double, hrr: Double, name: String)?, rng: inout SeededRNG) -> [HRSample] {
        let maxHR = 189.0
        var out: [HRSample] = []
        out.reserveCapacity(1440)
        for minute in 0..<1440 {
            let t = midnight.addingTimeInterval(Double(minute) * 60)
            let hour = Double(minute) / 60
            var bpm: Double
            if t >= sleep.start && t <= sleep.end || hour < 6.5 {
                bpm = rng.normal(rhr + 4, 2.5)
            } else {
                bpm = rng.normal(rhr + 22, 7)
                if rng.chance(0.03) { bpm += rng.normal(25, 8) } // stairs, walking fast
            }
            if let w = workout, hour >= w.start, hour < w.start + w.minutes / 60 {
                let target = rhr + w.hrr * (maxHR - rhr)
                let into = (hour - w.start) * 60
                bpm = rng.normal(min(target, rhr + 30 + into * 6), 5)
            }
            out.append(HRSample(t: t, bpm: max(40, bpm)))
        }
        return out
    }
}
