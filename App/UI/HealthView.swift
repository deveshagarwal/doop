import SwiftUI
import Charts

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let t = model.today {
                        illnessCard(t.illness)
                        recoveryTrend(model.analysis.recent(30))
                        ForEach(metrics, id: \.self) { m in VitalCard(metric: m, keys: Array(model.analysis.orderedKeys.suffix(30))) }
                    } else {
                        EmptyState(symbol: "heart.text.square", title: "No vitals yet", message: "Connect Apple Health or turn on demo mode in Settings.")
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Health")
        }
    }

    /// Prefer RMSSD when Google is connected; otherwise show SDNN only if something writes it.
    private var metrics: [Metric] {
        let days = model.days.values
        let hasRMSSD = days.contains { $0.hrvRmssd != nil }
        let hasSDNN = days.contains { $0.hrvSdnn != nil }
        var m: [Metric] = []
        if hasRMSSD { m.append(.hrvRmssd) } else if hasSDNN { m.append(.hrvSdnn) }
        return m + [.restingHR, .respiratoryRate, .skinTemp, .spo2]
    }

    private func illnessCard(_ s: IllnessSignal) -> some View {
        Card(title: "Illness watch") {
            HStack(spacing: 10) {
                Circle().fill(Theme.illness(s.level)).frame(width: 10, height: 10)
                Text(s.level.title).font(.headline)
            }
            Text(s.message).font(.subheadline).foregroundStyle(Theme.secondary)
            ForEach(s.deviations) { d in
                HStack {
                    Text(d.metric).font(.subheadline)
                    Spacer()
                    Text(d.detail).font(.caption).foregroundStyle(Theme.illness(s.level))
                }
            }
            let recent = model.analysis.recent(14)
            HStack(spacing: 4) {
                ForEach(recent, id: \.date) { d in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.illness(d.illness.level).opacity(d.illness.level == .clear ? 0.25 : 0.9))
                        .frame(height: 16)
                }
            }
            Text("Last 14 nights. Flags when several vitals drift from your baseline together; alcohol or a hard session alone only moves heart rate and HRV.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
    }

    private func recoveryTrend(_ days: [DayScore]) -> some View {
        Card(title: "Recovery", trailing: "30 days") {
            Chart {
                ForEach(days.filter { $0.recovery != nil }, id: \.date) { s in
                    BarMark(x: .value("Day", DayKey.date(from: s.date) ?? Date(), unit: .day), y: .value("Recovery", s.recovery?.score ?? 0))
                        .foregroundStyle(Theme.recovery(s.recovery?.zone)).cornerRadius(2)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 120)
        }
    }
}

struct VitalCard: View {
    @Environment(AppModel.self) private var model
    let metric: Metric
    let keys: [String]

    var body: some View {
        let points: [(Date, Double)] = keys.compactMap { k in
            guard let d = model.record(k), let v = metric.display(d), let date = DayKey.date(from: k) else { return nil }
            return (date, v)
        }
        let today = keys.last
        let base = today.flatMap { model.analysis.book.baseline(before: $0, metric.value) }
        let isLog = metric == .hrvRmssd || metric == .hrvSdnn
        let band = base.map { b in isLog ? (exp(b.mean - b.sd), exp(b.mean + b.sd), exp(b.mean)) : (b.lower, b.upper, b.mean) }
        let latest = today.flatMap { model.record($0) }.flatMap(metric.display)
        let inBand = latest.flatMap { v in band.map { v >= $0.0 && v <= $0.1 } } ?? true

        return Card(title: metric.label) {
            HStack(alignment: .firstTextBaseline) {
                Text(latest.map { String(format: decimals, $0) } ?? "–").font(.title2.bold()).monospacedDigit()
                    .foregroundStyle(inBand ? .white : Theme.yellow)
                Text(metric.unit).foregroundStyle(Theme.secondary)
                Spacer()
                if let b = band { Text("normal \(String(format: decimals, b.0))–\(String(format: decimals, b.1))").font(.caption).foregroundStyle(Theme.tertiary) }
            }
            if points.count > 2 {
                Chart {
                    if let b = band {
                        RectangleMark(xStart: .value("s", points.first!.0), xEnd: .value("e", points.last!.0),
                                      yStart: .value("lo", b.0), yEnd: .value("hi", b.1))
                            .foregroundStyle(Color.white.opacity(0.06))
                    }
                    ForEach(points, id: \.0) { p in
                        LineMark(x: .value("Day", p.0), y: .value(metric.label, p.1)).foregroundStyle(.white.opacity(0.8))
                        PointMark(x: .value("Day", p.0), y: .value(metric.label, p.1)).symbolSize(10)
                            .foregroundStyle(band.map { p.1 < $0.0 || p.1 > $0.1 } == true ? Theme.yellow : .white)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .frame(height: 70)
            } else {
                Text(emptyText).font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var decimals: String {
        switch metric {
        case .respiratoryRate, .skinTemp, .spo2: return "%.1f"
        default: return "%.0f"
        }
    }

    private var emptyText: String {
        metric == .hrvRmssd || metric == .hrvSdnn
            ? "HRV doesn't sync to Apple Health. Connect Google Health in Settings to add it."
            : "Not enough data yet."
    }
}
