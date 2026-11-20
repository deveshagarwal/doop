import SwiftUI
import Charts

struct SleepTab: View {
    var body: some View {
        NavigationStack { SleepPage() }
    }
}

struct SleepPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        let day = model.today
        let record = day.flatMap { model.record($0.date) }
        let nights = day.map { NightLine.build(days: model.days, upTo: $0.date, count: 30) } ?? []
        EmberPage {
            if let day {
                if let s = day.sleep {
                    PageHero(label: "Last night",
                             info: "Time actually asleep, and how it compares with what you needed. Need is your base, plus part of any sleep debt, plus extra after a hard day.",
                             value: s.asleepMinutes / 60, decimals: 1, unit: "hours",
                             caption: "\(Int(s.performance.rounded()))% of the \(Fmt.hm(s.needMinutes)) you needed")
                }
                if nights.count >= 3 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            InfoLabel(text: "Nightlines", info: nights.contains(where: \.fromSleepOnly)
                                      ? "Each hill is one night. Left to right is clock time, so a hill starts when you fell asleep and ends when you woke. Your sleep app doesn't share overnight heart rate with Apple Health, so the shape shows time asleep (raised) and awake (dips) instead. Dashed lines are your typical bed and wake times. Tilt your phone to shift the view."
                                      : "Each hill is one night. Left to right is clock time, so a hill starts when you fell asleep and ends when you woke. Taller means your heart rate dropped further (deeper rest). Dashed lines are your typical bed and wake times. Tilt your phone to shift the view.")
                            Spacer()
                            Label9("\(nights.count) nights")
                        }
                        NightlinesView(nights: nights).frame(height: 360).padding(.horizontal, -20)
                    }
                    consistency(nights)
                }
                Section9(title: "Tonight", info: "Need = your base sleep plus a quarter of your current sleep debt, plus extra after a strain above 10. Bed-by assumes your usual wake time and how efficiently you usually sleep.") {
                    Trio(items: [("Need", Fmt.hm(day.sleepNeedTonight), nil),
                                 ("Bed by", Fmt.clock(day.bedtimeTonight), nil),
                                 ("Debt", Fmt.hm(day.sleep?.debtMinutes ?? 0), (day.sleep?.debtMinutes ?? 0) > 60 ? "pay it back" : "clear")])
                    NavigationLink(value: TodayPage.tonight) {
                        HStack { Text("Plan tonight").font(.system(size: 13, weight: .medium)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                            .padding(12).background(Ember.glass, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                if let main = record?.mainSleep, !main.stages.isEmpty, !main.stages.contains(where: { [.light, .deep, .rem].contains($0.stage) }) {
                    let wakeUps = main.stages.filter { $0.stage == .awake && $0.minutes >= 1 && $0.start > main.start.addingTimeInterval(600) }.count
                    Section9(title: "Asleep and awake",
                             info: "Your sleep app shares when you were asleep and awake with Apple Health, but not REM, deep or light stages; those stay inside its own app.",
                             trailing: "\(Fmt.clock(main.start)) – \(Fmt.clock(main.end))") {
                        Hypnogram(stages: main.stages, twoLevel: true).frame(height: 70)
                        Trio(items: [("Asleep", Fmt.hm(main.minutesAsleep), nil),
                                     ("Awake", Fmt.hm(main.minutesAwake), nil),
                                     ("Wake-ups", "\(wakeUps)", nil)])
                    }
                }
                if let s = day.sleep, let main = record?.mainSleep, main.stages.contains(where: { [.light, .deep, .rem].contains($0.stage) }) {
                    Section9(title: "Stages", info: "Deep sleep (ember) restores the body and comes early in the night; REM (bone) is for memory and mood and comes later. Fitbit estimates stages from heart rate and movement.",
                             trailing: "\(Fmt.clock(main.start)) – \(Fmt.clock(main.end))") {
                        Hypnogram(stages: main.stages).frame(height: 110)
                        Trio(items: [("Deep", Fmt.hm(main.minutes(in: .deep)), "\(Int(s.stagePercent[.deep] ?? 0))%"),
                                     ("REM", Fmt.hm(main.minutes(in: .rem)), "\(Int(s.stagePercent[.rem] ?? 0))%"),
                                     ("Efficiency", s.efficiency.map { "\(Int($0))%" } ?? "–", nil)])
                    }
                }
                Section9(title: "Hours vs need", trailing: "14 nights") {
                    let scores = model.analysis.recent(14).filter { $0.sleep != nil }
                    Chart(scores, id: \.date) { s in
                        BarMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day), y: .value("Hours", (s.sleep?.asleepMinutes ?? 0) / 60 * progress))
                            .foregroundStyle(s.date == day.date ? Ember.ember : Ember.bone.opacity(0.4)).cornerRadius(3)
                        PointMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day), y: .value("Need", (s.sleep?.needMinutes ?? 0) / 60))
                            .symbolSize(16).foregroundStyle(Ember.bone)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day()).font(.mono(8.5)) } }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.mono(8.5)) } }
                    .frame(height: 130)
                    .modifier(DrawIn(progress: $progress))
                    Text("Bars are hours asleep; dots are what you needed that night.").font(.system(size: 11)).foregroundStyle(Ember.bone3)
                }
            }
        }
        .navigationDestination(for: TodayPage.self) { page in
            if case .tonight = page { TonightPlanner() } else { RecoveryPage() }
        }
    }

    private func consistency(_ nights: [NightLine]) -> some View {
        let beds = nights.map { NightlinesView.clock($0.start) }, wakes = nights.map { NightlinesView.clock($0.end) }
        let spread = (Stats.sd(beds) + Stats.sd(wakes)) / 2
        func median(_ v: [Double]) -> String { NightlinesView.label12(Stats.percentile(v, 0.5) ?? 0) }
        return Trio(items: [("Usual bed", median(beds), nights.last.map { "last " + Fmt.clock($0.start) }),
                            ("Usual wake", median(wakes), nights.last.map { "last " + Fmt.clock($0.end) }),
                            ("Varies", "±\(Int(spread))m", spread > 45 ? "irregular" : "steady")])
    }
}

struct Hypnogram: View {
    let stages: [StageSpan]
    /// Asleep/awake only, for sources that don't share stages.
    var twoLevel = false
    private let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        Chart(stages.filter { twoLevel || $0.stage != .unknown }, id: \.start) { s in
            RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end),
                          y: .value("Stage", twoLevel ? (s.stage == .awake ? "Awake" : "Asleep") : s.stage.rawValue.capitalized), height: 16)
                .foregroundStyle(twoLevel ? (s.stage == .awake ? Ember.bone.opacity(0.5) : Ember.ember) : Ember.stage(s.stage)).cornerRadius(2)
        }
        .chartYScale(domain: twoLevel ? ["Awake", "Asleep"] : order.map { $0.rawValue.capitalized })
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.mono(8.5)) } }
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.mono(8.5)) } }
    }
}
