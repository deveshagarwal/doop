import SwiftUI
import Charts

enum LearnPage: Hashable { case forYou, effects, discoveries, explorer, patterns, weekly, glossary }

struct LearnTab: View {
    @State private var path: [LearnPage] = LaunchArgs.page.flatMap { ["foryou": LearnPage.forYou, "effects": LearnPage.effects, "discoveries": .discoveries, "explorer": .explorer, "patterns": .patterns, "weekly": .weekly][$0] }.map { [$0] } ?? []
    var body: some View {
        NavigationStack(path: $path) {
            LearnHome()
                .navigationDestination(for: LearnPage.self) { p in
                    switch p {
                    case .forYou: ForYouPage()
                    case .effects: EffectsPage()
                    case .discoveries: DiscoveriesPage()
                    case .explorer: ExplorerPage()
                    case .patterns: PatternsPage()
                    case .weekly: WeeklyPage()
                    case .glossary: GlossaryPage()
                    }
                }
                .navigationDestination(for: TodayPage.self) { todayDestination($0) }
        }
    }
}

struct LearnHome: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmberPage {
            DayLog()
            VStack(spacing: 10) {
                LearnLink(page: .forYou, title: "For you", detail: model.analysis.suggestions.first?.title ?? "Suggestions from your own data")
                LearnLink(page: .effects, title: "What moves you", detail: "Each habit's effect on your next morning")
                LearnLink(page: .discoveries, title: "Discoveries", detail: "\(model.analysis.effects.filter(\.isSolid).count) solid patterns found in your history")
                LearnLink(page: .explorer, title: "Explorer", detail: "Any metric against any other")
                LearnLink(page: .patterns, title: "Patterns", detail: "Calendar, weekday rhythm, distributions")
                LearnLink(page: .glossary, title: "What everything means", detail: "Every score and term, in plain words")
                LearnLink(page: .weekly, title: "Weekly report", detail: model.analysis.weekly.map { String(format: "Last week averaged %.0f%%", $0.averageRecovery) } ?? "After your first full week")
            }
            ShareLink(item: model.askClaudeText) {
                HStack {
                    Text("Ask Claude about your data").font(.system(size: 12.5))
                    Spacer()
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11))
                }
                .foregroundStyle(Ember.bone3)
            }
            .padding(.top, 6)
            .accessibilityHint("Shares a summary of your numbers with your Claude app")
        }
    }
}

struct LearnLink: View {
    let page: LearnPage
    let title: String
    let detail: String
    var body: some View {
        NavigationLink(value: page) {
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .medium))
                        Text(detail).font(.system(size: 12)).foregroundStyle(Ember.bone2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Ember.bone3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Day log

struct DayLog: View {
    @Environment(AppModel.self) private var model
    @State private var offset = 0
    @State private var shown = false

    var body: some View {
        let key = DayKey.addDays(model.analysis.latestKey ?? DayKey.today(), -offset)
        let factors = model.analysis.scores[key]?.factors ?? []
        let events = model.record(key).map { AutoLog.events(day: $0, factors: factors) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                InfoLabel(text: "Day log · automatic", accent: true,
                          info: "Nothing to fill in. Each line comes from data you already create: meals and coffee from any food app that writes to Apple Health, weight from Omada, workouts and overnight heart rate from your band, meetings from Calendar, weather for your area, time zone changes for travel, mindful minutes from Apple Health. Long-press a line to correct it.")
                Spacer()
                Button { offset += 1 } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                Text(Fmt.dayTitle(key)).font(.mono(10.5, .semibold)).frame(minWidth: 70)
                Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }.disabled(offset == 0).accessibilityLabel("Next day")
            }
            .font(.system(size: 12, weight: .semibold)).tint(Ember.bone2)
            if offset == 0, let q = model.analysis.question { QuestionCard(question: q) }
            if events.isEmpty {
                Text("Nothing detected for this day yet.").font(.system(size: 13)).foregroundStyle(Ember.bone2)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                    HStack(alignment: .top, spacing: 10) {
                        Text(e.time.formatted(date: .omitted, time: .shortened)).font(.mono(9.5)).foregroundStyle(Ember.bone3).frame(width: 56, alignment: .leading)
                        Circle().fill(e.factor != nil ? Ember.ember : Ember.bone3).frame(width: 7, height: 7).padding(.top, 4)
                            .shadow(color: e.factor != nil ? Ember.ember : .clear, radius: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.system(size: 13))
                            Text(e.source.uppercased()).font(.mono(8.5)).tracking(1).foregroundStyle(Ember.bone3)
                        }
                    }
                    .padding(.vertical, 6)
                    .opacity(shown ? 1 : 0).offset(x: shown ? 0 : -8)
                    .animation(.easeOut(duration: 0.45).delay(Double(i) * 0.06), value: shown)
                    .contextMenu {
                        if let f = e.factor {
                            Button("That's wrong: no \(JournalFactor.named(f)?.label.lowercased() ?? f)") { model.setFactor(f, on: key, present: false) }
                        }
                    }
                }
            }
            let flagged = factors.compactMap(JournalFactor.named)
            if !flagged.isEmpty {
                Text("Counted for tomorrow: " + flagged.map { $0.label.lowercased() }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Ember.bone2)
            }
        }
        .onAppear { shown = true }
        .onChange(of: offset) { shown = false; withAnimation { shown = true } }
    }
}

// MARK: What moves you

struct EffectsPage: View {
    @Environment(AppModel.self) private var model
    @State private var outcome: HabitEffect.Outcome = .recovery

    var body: some View {
        let effects = model.analysis.effects.filter { $0.outcome == outcome }.sorted { $0.effect > $1.effect }
        let scale = max(effects.map { abs($0.effect) + $0.ci }.max() ?? 10, 4)
        EmberPage {
            InfoLabel(text: "Effect on tomorrow", accent: true,
                      info: "Each dot is how much higher or lower your next morning is after that habit, compared with mornings without it, holding your other habits, strain and bedtime steady. The line is the uncertainty: if it crosses the middle, the effect could be zero. Ember dots are solid.")
            Picker("Outcome", selection: $outcome) {
                ForEach(HabitEffect.Outcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if effects.isEmpty {
                Text("Needs at least 5 days with and 5 without a habit. Keep wearing the band; this fills in on its own.").font(.system(size: 13)).foregroundStyle(Ember.bone2)
            }
            VStack(spacing: 0) {
                ForEach(effects) { e in ForestRow(effect: e, scale: scale, unit: outcome == .hrv ? "ms" : outcome == .sleep ? "pts" : "pts") }
            }
            .animation(.spring(duration: 0.7), value: outcome)
            HStack { Text("worse"); Spacer(); Text("better") }.font(.mono(9)).foregroundStyle(Ember.bone3).padding(.leading, 110)
        }
    }
}

struct ForestRow: View {
    let effect: HabitEffect
    let scale: Double
    let unit: String
    var body: some View {
        HStack(spacing: 10) {
            Text(effect.factor.label).font(.system(size: 12.5)).frame(width: 100, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                let w = g.size.width
                let x = { (v: Double) in w / 2 + CGFloat(v / scale) * w / 2 }
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ember.bone3).frame(width: 1, height: 16).offset(x: w / 2)
                    Capsule().fill(Ember.bone2).frame(width: max(2, x(effect.effect + effect.ci) - x(effect.effect - effect.ci)), height: 2)
                        .offset(x: x(effect.effect - effect.ci))
                    Circle().fill(effect.isSolid ? Ember.ember : Ember.bone).frame(width: 9, height: 9)
                        .shadow(color: effect.isSolid ? Ember.ember : .clear, radius: 5)
                        .offset(x: x(effect.effect) - 4.5)
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            Text(Fmt.signed(effect.effect, 1)).font(.mono(10.5, .semibold)).foregroundStyle(effect.isSolid ? Ember.ember : Ember.bone2).frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%@: %+.1f %@, plus or minus %.1f%@", effect.factor.label, effect.effect, unit, effect.ci, effect.isSolid ? ", solid" : ""))
    }
}

// MARK: Discoveries

struct DiscoveriesPage: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        let found = model.analysis.effects.filter(\.isSolid).sorted { abs($0.effect) / $0.ci > abs($1.effect) / $1.ci }
        EmberPage {
            InfoLabel(text: "Found in your history", accent: true,
                      info: "Your life already varies: some nights you eat late, some weeks you travel. These compare days that differ in one habit while holding the others, your strain and your bedtime steady. That's weaker evidence than a planned test, so each shows how sure it is.")
            if found.isEmpty { Text("No solid patterns yet. They appear as your history grows.").font(.system(size: 13)).foregroundStyle(Ember.bone2) }
            ForEach(Array(found.enumerated()), id: \.element.id) { i, e in
                GlassCard {
                    Text(sentence(e)).font(.system(size: 14.5, weight: .medium))
                    Text("\(e.withCount) days with it vs \(e.withoutCount) without · from \(e.factor.source)").font(.system(size: 12)).foregroundStyle(Ember.bone2)
                    HStack { Label9(e.outcome.rawValue); Spacer(); ConfidenceBars(value: e.confidence) }.padding(.top, 4)
                }
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
                .animation(.easeOut(duration: 0.5).delay(Double(i) * 0.07), value: shown)
            }
        }
        .onAppear { shown = true }
    }

    private func sentence(_ e: HabitEffect) -> String {
        switch e.outcome {
        case .recovery: return String(format: "%@ → %+.0f recovery", e.factor.label, e.effect)
        case .hrv: return String(format: "%@ → HRV %+.0f ms", e.factor.label, e.effect)
        case .sleep: return String(format: "%@ → sleep %+.0f pts", e.factor.label, e.effect)
        }
    }
}

// MARK: Explorer

struct ExplorerPage: View {
    @Environment(AppModel.self) private var model
    @State private var x = "Sleep hours"
    @State private var y = "Recovery"
    @State private var nextMorning = false
    @State private var progress = 0.0

    private let xs: [String: (DayRecord, DayScore) -> Double?] = [
        "Sleep hours": { d, _ in d.totalSleepMinutes > 120 ? d.totalSleepMinutes / 60 : nil },
        "Bedtime": { d, _ in d.mainSleep.map { Analyzer.clock($0.start) } },
        "Strain": { _, s in s.strain.strain },
        "Steps (k)": { d, _ in d.steps.map { Double($0) / 1000 } },
        "Protein (g)": { d, _ in d.proteinTotal },
        "Calories": { d, _ in d.kcalTotal },
        "Weight (kg)": { d, _ in d.weightKg },
    ]
    private let ys: [String: (DayRecord, DayScore) -> Double?] = [
        "Recovery": { _, s in s.recovery.map { Double($0.score) } },
        "HRV": { d, _ in d.hrvRmssd ?? d.hrvSdnn },
        "Resting HR": { d, _ in d.restingHR },
        "Sleep %": { _, s in s.sleep?.performance },
    ]

    var body: some View {
        let pts = points()
        let fit = regression(pts)
        EmberPage {
            InfoLabel(text: "Explorer", accent: true, info: "Plot any metric against any other across your history. 'Next morning' pairs each day with the following morning's value, which is how habits show their effect.")
            HStack {
                Picker("X", selection: $x) { ForEach(xs.keys.sorted(), id: \.self) { Text($0) } }
                Text("vs").font(.mono(10)).foregroundStyle(Ember.bone3)
                Picker("Y", selection: $y) { ForEach(ys.keys.sorted(), id: \.self) { Text($0) } }
            }
            .tint(Ember.bone)
            Picker("Timing", selection: $nextMorning) { Text("Same day").tag(false); Text("Next morning").tag(true) }.pickerStyle(.segmented)
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                    PointMark(x: .value(x, p.0), y: .value(y, p.1))
                        .foregroundStyle(i == pts.count - 1 ? Ember.ember : Ember.bone.opacity(0.42)).symbolSize(i == pts.count - 1 ? 60 : 22)
                }
                if let f = fit, let lo = pts.map(\.0).min(), let hi = pts.map(\.0).max() {
                    LineMark(x: .value(x, lo), y: .value(y, f.a + f.b * lo), series: .value("fit", "fit")).foregroundStyle(Ember.ember)
                    LineMark(x: .value(x, lo + (hi - lo) * progress), y: .value(y, f.a + f.b * (lo + (hi - lo) * progress)), series: .value("fit", "fit")).foregroundStyle(Ember.ember)
                }
            }
            .chartXScale(domain: .automatic(includesZero: false)).chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.mono(8.5)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.mono(8.5)) } }
            .frame(height: 240)
            .modifier(DrawIn(progress: $progress))
            .onChange(of: x) { progress = 0; withAnimation(.easeOut(duration: 0.8)) { progress = 1 } }
            .onChange(of: y) { progress = 0; withAnimation(.easeOut(duration: 0.8)) { progress = 1 } }
            HStack {
                InfoLabel(text: "Strength", info: "From −1 to 1: how tightly the dots follow the line. Around ±0.1 is noise, ±0.3 a real pattern, ±0.5 strong. It shows association, not cause.")
                Spacer()
            }
            Trio(items: [("r", fit.map { String(format: "%.2f", $0.r) } ?? "–", nil),
                         ("Slope", fit.map { Fmt.signed($0.b, 2) } ?? "–", "per unit"),
                         ("Days", "\(pts.count)", nil)])
        }
    }

    private func points() -> [(Double, Double)] {
        guard let fx = xs[x], let fy = ys[y] else { return [] }
        let keys = model.analysis.orderedKeys
        return keys.enumerated().compactMap { i, k in
            let yk = nextMorning ? (i + 1 < keys.count ? keys[i + 1] : nil) : k
            guard let yk, let d = model.record(k), let s = model.analysis.scores[k],
                  let dy = model.record(yk), let sy = model.analysis.scores[yk], let xv = fx(d, s), let yv = fy(dy, sy) else { return nil }
            return (xv, yv)
        }
    }

    private func regression(_ p: [(Double, Double)]) -> (a: Double, b: Double, r: Double)? {
        guard p.count > 5 else { return nil }
        let mx = Stats.mean(p.map(\.0)), my = Stats.mean(p.map(\.1))
        let sxy = p.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }, sxx = p.reduce(0) { $0 + pow($1.0 - mx, 2) }, syy = p.reduce(0) { $0 + pow($1.1 - my, 2) }
        guard sxx > 0, syy > 0 else { return nil }
        let b = sxy / sxx
        return (my - b * mx, b, sxy / sqrt(sxx * syy))
    }
}

// MARK: Patterns

struct PatternsPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        EmberPage {
            Section9(title: "Recovery calendar", info: "Each square is a day. Brighter ember means higher recovery; dim bone means lower. Columns are weeks.", trailing: "13 weeks") {
                RecoveryCalendar(days: model.analysis.recent(91), progress: progress)
            }
            Section9(title: "By weekday", info: "Average next-morning recovery for each day of the week. A dip after weekends usually points to later bedtimes or alcohol on Friday and Saturday.") {
                WeekdayBars(averages: weekdayAverages(model.analysis), progress: progress)
            }
            hrvSection
        }
        .modifier(DrawIn(progress: $progress))
    }

    @ViewBuilder private var hrvSection: some View {
        let keys = model.analysis.orderedKeys
        let all: [Double] = keys.compactMap { k in model.record(k).flatMap { $0.hrvRmssd ?? $0.hrvSdnn } }
        if let today = keys.last, let hrv = model.record(today).flatMap({ $0.hrvRmssd ?? $0.hrvSdnn }), !all.isEmpty {
            let below = Double(all.filter { $0 < hrv }.count) / Double(all.count)
            Section9(title: "HRV distribution", info: "How often each HRV value has occurred. The ember line is last night: further right than most nights means unusually well recovered.",
                     trailing: "top \(Int((1 - below) * 100))%") {
                HRVHistogram(values: all, today: hrv, progress: progress)
            }
        }
    }

    private func weekdayAverages(_ a: Analysis) -> [(String, Double)] {
        var sums = [Double](repeating: 0, count: 8), counts = [Double](repeating: 0, count: 8)
        for k in a.orderedKeys {
            guard let r = a.scores[k]?.recovery?.score, let d = DayKey.date(from: k) else { continue }
            let w = Calendar.current.component(.weekday, from: d)
            sums[w] += Double(r)
            counts[w] += 1
        }
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return [2, 3, 4, 5, 6, 7, 1].compactMap { w in counts[w] > 0 ? (names[w], sums[w] / counts[w]) : nil }
    }
}

struct RecoveryCalendar: View {
    let days: [DayScore]
    let progress: Double

    var body: some View {
        LazyHGrid(rows: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, s in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(i, s))
                    .aspectRatio(1, contentMode: .fit)
                    .opacity(progress > Double(i) / Double(max(days.count, 1)) ? 1 : 0)
            }
        }
        .frame(height: 170)
    }

    private func color(_ i: Int, _ s: DayScore) -> Color {
        let r = Double(s.recovery?.score ?? 0)
        if i == days.count - 1 { return Ember.ember }
        if r >= 67 { return Ember.ember.opacity(0.25 + (r - 67) / 60) }
        return Ember.bone.opacity(0.06 + r / 220)
    }
}

struct WeekdayBars: View {
    let averages: [(String, Double)]
    let progress: Double

    var body: some View {
        let mean = averages.map(\.1).reduce(0, +) / Double(max(averages.count, 1))
        Chart(averages, id: \.0) { item in
            BarMark(x: .value("Day", item.0), y: .value("Recovery", item.1 * progress))
                .foregroundStyle(item.1 < mean ? Ember.bone.opacity(0.28) : Ember.ember.opacity(0.65))
                .cornerRadius(3)
                .annotation(position: .top) { Text("\(Int(item.1))").font(.mono(8.5)).foregroundStyle(Ember.bone2) }
        }
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.mono(8.5)) } }
        .frame(height: 110)
    }
}

struct HRVHistogram: View {
    let values: [Double]
    let today: Double
    let progress: Double

    var body: some View {
        let lo = floor((values.min() ?? 0) / 4) * 4
        let grouped = Dictionary(grouping: values) { Int(($0 - lo) / 4) }
        let bins: [(Double, Double)] = grouped.map { (lo + Double($0.key) * 4 + 2, Double($0.value.count)) }.sorted { $0.0 < $1.0 }
        Chart {
            ForEach(bins, id: \.0) { b in
                BarMark(x: .value("HRV", b.0), y: .value("Nights", b.1 * progress), width: .fixed(9))
                    .foregroundStyle(Ember.bone.opacity(0.3)).cornerRadius(2)
            }
            RuleMark(x: .value("Last night", today)).foregroundStyle(Ember.ember).lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.mono(8.5)) } }
        .chartYAxis(.hidden)
        .frame(height: 90)
    }
}

// MARK: Weekly

struct WeeklyPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        EmberPage {
            if let w = model.analysis.weekly {
                PageHero(label: "Week of " + Fmt.dayTitle(w.start), value: w.averageRecovery, unit: "% avg",
                         caption: [w.change.map { String(format: "%@ %.0f vs the week before", $0 >= 0 ? "▲" : "▼", abs($0)) },
                                   w.rankInQuarter.map { "#\($0) of the last 13 weeks" }].compactMap { $0 }.joined(separator: " · "))
                Chart(Array(w.daily.enumerated()), id: \.offset) { i, d in
                    BarMark(x: .value("Day", DayKey.date(from: d.0).map { $0.formatted(.dateTime.weekday(.abbreviated)) } ?? "\(i)"),
                            y: .value("Recovery", Double(d.1 ?? 0) * progress))
                        .foregroundStyle(d.0 == w.best?.day ? Ember.ember : d.0 == w.worst?.day ? Ember.bone.opacity(0.18) : Ember.bone.opacity(0.4)).cornerRadius(3)
                    RuleMark(y: .value("Average", w.averageRecovery)).foregroundStyle(Ember.bone3).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                .chartYAxis(.hidden).chartXAxis { AxisMarks { _ in AxisValueLabel().font(.mono(8.5)) } }.frame(height: 120)
                .modifier(DrawIn(progress: $progress))
                VStack(spacing: 0) {
                    if let b = w.best { MetricRow(name: "Best · \(Analyzer.weekdayName(b.day)) \(b.score)%", value: b.why) }
                    if let b = w.worst { MetricRow(name: "Worst · \(Analyzer.weekdayName(b.day)) \(b.score)%", value: b.why) }
                    if let s = w.bedtimeSpreadMinutes { MetricRow(name: "Bedtime consistency", value: "±\(Int(s))m") }
                    MetricRow(name: "Strain total", value: String(format: "%.1f", w.strainTotal), delta: w.strainChange.map { Fmt.signed($0) + "%" })
                }
                if let tip = w.tip {
                    GlassCard { Label9("Next week", accent: true); Text(tip).font(.system(size: 13.5)) }
                }
                ShareLink(item: summary(w)) { Text("Share this week").font(.system(size: 13, weight: .medium)) }.tint(Ember.ember)
            } else {
                Text("Your first weekly report arrives after a full Monday–Sunday week.").font(.system(size: 14)).foregroundStyle(Ember.bone2)
            }
        }
    }

    private func summary(_ w: WeeklyReport) -> String {
        String(format: "My week: %.0f%% average recovery%@. Best day %@, worst %@.", w.averageRecovery,
               w.change.map { String(format: " (%+.0f)", $0) } ?? "", w.best.map { Analyzer.weekdayName($0.day) } ?? "–", w.worst.map { Analyzer.weekdayName($0.day) } ?? "–")
    }
}
