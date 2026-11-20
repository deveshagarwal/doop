import Foundation
import BaselineCore

var failures = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    print(cond ? "  ✓ \(name)" : "  ✗ \(name) \(detail())")
    if !cond { failures += 1 }
}

print("Math")
check(abs(Stats.mean([1, 2, 3]) - 2) < 1e-9, "mean")
check(abs(Stats.sd([2, 4, 4, 4, 5, 5, 7, 9]) - 2.138) < 0.01, "sample SD")
check(StrainEngine.strain(fromTRIMP: 0) == 0, "zero TRIMP → zero strain")
check(StrainEngine.strain(fromTRIMP: 1000) < 21, "strain never reaches 21")
check(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE RFC 7636 vector")
check(JSONExtract.snakeCase("heartRateVariability") == "heart_rate_variability", "snake case")

print("Training load")
let flat = TrainingLoad.states(Array(repeating: 100, count: 60))
check(abs((flat.last?.acwr ?? 0) - 1) < 0.01, "steady load → ACWR 1.0", "\(flat.last?.acwr ?? -1)")
let spike = TrainingLoad.states(Array(repeating: 50, count: 40) + Array(repeating: 150, count: 7))
check(spike.last?.status == .highRisk, "sudden spike → high risk", "\(spike.last!.status)")
let stepsOnly = TrainingLoad.states(Array(repeating: 100, count: 40) + Array(repeating: 10, count: 10),
                                    measured: Array(repeating: false, count: 50))
check(stepsOnly.last?.status == .building, "no band data → not enough history, not detraining", "\(stepsOnly.last!.status)")

print("End-to-end on 90 demo days")
let end = "2026-11-19"
let demo = DemoData.generate(days: 90, endingOn: end)
var settings = UserSettings()
settings.age = 28
settings.sex = .male
let t0 = Date()
let a = Analyzer.run(days: demo.days, journal: demo.journal, settings: settings, today: end, now: DayKey.date(from: end)!.addingTimeInterval(15 * 3600))
print(String(format: "  analysis took %.2fs", Date().timeIntervalSince(t0)))

let recs = a.orderedKeys.compactMap { a.scores[$0]?.recovery?.score }
check(recs.count >= 80, "recovery scored most days", "\(recs.count)")
let meanRec = Stats.mean(recs.map(Double.init))
check((45...75).contains(meanRec), "average recovery in a WHOOP-like range", "\(meanRec)")

let illnessKeys = (11...15).map { DayKey.addDays(end, -$0) }   // planted episode
let illLevels = illnessKeys.compactMap { a.scores[$0]?.illness.level }
check(illLevels.contains(.alert), "planted illness triggers an alert", "\(illLevels)")
check(a.scores[DayKey.addDays(end, -15)]?.illness.level != .alert, "first night alone never alerts (needs persistence)")
let illRec = (13...14).compactMap { a.scores[DayKey.addDays(end, -$0)]?.recovery?.score }
check(illRec.allSatisfy { $0 < 34 }, "illness days are red", "\(illRec)")
let falseAlerts = a.orderedKeys.filter { k in
    a.scores[k]?.illness.level == .alert && !(DayKey.addDays(end, -16)...DayKey.addDays(end, -10)).contains(k)
}
check(falseAlerts.isEmpty, "no false alerts outside the episode", "\(falseAlerts)")

let runDay = a.orderedKeys.compactMap { a.scores[$0] }.filter { !$0.workouts.isEmpty }.map(\.strain.strain)
let restDay = a.orderedKeys.compactMap { a.scores[$0] }.filter { $0.workouts.isEmpty }.map(\.strain.strain)
check(Stats.mean(runDay) > Stats.mean(restDay) + 4, "workout days carry more strain",
      String(format: "%.1f vs %.1f", Stats.mean(runDay), Stats.mean(restDay)))
check((runDay.max() ?? 0) < 21 && (runDay.max() ?? 0) > 10, "strain range plausible", "\(runDay.max() ?? 0)")

print("Auto-logging and habit effects")
let detectedLate = a.orderedKeys.filter { a.scores[$0]?.factors.contains("late_meal") == true }.count
check(detectedLate >= 12, "late meals detected from Nourish-style meal times", "\(detectedLate)")
check(a.orderedKeys.contains { a.scores[$0]?.factors.contains("travel") == true }, "travel detected from time zone change")
check(a.orderedKeys.contains { a.scores[$0]?.factors.contains("hot_night") == true }, "hot nights detected from weather")
func effect(_ id: String, _ o: HabitEffect.Outcome = .recovery) -> HabitEffect? { a.effects.first { $0.factor.id == id && $0.outcome == o } }
if let e = effect("alcohol") { check(e.effect < -5 && e.isSolid, "alcohol: solid negative effect", String(format: "%+.1f ±%.1f", e.effect, e.ci)) } else { check(false, "alcohol effect computed") }
if let e = effect("late_meal") { check(e.effect < 0, "late meals: negative effect", String(format: "%+.1f ±%.1f", e.effect, e.ci)) } else { check(false, "late meal effect computed") }
if let e = effect("late_caffeine", .sleep) { check(e.effect < 0, "late caffeine: less sleep", String(format: "%+.1f ±%.1f", e.effect, e.ci)) } else { check(false, "caffeine effect computed") }

print("Forecast and suggestions")
if let f = a.forecast {
    print(String(format: "  forecast error ±%.1f vs naive ±%.1f (%.0f%% better), %d nights", f.backtestError, f.naiveError, f.beatsNaiveBy * 100, f.trainedOn))
    check(f.isUseful, "forecast beats 'tomorrow = today'")
    if let early = a.forecastTomorrow(bedtime: 4.0), let late = a.forecastTomorrow(bedtime: 7.0) {
        check(early > late, "earlier bedtime forecasts better recovery", String(format: "%.0f vs %.0f", early, late))
    }
} else { check(false, "forecast trained") }
check(!a.suggestions.isEmpty, "suggestions produced", "\(a.suggestions.map(\.title))")
a.suggestions.prefix(4).forEach { print("    · \($0.title)  [\($0.model), \(Int($0.confidence * 100))%]") }
check(a.healthspan != nil, "healthspan computed")
if let h = a.healthspan { print(String(format: "  body age %.1f vs %.0f, pace %@", h.bodyAge, h.chronologicalAge, h.pace.map { String(format: "%.2f", $0) } ?? "–")) }
check(a.stressEnergy != nil, "stress and energy computed for today")
if let s = a.stressEnergy { print(String(format: "  energy now %.0f, high stress %.0f min", s.current ?? -1, s.highStressMinutes)) }
check(a.weekly != nil, "weekly report built")

if let last = a.latest {
    check(last.sleep != nil, "today has a sleep score")
    check(last.sleepNeedTonight > 400 && last.sleepNeedTonight < 600, "sleep need tonight plausible", "\(last.sleepNeedTonight)")
    check(last.bedtimeTonight != nil, "bedtime recommendation present")
    check(last.load.acwr != nil, "ACWR available after 90 days")
}

let episode = (DayKey.addDays(end, -16)...DayKey.addDays(end, -10))
let alcoholMornings = a.orderedKeys.filter { demo.journal[DayKey.addDays($0, -1)]?.factors.contains("alcohol") == true && !episode.contains($0) }
check(alcoholMornings.allSatisfy { a.scores[$0]?.illness.level != .alert }, "alcohol alone never raises a full alert")

print("No-HRV path (Apple Health only)")
var noHRV = demo.days
for k in noHRV.keys { noHRV[k]?.hrvRmssd = nil }
let b = Analyzer.run(days: noHRV, journal: demo.journal, settings: settings, today: end)
check(b.latest?.recovery?.usedHRV == false, "recovery falls back without HRV")
check(b.latest?.recovery != nil, "still produces a score")

print("Ask Claude summary")
let ctx = AskClaudeSummary.build(analysis: a, days: demo.days, settings: settings)
check(ctx.contains("TODAY") && ctx.contains("LAST 14 DAYS"), "summary has sections")
print("  summary ≈ \(ctx.count / 4) tokens")

print("Food")
let foodsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../App/Resources/foods.json").standardized
let db = try! FoodDatabase(json: Data(contentsOf: foodsURL))
check(db.foods.count > 5000, "USDA database loads", "\(db.foods.count)")
check(db.search("scrambled eggs").first.map { $0.name.lowercased().contains("egg") } == true, "search finds eggs", db.search("scrambled eggs").first?.name ?? "none")
check(PortionParser.parse("12 fl oz") == .init(count: 12, words: ["floz"], grams: nil), "parses fluid ounces")
check(PortionParser.parse("150 g").grams == 150, "parses grams")
check(PortionParser.parse("half a cup").count == 0.5, "parses 'half a cup'", "\(PortionParser.parse("half a cup"))")
let milk = db.search("milk whole").first!
let cupMilk = PortionParser.grams(of: milk, amount: "1 cup").grams
check((230...260).contains(cupMilk), "1 cup of milk ≈ 244 g", "\(cupMilk)")
let cola = db.search("soft drink cola").first!
let can = PortionParser.grams(of: cola, amount: "20 fl oz").grams
check((560...650).contains(can), "20 fl oz of cola ≈ 600 g", "\(cola.name) \(can)")
let meal = LoggedMeal(time: Date(), text: "milk", items: [LoggedItem(food: milk, amount: "1 cup", grams: cupMilk)], source: .text)
check(abs(meal.totals.kcal - milk.per100.kcal * cupMilk / 100) < 0.01, "meal totals scale per 100 g")

print("Energy budget")
var bdays: [String: DayRecord] = [:]
let bend = "2026-12-31"
for i in 0..<35 {
    let k = DayKey.addDays(bend, -i)
    var d = DayRecord(date: k)
    // Eats 2,000 a day while losing 0.5 kg/week → true burn ≈ 2,000 + 550 = 2,550.
    d.weightKg = 85 - 0.5 * Double(35 - i) / 7
    d.meals = [Meal(time: DayKey.date(from: k)!, kcal: 2000)]
    d.activeEnergy = 500
    bdays[k] = d
}
var bs = UserSettings(); bs.age = 27; bs.sex = .male; bs.heightCm = 178; bs.goalRateKgPerWeek = -0.75
let budget = EnergyBudget.compute(days: bdays, settings: bs, today: bend)!
check(budget.basis == .learned, "learns burn from 28 logged days", "\(budget.basis)")
check((2350...2750).contains(budget.burnKcal), "learned burn ≈ 2,550", "\(budget.burnKcal)")
check(abs((budget.weeklyRateKg ?? 0) + 0.5) < 0.1, "trend rate ≈ −0.5 kg/week", "\(budget.weeklyRateKg ?? 0)")
check(abs((budget.targetKcal ?? 0) - (budget.burnKcal - 825)) < 1, "target = burn − 825 for −0.75 kg/week")
var noFood = bdays; for k in noFood.keys { noFood[k]?.meals = nil }
check(EnergyBudget.compute(days: noFood, settings: bs, today: bend)?.basis == .estimated, "no logging → formula estimate")

print("Body signals")
var gdays: [String: DayRecord] = [:]
let gend = "2026-12-31"
for i in 0..<40 {
    let k = DayKey.addDays(gend, -i)
    var d = DayRecord(date: k)
    d.walkingAsymmetryPct = i < 3 ? 9 : 2 + Double(i % 3) * 0.3    // jumps for the last three days
    d.doubleSupportPct = 27
    d.walkingSpeed = 1.35
    d.extras = ["HKQuantityTypeIdentifierDistanceWalkingRunning": Double(i % 10)]
    gdays[k] = d
}
let gkeys = DayKey.keys(from: DayKey.addDays(gend, -39), to: gend)
let alert = GaitWatch.check(days: gdays, keys: gkeys)
check(alert?.metric == "Walking asymmetry", "3-day asymmetry jump → gait alert", "\(String(describing: alert))")
var calm = gdays; calm[gend]?.walkingAsymmetryPct = 2
check(GaitWatch.check(days: calm, keys: gkeys) == nil, "two odd days → no alert")
let th = ExtraHabits.thresholds(days: gdays)
check(th["HKQuantityTypeIdentifierDistanceWalkingRunning"] != nil, "walking distance becomes a habit after 2 weeks")
check(ExtraHabits.detect(gdays[DayKey.addDays(gend, -9)]!, thresholds: th).contains("x:HKQuantityTypeIdentifierDistanceWalkingRunning"), "long walking day detected")
check(JournalFactor.named("x:HKQuantityTypeIdentifierDistanceWalkingRunning")?.label == "Long walking day", "habit has a readable name")
let hs = Healthspan.compute(days: demo.days.mapValues { var d = $0; d.walkingSpeed = 1.45; return d }, keys: a.orderedKeys, settings: settings)
check(hs?.contributors.contains { $0.name.hasPrefix("Walking speed") && $0.years < 0 } == true, "brisk walking lowers body age")

print("Store roundtrip")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = Store(directory: dir)
var snap = StoreSnapshot()
snap.days = demo.days
snap.journal = demo.journal
snap.foodLog = [meal]
store.save(snap)
let loaded = store.load()
check(loaded.days.count == demo.days.count && loaded.journal.count == demo.journal.count, "save/load")
check(loaded.foodLog.first?.items.first?.foodID == milk.id, "food log survives save/load")
check(loaded.mergedDays[DayKey.today()]?.meals?.isEmpty == false, "logged meals join the day's data")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
