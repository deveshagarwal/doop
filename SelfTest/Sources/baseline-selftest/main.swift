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

print("End-to-end on 90 demo days")
let end = "2026-11-19"
let demo = DemoData.generate(days: 90, endingOn: end)
var settings = UserSettings()
settings.age = 28
settings.sex = .male
let t0 = Date()
let a = Analyzer.run(days: demo.days, journal: demo.journal, factors: JournalFactor.defaults, settings: settings, today: end)
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

let alcohol = a.insights.first { $0.factor.id == "alcohol" && $0.outcome == "Recovery" }
check(alcohol != nil && alcohol!.difference < -5 && alcohol!.strength == .solid, "alcohol hurts next-day recovery (solid)",
      alcohol.map { String(format: "%+.1f t=%.1f", $0.difference, $0.t) } ?? "missing")
let sunlight = a.insights.first { $0.factor.id == "sunlight_am" && $0.outcome == "Recovery" }
check(sunlight == nil || sunlight!.strength != .solid, "no-effect factor isn't called solid",
      sunlight.map { String(format: "%+.1f t=%.1f", $0.difference, $0.t) } ?? "")

if let last = a.latest {
    check(last.sleep != nil, "today has a sleep score")
    check(last.sleepNeedTonight > 400 && last.sleepNeedTonight < 600, "sleep need tonight plausible", "\(last.sleepNeedTonight)")
    check(last.bedtimeTonight != nil, "bedtime recommendation present")
    check(last.load.acwr != nil, "ACWR available after 90 days")
}

let alcoholMornings = a.orderedKeys.filter { demo.journal[DayKey.addDays($0, -1)]?.factors.contains("alcohol") == true }
check(alcoholMornings.allSatisfy { a.scores[$0]?.illness.level != .alert }, "alcohol alone never raises a full alert")

print("No-HRV path (Apple Health only)")
var noHRV = demo.days
for k in noHRV.keys { noHRV[k]?.hrvRmssd = nil }
let b = Analyzer.run(days: noHRV, journal: demo.journal, factors: JournalFactor.defaults, settings: settings, today: end)
check(b.latest?.recovery?.usedHRV == false, "recovery falls back without HRV")
check(b.latest?.recovery != nil, "still produces a score")

print("Coach context")
let ctx = CoachContext.build(analysis: a, days: demo.days, journal: demo.journal, factors: JournalFactor.defaults, settings: settings)
check(ctx.contains("Recovery") && ctx.contains("30-DAY BASELINES"), "context has sections")
print("  context ≈ \(ctx.count / 4) tokens")

print("Store roundtrip")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = Store(directory: dir)
var snap = StoreSnapshot()
snap.days = demo.days
snap.journal = demo.journal
store.save(snap)
let loaded = store.load()
check(loaded.days.count == demo.days.count && loaded.journal.count == demo.journal.count, "save/load")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
