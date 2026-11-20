import SwiftUI
import Charts

enum TodayPage: Hashable { case recovery, strain, sleep, tonight, forYou, glossary, workout(String, String) }

struct TodayTab: View {
    @Environment(AppModel.self) private var model
    @State private var path: [TodayPage] = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--page"), i + 1 < args.count else { return [] }
        return [["recovery": .recovery, "strain": .strain, "sleep": .sleep, "tonight": .tonight, "foryou": .forYou][args[i + 1]]].compactMap { $0 }
    }()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.hasAnyData { Onboarding(showSettings: $showSettings) }
                else if let t = model.today { Home(day: t, showSettings: $showSettings) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Ember.ink) }
            }
            .navigationDestination(for: TodayPage.self) { todayDestination($0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

/// Today's deep dives, also reachable from Learn (For you) and Fuel.
@ViewBuilder func todayDestination(_ page: TodayPage) -> some View {
    switch page {
    case .recovery: RecoveryPage()
    case .strain: StrainPage()
    case .sleep: SleepPage()
    case .tonight: TonightPlanner()
    case .forYou: ForYouPage()
    case .glossary: GlossaryPage()
    case .workout(let day, let id): WorkoutPage(day: day, workoutID: id)
    }
}

// MARK: Home

struct Home: View {
    @Environment(AppModel.self) private var model
    let day: DayScore
    @Binding var showSettings: Bool

    var body: some View {
        let bpm = model.record(day.date)?.restingHR ?? 60
        ZStack {
            GlassOrbView(bpm: bpm)
            VStack(spacing: 0) {
                HStack {
                    Label9(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    Spacer()
                    Text(day.illness.level == .clear ? "● all clear" : "● \(day.illness.level.title.lowercased())")
                        .font(.mono(9.5, .semibold)).foregroundStyle(Ember.ember)
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium))
                            .frame(width: 34, height: 34).glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain).padding(.leading, 6).accessibilityLabel("Settings")
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                if day.recovery != nil {
                    if let q = model.analysis.question { QuestionCard(question: q).padding(.bottom, 14) }
                    Text(verdict).font(.system(size: 14.5)).foregroundStyle(Ember.bone2).multilineTextAlignment(.center)
                }
                heroes.padding(.top, 22)

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
            .foregroundStyle(Ember.bone)
        }
        .modifier(HeartbeatHaptics(bpm: bpm))
        .toolbar(.hidden, for: .navigationBar)
    }

    private var verdict: AttributedString {
        guard let r = day.recovery else { return "Waiting for last night's data." }
        let target = day.strainTarget.map { String(format: "%.1f", $0) } ?? "–"
        var s: AttributedString
        switch r.zone {
        case .green: s = AttributedString("Recovered. ")
        case .yellow: s = AttributedString("Steady. ")
        case .red: s = AttributedString("Run down. ")
        }
        s.foregroundColor = Ember.bone
        var rest = AttributedString(r.zone == .red ? "Make today a recovery day." : "Ready for a \(target) strain day.")
        rest.foregroundColor = Ember.bone2
        return s + rest
    }

    private var heroes: some View {
        HStack(spacing: 0) {
            HeroNumber(page: .recovery, label: "Recovery", value: day.recovery.map { Double($0.score) }, decimals: 0, unit: "%",
                       note: day.recovery.map { Ember.zoneWord($0.zone) } ?? "after tonight")
            divider
            HeroNumber(page: .strain, label: "Strain", value: day.strain.strain, decimals: 1, unit: nil,
                       note: day.strainTarget.map { String(format: "of %.1f", $0) } ?? "–")
            divider
            HeroNumber(page: .sleep, label: "Sleep", value: day.sleep?.performance, decimals: 0, unit: "%",
                       note: day.sleep.map { Fmt.hm($0.asleepMinutes) } ?? "no data")
        }
    }

    private var divider: some View { Rectangle().fill(Ember.hair).frame(width: 1, height: 70) }
}

struct HeroNumber: View {
    let page: TodayPage
    let label: String
    let value: Double?
    let decimals: Int
    let unit: String?
    let note: String

    var body: some View {
        NavigationLink(value: page) {
            VStack(spacing: 3) {
                Label9(label)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if let value {
                        CountUp(value: value, decimals: decimals, font: .ultra(44))
                    } else {
                        Text("–").font(.ultra(44)).foregroundStyle(Ember.bone3)
                    }
                    if let unit, value != nil { Text(unit).font(.light(14)).foregroundStyle(Ember.bone3) }
                }
                Text(note + " ›").font(.mono(10, .semibold)).foregroundStyle(Ember.ember)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(value.map { String(format: "%.\(decimals)f", $0) + (unit ?? "") } ?? "not yet"), \(note). Opens details.")
    }
}

/// The one optional yes/no of the day.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let question: DailyQuestion

    var body: some View {
        GlassCard {
            HStack {
                InfoLabel(text: "One question", accent: true,
                          info: "Some things leave only a guess in the data. Alcohol keeps your heart rate high for hours after you fall asleep, but so can a late workout, so the app asks once instead of assuming. You can also answer from the morning notification.")
                Spacer()
            }
            Text(question.prompt).font(.system(size: 14, weight: .medium))
            Text(question.evidence).font(.system(size: 11.5)).foregroundStyle(Ember.bone2)
            HStack(spacing: 8) {
                ChipButton(title: "Yes") { model.answer(question, yes: true) }
                ChipButton(title: "No") { model.answer(question, yes: false) }
                ChipButton(title: "Skip") { model.answer(question, yes: nil) }
            }
            .padding(.top, 4)
        }
    }
}

struct ChipButton: View {
    let title: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Ember.ink : Ember.bone)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? AnyShapeStyle(Ember.bone) : AnyShapeStyle(Ember.glass), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.06)))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }
}

// MARK: Recovery

struct RecoveryPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        EmberPage {
            if let t = model.today {
                let forecast = model.analysis.habits.flatMap { model.analysis.forecastTomorrow(bedtime: $0.typicalBedtime) }
                PageHero(label: "Recovery",
                         info: "How ready your body is today, 1–99%. It compares last night's HRV, resting heart rate, sleep and breathing with your own last 30 days. 67+ is primed, 34–66 steady, under 34 run down.",
                         value: Double(t.recovery?.score ?? 0), unit: "%",
                         caption: "\(Ember.zoneWord(t.recovery?.zone).capitalized)" + (forecast.map { " · tomorrow forecast \(Int($0)) ±\(Int(model.analysis.forecast?.backtestError ?? 0))" } ?? ""))
                if let r = t.recovery {
                    VStack(spacing: 0) {
                        ForEach(r.contributors) { c in
                            MetricRow(name: c.name, info: info(c.name), value: c.value,
                                      delta: c.z.map { z in (c.name == "Resting HR" ? (z < 0 ? "▼" : "▲") : (z >= 0 ? "▲" : "▼")) + String(format: "%.1fσ", abs(z)) },
                                      fraction: c.score / 100, accent: c.score >= 67)
                        }
                    }
                    ForEach(r.notes, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Ember.bone2) }
                }
                Section9(title: "Last 30 days") {
                    let days = model.analysis.recent(30).filter { $0.recovery != nil }
                    Chart(days, id: \.date) { s in
                        BarMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day),
                                y: .value("Recovery", Double(s.recovery?.score ?? 0) * progress))
                            .foregroundStyle(s.date == t.date ? Ember.ember : Ember.bone.opacity((s.recovery?.score ?? 0) < 34 ? 0.2 : 0.42))
                            .cornerRadius(2)
                    }
                    .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 90)
                    .modifier(DrawIn(progress: $progress))
                }
                Section9(title: "Illness watch", info: IllnessInfo.text) {
                    Text(t.illness.level.title).font(.light(22))
                    Text(t.illness.message).font(.system(size: 12.5)).foregroundStyle(Ember.bone2)
                }
            }
        }
    }

    private func info(_ name: String) -> String? {
        switch name {
        case "HRV": return "Heart rate variability: tiny variations between heartbeats while you sleep. Higher than your normal usually means your nervous system has recovered. The biggest input to recovery."
        case "Resting HR": return "Your lowest steady heart rate overnight. Lower than normal is good; a jump of 3+ bpm often means stress, alcohol or illness."
        case "Respiratory rate": return "Breaths per minute while asleep. Very stable night to night, so a rise often shows up early in an illness. It can only lower the score."
        case "Sleep": return "Hours slept as a share of what you needed last night."
        default: return nil
        }
    }
}

enum IllnessInfo {
    static let text = "Flags when several overnight signals drift from your normal together: heart rate up, HRV down, breathing or skin temperature up. One odd night is often noise, so a full alert needs two nights in a row. Tested on 71 real Fitbit users: about 3 alerts a year."
}

// MARK: Strain

struct StrainPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        EmberPage {
            if let t = model.today {
                PageHero(label: "Strain",
                         info: "How hard your heart worked today on a 0–21 scale. It's logarithmic: going from 10 to 14 takes far more effort than 2 to 6. The target comes from your recovery and how fast your training load is rising.",
                         value: t.strain.strain, decimals: 1, unit: t.strainTarget.map { String(format: "/ %.1f", $0) },
                         caption: (t.strainTarget.map { String(format: "%.1f to go · ", max(0, $0 - t.strain.strain)) } ?? "") + "load \(t.load.status.rawValue.lowercased())")
                StrainDial(strain: t.strain.strain * progress, target: t.strainTarget, samples: model.record(t.date)?.hrSamples ?? [])
                    .frame(height: 250).modifier(DrawIn(progress: $progress))
                let week = model.analysis.recent(7).map(\.strain.strain).reduce(0, +)
                Trio(items: [("Peak HR", t.strain.peakHR.map { "\(Int($0))" } ?? "–", "bpm"),
                             ("Zone 2+", Fmt.hm(t.strain.zoneMinutes.dropFirst().reduce(0, +)), "active"),
                             ("7 days", String(format: "%.1f", week), nil)])
                if !t.workouts.isEmpty {
                    Section9(title: "Workouts today") {
                        ForEach(t.workouts) { w in WorkoutRow(day: t.date, workout: w) }
                    }
                }
            }
        }
    }
}

struct StrainDial: View {
    let strain: Double
    let target: Double?
    let samples: [HRSample]

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height * 0.52), r = min(size.width, size.height) * 0.38
            let a0 = Angle.degrees(135), sweep = 270.0
            func angle(_ v: Double) -> Angle { .degrees(135 + sweep * v / 21) }
            func pt(_ a: Angle, _ rr: CGFloat) -> CGPoint { CGPoint(x: c.x + CGFloat(cos(a.radians)) * rr, y: c.y + CGFloat(sin(a.radians)) * rr) }
            var track = Path(); track.addArc(center: c, radius: r, startAngle: a0, endAngle: angle(21), clockwise: false)
            ctx.stroke(track, with: .color(Ember.hair), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for i in 0...21 {
                var tick = Path(); tick.move(to: pt(angle(Double(i)), r + 7)); tick.addLine(to: pt(angle(Double(i)), r + (i % 7 == 0 ? 15 : 11)))
                ctx.stroke(tick, with: .color(Ember.bone.opacity(i % 7 == 0 ? 0.4 : 0.14)), lineWidth: 1)
            }
            if let target {
                var tgt = Path(); tgt.addArc(center: c, radius: r, startAngle: a0, endAngle: angle(target), clockwise: false)
                ctx.stroke(tgt, with: .color(Ember.ember.opacity(0.22)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: pt(angle(target), r).x - 3.5, y: pt(angle(target), r).y - 3.5, width: 7, height: 7)), with: .color(Ember.bone))
                ctx.draw(Text("TARGET").font(.mono(8.5)).foregroundStyle(Ember.bone2), at: pt(angle(target), r + 26))
            }
            var arc = Path(); arc.addArc(center: c, radius: r, startAngle: a0, endAngle: angle(max(strain, 0.05)), clockwise: false)
            var glow = ctx
            glow.addFilter(.shadow(color: Ember.ember, radius: 6))
            glow.stroke(arc, with: .color(Ember.ember), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // Heart rate since midnight inside the dial.
            if samples.count > 10 {
                let lo = 45.0, hi = max(samples.map(\.bpm).max() ?? 120, 100)
                var line = Path()
                let start = samples.first!.t, span = max(samples.last!.t.timeIntervalSince(start), 1)
                for (i, s) in samples.enumerated() where i % 3 == 0 {
                    let p = CGPoint(x: c.x - r * 0.62 + s.t.timeIntervalSince(start) / span * r * 1.24, y: c.y + r * 0.28 - (s.bpm - lo) / (hi - lo) * r * 0.6)
                    i == 0 ? line.move(to: p) : line.addLine(to: p)
                }
                ctx.stroke(line, with: .color(Ember.bone2), lineWidth: 1)
                ctx.draw(Text("HEART RATE SINCE MIDNIGHT").font(.mono(8.5)).foregroundStyle(Ember.bone3), at: CGPoint(x: c.x, y: c.y + r * 0.5))
            }
        }
        .accessibilityLabel(String(format: "Strain %.1f of 21%@", strain, target.map { String(format: ", target %.1f", $0) } ?? ""))
    }
}

struct WorkoutRow: View {
    let day: String
    let workout: Workout
    var body: some View {
        NavigationLink(value: TodayPage.workout(day, workout.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.name).font(.system(size: 14, weight: .medium))
                    Text("\(Fmt.dayTitle(day)) · \(Int(workout.durationMinutes)) min" + (workout.averageHR.map { " · avg \(Int($0))" } ?? ""))
                        .font(.system(size: 11.5)).foregroundStyle(Ember.bone2)
                }
                Spacer()
                Text(workout.strain.map { String(format: "%.1f", $0) } ?? "–").font(.light(20)).foregroundStyle(Ember.ember)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Ember.bone3)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Tonight planner

struct TonightPlanner: View {
    @Environment(AppModel.self) private var model
    @State private var bedtime: Double = 5
    @State private var extra: Set<String> = []
    @State private var removed: Set<String> = []
    @State private var ready = false

    private let toggles: [(String, String)] = [("alcohol", "Have a drink"), ("late_meal", "Eat late"), ("late_caffeine", "Late coffee"), ("late_workout", "Train late")]

    var body: some View {
        let a = model.analysis
        EmberPage {
            if let f = a.forecast, let h = a.habits {
                let value = a.forecastTomorrow(bedtime: bedtime, extra: extra, removed: removed) ?? 0
                let hours = a.plannedSleepHours(bedtime: bedtime) ?? 0
                PageHero(label: "Tomorrow's recovery",
                         info: String(format: "A model trained only on your own %d nights predicts tomorrow's recovery from tonight's choices. On your past nights it was off by ±%.0f points on average, %.0f%% better than guessing 'same as today'. It retrains every time new data arrives, on the phone.", f.trainedOn, f.backtestError, f.beatsNaiveBy * 100),
                         value: value, unit: "%",
                         caption: String(format: "±%.0f · %@ of sleep before a %@ wake", f.backtestError, Fmt.hm(hours * 60), Suggestions.clockLabel(h.typicalWake)))
                Chart {
                    ForEach(Array(stride(from: h.typicalBedtime - 1.5, through: h.typicalBedtime + 2, by: 0.25)), id: \.self) { b in
                        LineMark(x: .value("Bedtime", b), y: .value("Forecast", a.forecastTomorrow(bedtime: b, extra: extra, removed: removed) ?? 0))
                            .foregroundStyle(Ember.bone2).interpolationMethod(.monotone)
                    }
                    RuleMark(x: .value("Now", bedtime)).foregroundStyle(Ember.hair)
                    PointMark(x: .value("Now", bedtime), y: .value("Forecast", value)).foregroundStyle(Ember.ember).symbolSize(70)
                }
                .chartXAxis { AxisMarks(values: .stride(by: 1)) { v in AxisValueLabel { if let b = v.as(Double.self) { Text(Suggestions.clockLabel(b)).font(.mono(8.5)) } } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.mono(8.5)) } }
                .chartXScale(domain: (h.typicalBedtime - 1.5)...(h.typicalBedtime + 2))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Label9("Lights out"); Spacer(); Text(Suggestions.clockLabel(bedtime)).font(.mono(11, .semibold)) }
                    Slider(value: $bedtime, in: (h.typicalBedtime - 1.5)...(h.typicalBedtime + 2), step: 1.0 / 12).tint(Ember.ember)
                        .sensoryFeedback(.selection, trigger: Int(bedtime * 12))
                }
                Section9(title: "Tonight I'll", info: "Each habit's effect is learned from your own history. Only habits that happened at least 5 times change the forecast.") {
                    FlowChips(items: toggles.filter { model.hasMealData || !["late_meal", "late_caffeine"].contains($0.0) }, isOn: { id in (model.today?.factors.contains(id) ?? false || extra.contains(id)) && !removed.contains(id) }) { id in
                        let on = (model.today?.factors.contains(id) ?? false || extra.contains(id)) && !removed.contains(id)
                        if on { extra.remove(id); removed.insert(id) } else { removed.remove(id); extra.insert(id) }
                    }
                }
            } else {
                PageHero(label: "Tomorrow's recovery", value: 0, caption: "The forecast appears after about 3 weeks of nights.")
            }
        }
        .onAppear { if !ready, let h = model.analysis.habits { bedtime = h.typicalBedtime; ready = true } }
    }
}

struct FlowChips: View {
    let items: [(String, String)]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { id, label in ChipButton(title: label, on: isOn(id)) { toggle(id) } }
        }
    }
}

// MARK: For you

struct ForYouPage: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        EmberPage {
            HStack {
                InfoLabel(text: "For you", accent: true, info: "Suggestions ranked by how many recovery points they're likely to gain you, times how sure the model behind each one is. No language model: each card comes from a specific statistical model trained on your data on this phone.")
                Spacer()
                Label9("updated " + model.analysis.computedAt.formatted(date: .omitted, time: .shortened))
            }
            if model.analysis.suggestions.isEmpty {
                Text("Nothing stands out today. Suggestions appear as patterns emerge in your data.").font(.system(size: 14)).foregroundStyle(Ember.bone2)
            }
            ForEach(Array(model.analysis.suggestions.enumerated()), id: \.element.id) { i, s in
                NavigationLink(value: s.kind == .bedtime || s.kind == .debt ? TodayPage.tonight : TodayPage.recovery) {
                    GlassCard {
                        Text(s.title).font(.system(size: 14.5, weight: .medium)).multilineTextAlignment(.leading)
                        Text(s.why).font(.system(size: 12)).foregroundStyle(Ember.bone2).multilineTextAlignment(.leading)
                        HStack { Label9(s.model); Spacer(); ConfidenceBars(value: s.confidence) }.padding(.top, 4)
                    }
                }
                .buttonStyle(.plain)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
                .animation(.easeOut(duration: 0.5).delay(Double(i) * 0.08), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

// MARK: Glossary

struct GlossaryPage: View {
    private let entries: [(String, String)] = [
        ("Recovery", "How ready your body is today, 1–99%. It compares last night's HRV, resting heart rate, sleep and breathing with your own last 30 days. 67+ is primed, 34–66 steady, under 34 run down."),
        ("Strain", "How hard your heart worked today on a 0–21 scale. It's logarithmic: going from 10 to 14 takes far more effort than 2 to 6."),
        ("Strain target", "How much strain today's recovery can absorb. Lower when recovery is low or your training load has jumped."),
        ("HRV", "Heart rate variability: tiny variations between heartbeats while you sleep. Higher than your normal usually means your nervous system has recovered."),
        ("Resting heart rate", "Your lowest steady heart rate overnight. A rise of 3+ bpm over your normal often means stress, alcohol or illness."),
        ("Sleep need", "Your base need, plus part of any sleep debt, plus extra after a hard day."),
        ("Sleep debt", "Sleep you've missed recently against your base need. It fades by about 30% a day, so it reflects the past week, not the past year."),
        ("Nightlines", "Each hill is one night of heart rate, on a clock axis: it starts when you fell asleep and ends when you woke. Taller means your heart rate dropped further."),
        ("Training load", "This week's average load divided by your last four weeks. 0.8–1.3 builds fitness safely; above 1.5 is where injury and illness risk climbs."),
        ("Fitness and fatigue", "Fitness is your 6-week average load, fatigue your 1-week. The gap between them is your form."),
        ("Energy bank", "Starts the morning at your recovery level. Exercise and stress drain it; sleep, naps and calm stretches refill it."),
        ("Stress", "Minutes your heart rate was well above your calm baseline while you weren't moving. It can't tell excitement from worry."),
        ("Illness watch", "Flags when several overnight signals drift from your normal together. A full alert needs two nights in a row."),
        ("Body age", "What age your fitness, resting heart rate, activity and sleep look like against published norms. A rough guide, not a medical test."),
        ("Pace of aging", "How many years your body age moves per calendar year. 1.0× is average; lower is slower. Needs about 4 months of data."),
        ("Habit effects", "How your next morning differs after a habit, holding your other habits, strain and bedtime steady. Ember means solid; grey could be chance."),
        ("Forecast", "Tomorrow's recovery predicted from tonight's choices, by a model trained only on your nights. Appears after about 3 weeks."),
    ]

    var body: some View {
        EmberPage {
            Label9("What everything means", accent: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.0) { name, text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 15, weight: .medium))
                        Text(text).font(.system(size: 13)).foregroundStyle(Ember.bone2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: Onboarding

struct Onboarding: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    var body: some View {
        EmberPage {
            Spacer(minLength: 60)
            Text("DOOP").font(.ultra(48)).tracking(4)
            Text("Recovery, strain, sleep and early illness signals from your Fitbit Air, scored against your own baseline. Nothing to log. Everything stays on this phone.")
                .font(.system(size: 15)).foregroundStyle(Ember.bone2)
            GlassCard {
                Label9("Step 1", accent: true)
                Text("In the Google Health app: Connections → Apps and services → Apple Health. Turn sharing on.").font(.system(size: 14))
            }
            Button { Task { await model.connectAppleHealth() } } label: {
                Text("Connect Apple Health").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent).tint(Ember.ember)
            Button("Explore with demo data") { model.updateSettings { $0.demoMode = true } }.foregroundStyle(Ember.bone2)
            Button("More sources in Settings") { showSettings = true }.font(.system(size: 13)).foregroundStyle(Ember.bone3)
        }
    }
}
