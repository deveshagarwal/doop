import SwiftUI
import Charts

struct TrainingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let t = model.today {
                        loadStatus(t.load)
                        strainChart(model.analysis.recent(21))
                        loadChart(model.analysis.recent(90))
                        workouts(model.analysis.recent(30))
                    } else {
                        EmptyState(symbol: "figure.run", title: "No training data", message: "Connect Apple Health or turn on demo mode in Settings.")
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Training")
        }
    }

    private func loadStatus(_ l: LoadState) -> some View {
        Card(title: "Training load") {
            HStack(alignment: .firstTextBaseline) {
                Text(l.status.rawValue).font(.title2.bold()).foregroundStyle(color(l.status))
                Spacer()
                if let r = l.acwr { Text(String(format: "ACWR %.2f", r)).font(.subheadline.weight(.semibold)).monospacedDigit() }
            }
            if let r = l.acwr { ACWRGauge(value: r) }
            Text(l.status.advice).font(.subheadline).foregroundStyle(Theme.secondary)
            HStack {
                StatTile(label: "Fitness (42d)", value: "\(Int(l.chronic))")
                StatTile(label: "Fatigue (7d)", value: "\(Int(l.acute))")
                StatTile(label: "Form", value: String(format: "%+.0f", l.form), color: l.form >= 0 ? Theme.green : Theme.load)
            }
        }
    }

    private func color(_ s: LoadState.Status) -> Color {
        switch s {
        case .productive: return Theme.green
        case .overreaching: return Theme.yellow
        case .highRisk: return Theme.red
        case .detraining: return Theme.load
        default: return .white
        }
    }

    private func strainChart(_ days: [DayScore]) -> some View {
        Card(title: "Strain vs target", trailing: "21 days") {
            Chart {
                ForEach(days, id: \.date) { s in
                    let d = DayKey.date(from: s.date) ?? Date()
                    BarMark(x: .value("Day", d, unit: .day), y: .value("Strain", s.strain.strain))
                        .foregroundStyle(Theme.strain.gradient).cornerRadius(3)
                    if let t = s.strainTarget {
                        PointMark(x: .value("Day", d, unit: .day), y: .value("Target", t))
                            .symbol(.circle).symbolSize(16).foregroundStyle(.white)
                    }
                }
            }
            .chartYScale(domain: 0...21)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 4)) { _ in AxisValueLabel(format: .dateTime.day()) } }
            .frame(height: 150)
        }
    }

    private func loadChart(_ days: [DayScore]) -> some View {
        Card(title: "Fitness vs fatigue", trailing: "90 days") {
            Chart {
                ForEach(days, id: \.date) { s in
                    let d = DayKey.date(from: s.date) ?? Date()
                    LineMark(x: .value("Day", d), y: .value("Load", s.load.chronic), series: .value("Series", "Fitness"))
                        .foregroundStyle(Theme.green).interpolationMethod(.monotone)
                    LineMark(x: .value("Day", d), y: .value("Load", s.load.acute), series: .value("Series", "Fatigue"))
                        .foregroundStyle(Theme.load).interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Fitness": Theme.green, "Fatigue": Theme.load])
            .frame(height: 150)
            Text("Fitness is your 6-week average load, fatigue your 1-week. Fatigue far above fitness for long is how people get hurt or sick.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
    }

    private func workouts(_ days: [DayScore]) -> some View {
        let all = days.reversed().flatMap { d in d.workouts.map { (d.date, $0) } }
        return Card(title: "Recent workouts") {
            if all.isEmpty {
                Text("No workouts in the last 30 days.").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            ForEach(all.prefix(12), id: \.1.id) { date, w in
                HStack {
                    VStack(alignment: .leading) {
                        Text(w.name).font(.subheadline.weight(.medium))
                        Text("\(Fmt.dayTitle(date)) · \(Int(w.durationMinutes)) min\(w.averageHR.map { " · avg \(Int($0)) bpm" } ?? "")")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(w.strain.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.headline).monospacedDigit().foregroundStyle(Theme.strain)
                }
            }
        }
    }
}

struct ACWRGauge: View {
    let value: Double
    private let range = 0.4...2.0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (v: Double) -> CGFloat in
                CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Theme.load.opacity(0.5).frame(width: x(0.8))
                    Color.white.opacity(0.2).frame(width: x(1.0) - x(0.8))
                    Theme.green.opacity(0.7).frame(width: x(1.3) - x(1.0))
                    Theme.yellow.opacity(0.7).frame(width: x(1.5) - x(1.3))
                    Theme.red.opacity(0.7)
                }
                .clipShape(Capsule())
                Circle().fill(.white).frame(width: 14, height: 14).offset(x: x(value) - 7)
            }
        }
        .frame(height: 14)
    }
}
