import SwiftUI
import Charts

struct SleepDetailView: View {
    @Environment(AppModel.self) private var model
    let day: DayScore
    let record: DayRecord?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let s = day.sleep, let main = record?.mainSleep {
                    Card(title: "Last night", trailing: "\(Fmt.clock(s.bedtime)) – \(Fmt.clock(s.wake))") {
                        HStack {
                            StatTile(label: "Performance", value: "\(Int(s.performance.rounded()))%", color: Theme.sleep)
                            StatTile(label: "Asleep", value: Fmt.hm(s.asleepMinutes))
                            StatTile(label: "Needed", value: Fmt.hm(s.needMinutes))
                        }
                        HStack {
                            StatTile(label: "Efficiency", value: s.efficiency.map { "\(Int($0))%" } ?? "–")
                            StatTile(label: "Consistency", value: s.consistency.map { "\(Int($0))%" } ?? "–")
                            StatTile(label: "Debt in", value: Fmt.hm(s.debtMinutes))
                        }
                    }
                    if !main.stages.isEmpty {
                        Card(title: "Stages") {
                            Hypnogram(stages: main.stages).frame(height: 130)
                            HStack {
                                ForEach([SleepStage.awake, .light, .deep, .rem], id: \.self) { st in
                                    StatTile(label: st.rawValue.capitalized,
                                             value: "\(Int(s.stagePercent[st] ?? 0))%",
                                             sub: Fmt.hm(main.minutes(in: st)), color: Theme.stage(st))
                                }
                            }
                        }
                    }
                } else {
                    EmptyState(symbol: "bed.double", title: "No sleep data", message: "Wear the band overnight and open the Google Health app in the morning to sync.")
                }

                Card(title: "Tonight") {
                    HStack {
                        StatTile(label: "Sleep need", value: Fmt.hm(day.sleepNeedTonight), color: Theme.sleep)
                        StatTile(label: "Bed by", value: Fmt.clock(day.bedtimeTonight))
                    }
                    Text("Need = your base \(String(format: "%.1f", model.settings.baseSleepNeedHours))h, plus a quarter of your sleep debt, plus extra after a strain above 10.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }

                SleepTrendCard(scores: model.analysis.recent(14))
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Sleep")
    }
}

struct Hypnogram: View {
    let stages: [StageSpan]
    private let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        Chart(stages.filter { $0.stage != .unknown }, id: \.start) { s in
            RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end),
                          y: .value("Stage", s.stage.rawValue.capitalized), height: 18)
                .foregroundStyle(Theme.stage(s.stage))
                .cornerRadius(3)
        }
        .chartYScale(domain: order.map { $0.rawValue.capitalized })
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
    }
}

struct SleepTrendCard: View {
    let scores: [DayScore]

    var body: some View {
        Card(title: "Hours vs need", trailing: "14 days") {
            Chart {
                ForEach(scores.filter { $0.sleep != nil }, id: \.date) { s in
                    BarMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day),
                            y: .value("Hours", (s.sleep?.asleepMinutes ?? 0) / 60))
                        .foregroundStyle(Theme.sleep.opacity(0.8))
                        .cornerRadius(3)
                    PointMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day),
                              y: .value("Need", (s.sleep?.needMinutes ?? 0) / 60))
                        .symbol(.circle).symbolSize(18).foregroundStyle(.white)
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day()) } }
            .frame(height: 140)
            Text("Bars are hours asleep, dots are what you needed that night.").font(.caption).foregroundStyle(Theme.tertiary)
        }
    }
}
