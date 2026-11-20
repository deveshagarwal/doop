import SwiftUI
import Charts

/// Every extra Apple Health type with data: latest daily value and the last 30 days.
struct AllHealthDataPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keys = model.extraMetricKeys
        let dayKeys = model.analysis.orderedKeys
        EmberPage {
            InfoLabel(text: "All Apple Health data", accent: true,
                      info: "Everything in Apple Health that the scores don't use directly, from any app or device. One value per day: totals are summed (water, distance), readings are averaged (blood pressure, walking heart rate).")
            if keys.isEmpty {
                Text("Nothing extra yet. Anything any app writes to Apple Health shows up here after the next sync.")
                    .font(.system(size: 13)).foregroundStyle(Ember.bone2)
            }
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { k in
                    let series: [(Date, Double)] = dayKeys.suffix(30).compactMap { d in
                        model.record(d)?.extras?[k].flatMap { v in DayKey.date(from: d).map { ($0, v) } }
                    }
                    let latest = dayKeys.reversed().lazy.compactMap { d in model.record(d)?.extras?[k].map { (d, $0) } }.first
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(HealthCatalog.label(k)).font(.system(size: 13.5)).lineLimit(2)
                            Text(latest.map { Fmt.dayTitle($0.0) } ?? "").font(.mono(9.5)).foregroundStyle(Ember.bone3)
                        }
                        Spacer(minLength: 8)
                        if series.count > 1 {
                            Chart(series, id: \.0) { p in
                                LineMark(x: .value("Day", p.0), y: .value("Value", p.1)).foregroundStyle(Ember.ember)
                            }
                            .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
                            .frame(width: 70, height: 24)
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(latest.map { Self.format($0.1) } ?? "–").font(.light(16)).monospacedDigit()
                            Text(model.unit(forExtra: k)).font(.mono(8.5)).foregroundStyle(Ember.bone3)
                        }
                        .frame(minWidth: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
                }
            }
        }
    }

    static func format(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }
}
