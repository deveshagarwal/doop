import SwiftUI
import Charts

/// Simulator screenshots: --page <name> opens a sub-page on launch.
enum LaunchArgs {
    static var page: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--page"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
}

struct TrainTab: View {
    var body: some View {
        NavigationStack {
            TrainingPage()
                .navigationDestination(for: TodayPage.self) { page in
                    if case .workout(let d, let id) = page { WorkoutPage(day: d, workoutID: id) } else { StrainPage() }
                }
        }
    }
}

struct TrainingPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        let a = model.analysis
        EmberPage {
            if let t = a.latest {
                let l = t.load
                VStack(alignment: .leading, spacing: 4) {
                    InfoLabel(text: "Training load", accent: true,
                              info: "This week's average training load divided by your last four weeks (the acute:chronic ratio). 0.8–1.3 builds fitness safely; above 1.5 is where injury and illness risk climbs (Gabbett, 2016).")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(l.status.rawValue).font(.ultra(40)).tracking(-1)
                        if let r = l.acwr { Text(String(format: "%.2f", r)).font(.light(22)).foregroundStyle(Ember.bone2) }
                    }
                    Text(l.status.advice).font(.system(size: 13)).foregroundStyle(Ember.bone2)
                }
                if let r = l.acwr { ACWRGauge(value: r * progress).frame(height: 36) }
                Section9(title: "Fitness vs fatigue", info: "Fitness (bone) is your 6-week average load; fatigue (ember) is your 1-week. Fatigue above fitness means you're carrying tiredness; the gap is your form.", trailing: "90 days") {
                    let days = a.recent(90)
                    let shown = Int(Double(days.count) * progress)
                    Chart {
                        ForEach(Array(days.prefix(max(shown, 2)).enumerated()), id: \.offset) { _, s in
                            let d = DayKey.date(from: s.date) ?? Date()
                            LineMark(x: .value("Day", d), y: .value("Load", s.load.chronic), series: .value("S", "Fitness")).foregroundStyle(Ember.bone)
                            LineMark(x: .value("Day", d), y: .value("Load", s.load.acute), series: .value("S", "Fatigue")).foregroundStyle(Ember.ember)
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.mono(8.5)) } }
                    .chartYAxis(.hidden)
                    .frame(height: 150)
                    Trio(items: [("Fitness", "\(Int(l.chronic))", nil), ("Fatigue", "\(Int(l.acute))", nil),
                                 ("Form", Fmt.signed(l.form), l.form >= 0 ? "fresh" : "loaded")])
                }
                Section9(title: "Weekly strain", trailing: "13 weeks") {
                    let weeks = weeklyStrain(a)
                    Chart(Array(weeks.enumerated()), id: \.offset) { i, v in
                        BarMark(x: .value("Week", i), y: .value("Strain", v * progress))
                            .foregroundStyle(i == weeks.count - 1 ? Ember.ember : Ember.bone.opacity(0.32)).cornerRadius(3)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 70)
                }
                if let c = a.costPerStrain {
                    Section9(title: "What workouts cost you", info: "Learned from your history: how much your next-morning recovery tends to drop for each point of strain the day before.") {
                        Text(String(format: "Each point of strain costs about %.1f recovery points the next morning.", -c)).font(.system(size: 14))
                        Text(String(format: "A hard day (strain 14) leaves you about %.0f points lower than an easy one (strain 4).", -c * 10)).font(.mono(10.5, .semibold)).foregroundStyle(Ember.ember)
                    }
                }
                Section9(title: "Recent workouts") {
                    let all = a.recent(30).reversed().flatMap { s in s.workouts.map { (s.date, $0) } }
                    if all.isEmpty { Text("No workouts in the last 30 days.").font(.system(size: 13)).foregroundStyle(Ember.bone2) }
                    ForEach(all.prefix(15), id: \.1.id) { day, w in WorkoutRow(day: day, workout: w) }
                }
            }
        }
        .modifier(DrawIn(progress: $progress))
    }

    private func weeklyStrain(_ a: Analysis) -> [Double] {
        let days = a.recent(91)
        return stride(from: 0, to: days.count, by: 7).map { i in days[i..<min(i + 7, days.count)].map(\.strain.strain).reduce(0, +) }
    }
}

struct ACWRGauge: View {
    let value: Double
    private let lo = 0.4, hi = 2.0
    var body: some View {
        GeometryReader { g in
            let x = { (v: Double) in CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * g.size.width }
            ZStack(alignment: .topLeading) {
                ForEach([(0.4, 0.8, 0.12), (0.8, 1.3, 0.55), (1.3, 1.5, 0.25), (1.5, 2.0, 0.08)], id: \.0) { a, b, o in
                    Capsule().fill((a == 0.8 || a == 1.3) ? Ember.ember.opacity(o) : Ember.bone.opacity(o))
                        .frame(width: x(b) - x(a) - 2, height: 5).offset(x: x(a), y: 6)
                }
                ForEach([0.8, 1.3, 1.5], id: \.self) { v in
                    Text(String(format: "%.1f", v)).font(.mono(8.5)).foregroundStyle(Ember.bone3).position(x: x(v), y: 26)
                }
                Circle().fill(Ember.bone).frame(width: 13, height: 13).shadow(color: Ember.ember, radius: 6).offset(x: x(value) - 6.5, y: 2)
            }
        }
        .accessibilityLabel(String(format: "Load ratio %.2f", value))
    }
}

struct WorkoutPage: View {
    @Environment(AppModel.self) private var model
    let day: String
    let workoutID: String
    @State private var progress = 0.0

    var body: some View {
        let w = model.analysis.scores[day]?.workouts.first { $0.id == workoutID }
        let samples = w.map { w in (model.record(day)?.hrSamples ?? []).filter { $0.t >= w.start && $0.t <= w.end } } ?? []
        EmberPage {
            if let w {
                PageHero(label: "\(w.name) · \(Int(w.durationMinutes)) min", info: "Strain for this session alone, from your heart rate during it.",
                         value: w.strain ?? 0, decimals: 1, unit: "strain",
                         caption: [w.averageHR.map { "avg \(Int($0))" }, samples.map(\.bpm).max().map { "max \(Int($0)) bpm" }, w.calories.map { "\(Int($0)) kcal" }]
                            .compactMap { $0 }.joined(separator: " · ") + " · " + Fmt.dayTitle(day))
                if samples.count > 3 {
                    let rest = model.record(day)?.restingHR ?? 60, maxHR = model.settings.maxHR
                    Chart {
                        ForEach(Array(StrainEngine.zoneBounds.enumerated()), id: \.offset) { i, lo in
                            let hi = i + 1 < StrainEngine.zoneBounds.count ? StrainEngine.zoneBounds[i + 1] : 1.05
                            RectangleMark(yStart: .value("lo", rest + lo * (maxHR - rest)), yEnd: .value("hi", rest + hi * (maxHR - rest)))
                                .foregroundStyle(Ember.ember.opacity(0.03 + Double(i) * 0.035))
                        }
                        ForEach(samples.prefix(max(2, Int(Double(samples.count) * progress))), id: \.t) { s in
                            LineMark(x: .value("Time", s.t), y: .value("BPM", s.bpm)).foregroundStyle(Ember.bone).interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.mono(8.5)) } }
                    .chartYAxis { AxisMarks(position: .trailing) { _ in AxisValueLabel().font(.mono(8.5)) } }
                    .frame(height: 170)
                    .modifier(DrawIn(progress: $progress))
                    Section9(title: "Time in zones", info: "Zones are shares of your heart-rate reserve (between resting and max). Higher zones count far more toward strain.") {
                        let zones = zoneMinutes(samples, rest: rest, maxHR: maxHR)
                        let total = max(zones.reduce(0, +), 1)
                        VStack(spacing: 0) {
                            ForEach(Array(StrainEngine.zoneLabels.enumerated()), id: \.offset) { i, label in
                                MetricRow(name: label, value: "\(Int(zones[i])) min", fraction: zones[i] / total, accent: i >= 2)
                            }
                        }
                    }
                }
                if let c = model.analysis.costPerStrain, let s = w.strain {
                    GlassCard {
                        HStack {
                            InfoLabel(text: "Predicted cost tomorrow", info: "How many recovery points sessions like this usually take from your next morning, learned from your past workouts.")
                            Spacer()
                            Text(String(format: "%.0f", c * s)).font(.light(22)).foregroundStyle(Ember.ember)
                        }
                    }
                }
            }
        }
    }

    private func zoneMinutes(_ samples: [HRSample], rest: Double, maxHR: Double) -> [Double] {
        var z = Array(repeating: 0.0, count: StrainEngine.zoneBounds.count)
        for s in samples {
            let hrr = (s.bpm - rest) / max(maxHR - rest, 40)
            if let i = StrainEngine.zoneBounds.lastIndex(where: { hrr >= $0 }) { z[i] += 1 }
        }
        return z
    }
}
