import SwiftUI
import Charts

// MARK: Energy and stress

struct EnergyPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        let se = model.analysis.stressEnergy
        EmberPage {
            if let se, let now = se.current {
                PageHero(label: "Energy bank",
                         info: "Starts the morning at your recovery level. Exercise and stress drain it; sleep, naps and calm stretches refill it. A rough guide to how much you have left for the evening, not a medical measure.",
                         value: now, unit: "left",
                         caption: se.projectedBedtimeEnergy.map { String(format: "About %.0f by 10:30pm at this pace", $0) } ?? "")
                Chart {
                    ForEach(Array(se.energy.prefix(max(2, Int(Double(se.energy.count) * progress))).enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.0), y: .value("Energy", p.1))
                            .foregroundStyle(LinearGradient(colors: [Ember.ember.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", p.0), y: .value("Energy", p.1)).foregroundStyle(Ember.ember)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.mono(8.5)) } }
                .chartYAxis(.hidden).frame(height: 140)
                Section9(title: "Stress today",
                         info: "Minutes when your heart rate was well above your calm baseline while you weren't moving or exercising. Built from heart rate and steps only, so it can't tell excitement from worry.",
                         trailing: "\(Int(se.highStressMinutes)) min high") {
                    Chart(Array(se.stressBuckets.enumerated()), id: \.offset) { _, b in
                        BarMark(x: .value("Time", b.0, unit: .minute), y: .value("Stress", max(b.1, 0.08) * progress), width: .fixed(4))
                            .foregroundStyle(b.1 >= 2 ? Ember.ember : b.1 >= 1 ? Ember.ember.opacity(0.45) : Ember.bone.opacity(0.22)).cornerRadius(1.5)
                    }
                    .chartYScale(domain: 0...3).chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.mono(8.5)) } }
                    .frame(height: 60)
                }
            } else {
                PageHero(label: "Energy bank", value: 0, caption: "Appears once today's heart rate has synced.")
            }
        }
        .modifier(DrawIn(progress: $progress))
    }
}


struct BreathingView: View {
    @State private var running = false
    @State private var start = Date()
    @State private var phaseTick = 0

    var body: some View {
        HStack(spacing: 18) {
            TimelineView(.animation(paused: !running)) { tl in
                let t = running ? tl.date.timeIntervalSince(start) : 0
                let phase = Int(t / 4) % 4, f = (t / 4).truncatingRemainder(dividingBy: 1)
                let s = phase == 0 ? f : phase == 1 ? 1 : phase == 2 ? 1 - f : 0
                ZStack {
                    Circle().fill(RadialGradient(colors: [Ember.ember.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 46))
                        .scaleEffect(0.55 + 0.45 * s)
                    Circle().stroke(Ember.bone, lineWidth: 1).frame(width: 30 + 40 * s, height: 30 + 40 * s)
                }
                .frame(width: 90, height: 90)
                .onChange(of: phase) { _, _ in phaseTick += 1 }
                .overlay(alignment: .bottom) {
                    Text(running ? ["in", "hold", "out", "hold"][phase] + " · 4s" : "")
                        .font(.mono(9.5)).foregroundStyle(Ember.bone2).offset(y: 16)
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.4), trigger: phaseTick)
            VStack(alignment: .leading, spacing: 6) {
                Text(running ? "Follow the circle" : "Two minutes, box breathing").font(.system(size: 14, weight: .medium))
                ChipButton(title: running ? "Stop" : "Start", on: running) {
                    running.toggle()
                    start = Date()
                }
            }
        }
        .task(id: running) {
            guard running else { return }
            try? await Task.sleep(for: .seconds(120))
            running = false
        }
    }
}

// MARK: Health monitor

struct HealthMonitorPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let a = model.analysis
        EmberPage {
            if let t = a.latest {
                VStack(alignment: .leading, spacing: 6) {
                    InfoLabel(text: "Illness watch", accent: true, info: IllnessInfo.text)
                    Text(t.illness.level.title).font(.ultra(38))
                    Text(t.illness.message).font(.system(size: 13)).foregroundStyle(Ember.bone2)
                    HStack(spacing: 3) {
                        ForEach(a.recent(14), id: \.date) { d in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(d.illness.level == .alert ? Ember.ember.opacity(0.85) : d.illness.level == .watch ? Ember.ember.opacity(0.35) : Ember.bone.opacity(0.14))
                                .frame(height: 16)
                        }
                    }
                    .padding(.top, 6)
                    HStack { Label9("14 nights ago"); Spacer(); Label9("last night") }
                }
                VStack(spacing: 0) {
                    ForEach(metrics, id: \.self) { m in VitalRow(metric: m) }
                }
            }
        }
    }

    private var metrics: [Metric] {
        let hasRMSSD = model.days.values.contains { $0.hrvRmssd != nil }
        return [hasRMSSD ? .hrvRmssd : .hrvSdnn, .restingHR, .respiratoryRate, .skinTemp, .spo2]
    }
}

struct VitalRow: View {
    @Environment(AppModel.self) private var model
    let metric: Metric
    @State private var progress = 0.0

    var body: some View {
        let keys = Array(model.analysis.orderedKeys.suffix(30))
        let pts: [(Date, Double)] = keys.compactMap { k in model.record(k).flatMap(metric.display).flatMap { v in DayKey.date(from: k).map { ($0, v) } } }
        let base = keys.last.flatMap { model.analysis.book.baseline(before: $0, metric.value) }
        let isLog = metric == .hrvRmssd || metric == .hrvSdnn
        let band = base.map { b in isLog ? (exp(b.mean - b.sd), exp(b.mean + b.sd)) : (b.lower, b.upper) }
        let latest = pts.last?.1
        let out = latest.flatMap { v in band.map { v < $0.0 || v > $0.1 } } ?? false
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(metric.label).font(.system(size: 12.5)).lineLimit(1)
                InfoButton(title: metric.label, text: info)
            }
            .frame(width: 128, alignment: .leading)
            Chart {
                if let band, let first = pts.first?.0, let last = pts.last?.0 {
                    RectangleMark(xStart: .value("s", first), xEnd: .value("e", last), yStart: .value("lo", band.0), yEnd: .value("hi", band.1))
                        .foregroundStyle(Ember.bone.opacity(0.07))
                }
                ForEach(pts.prefix(max(2, Int(Double(pts.count) * progress))), id: \.0) { p in
                    LineMark(x: .value("Day", p.0), y: .value("V", p.1)).foregroundStyle(Ember.bone2)
                }
                if let p = pts.last { PointMark(x: .value("Day", p.0), y: .value("V", p.1)).foregroundStyle(Ember.ember).symbolSize(20) }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 26)
            Text(latest.map { String(format: decimals, $0) } ?? "–").font(.light(14)).monospacedDigit()
                .foregroundStyle(out ? Ember.ember : Ember.bone).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
        .modifier(DrawIn(progress: $progress))
    }

    private var decimals: String { [.respiratoryRate, .skinTemp, .spo2].contains(metric) ? "%.1f" : "%.0f" }

    private var info: String {
        switch metric {
        case .hrvRmssd, .hrvSdnn: return "Variation between heartbeats overnight. The shaded band is your normal range over the last 30 nights. HRV doesn't sync to Apple Health from Fitbit; connect Google Health in Settings to add it."
        case .restingHR: return "Lowest steady overnight heart rate. Above the band for two nights is the most common early sign of getting sick."
        case .respiratoryRate: return "Breaths per minute asleep. It rarely moves, so a rise stands out."
        case .skinTemp: return "Overnight wrist temperature. A rise of 0.5 °C or more often comes with illness, alcohol or the luteal phase."
        case .spo2: return "Average blood oxygen overnight. Dips under 90% can point to breathing interruptions."
        }
    }
}

// MARK: Healthspan

struct HealthspanPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        EmberPage {
            if let h = model.analysis.healthspan {
                InfoLabel(text: "Pace of aging", accent: true,
                          info: "How many years your body age moves per calendar year, from the trend over recent months. 1.0× is average; 0.8× means aging slower than the calendar. Needs about 4 months of data.")
                PaceDial(pace: h.pace.map { 1.6 - (1.6 - $0) * progress }).frame(height: 160)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        InfoLabel(text: "Body age", info: "What age your fitness (VO₂max), resting heart rate, activity and sleep look like against published population norms. Anchored on VO₂max, the strongest single predictor of long-term health. A heuristic, not a clinical test.")
                        CountUp(value: h.bodyAge, decimals: 1, font: .ultra(44))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Label9("Calendar age")
                        Text("\(Int(h.chronologicalAge))").font(.ultra(44)).foregroundStyle(Ember.bone3)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(h.contributors, id: \.name) { c in
                        MetricRow(name: c.name, value: Fmt.signed(c.years, 1) + " yrs", fraction: min(abs(c.years) / 4, 1), accent: c.years < 0)
                    }
                }
                if h.vo2Estimated {
                    Text("VO₂max is estimated from your heart rates; a Fitbit cardio-fitness reading would sharpen this.").font(.system(size: 11.5)).foregroundStyle(Ember.bone3)
                }
            } else {
                PageHero(label: "Healthspan", value: 0, caption: "Needs about two weeks of data.")
            }
        }
        .modifier(DrawIn(progress: $progress))
    }
}

struct PaceDial: View {
    let pace: Double?
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height * 0.92), r = size.width * 0.36
            func a(_ v: Double) -> Angle { .degrees(180 + (v - 0.5) / 1.2 * 180) }
            var track = Path(); track.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(track, with: .color(Ember.hair), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            var good = Path(); good.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: a(1), clockwise: false)
            ctx.stroke(good, with: .linearGradient(Gradient(colors: [Ember.ember, Ember.ember.opacity(0.2)]), startPoint: CGPoint(x: c.x - r, y: c.y), endPoint: CGPoint(x: c.x, y: c.y)),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round))
            for v in [0.6, 1.0, 1.4] {
                let p = CGPoint(x: c.x + CGFloat(cos(a(v).radians)) * (r + 18), y: c.y + CGFloat(sin(a(v).radians)) * (r + 18))
                ctx.draw(Text(String(format: "%.1f×", v)).font(.mono(9)).foregroundStyle(Ember.bone2), at: p)
            }
            if let pace {
                let na = a(min(max(pace, 0.5), 1.7))
                var needle = Path(); needle.move(to: c); needle.addLine(to: CGPoint(x: c.x + CGFloat(cos(na.radians)) * (r - 14), y: c.y + CGFloat(sin(na.radians)) * (r - 14)))
                ctx.stroke(needle, with: .color(Ember.bone), lineWidth: 2)
                ctx.draw(Text(String(format: "%.2f× PACE", pace)).font(.mono(11, .semibold)).foregroundStyle(Ember.bone), at: CGPoint(x: c.x, y: c.y - r * 0.45))
            } else {
                ctx.draw(Text("CALIBRATING").font(.mono(10)).foregroundStyle(Ember.bone3), at: CGPoint(x: c.x, y: c.y - r * 0.45))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Ember.ember))
        }
    }
}

// MARK: Weight and food

struct WeightFoodPage: View {
    @Environment(AppModel.self) private var model
    @State private var progress = 0.0

    var body: some View {
        let keys = model.analysis.orderedKeys
        let weights: [(Date, Double)] = keys.compactMap { k in model.record(k)?.weightKg.flatMap { w in DayKey.date(from: k).map { ($0, w) } } }
        EmberPage {
            if let last = weights.last {
                let rate = weeklyRate(weights)
                PageHero(label: "Weight · Omada", info: "Dots are weigh-ins; the ember line is a 7-day average, which hides day-to-day water swings. The rate is the slope of the last four weeks.",
                         value: last.1, decimals: 1, unit: "kg", caption: rate.map { String(format: "%+.1f kg/week over 4 weeks", $0) } ?? "")
                Chart {
                    ForEach(weights.prefix(max(2, Int(Double(weights.count) * progress))), id: \.0) { p in
                        PointMark(x: .value("Day", p.0), y: .value("kg", p.1)).foregroundStyle(Ember.bone.opacity(0.3)).symbolSize(10)
                    }
                    ForEach(Array(movingAverage(weights).prefix(max(2, Int(Double(weights.count) * progress))).enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Day", p.0), y: .value("kg", p.1)).foregroundStyle(Ember.ember)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false)).chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.mono(8.5)) } }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.mono(8.5)) } }
                .frame(height: 130)
            } else {
                GlassCard {
                    Label9("Weight · Omada", accent: true)
                    Text("No weigh-ins yet. In the Omada app: Settings → Health Integration → Share with Health App, and turn on weight.").font(.system(size: 13))
                }
            }
        }
        .modifier(DrawIn(progress: $progress))
    }

    private func movingAverage(_ w: [(Date, Double)]) -> [(Date, Double)] {
        w.indices.map { i in
            let window = w.filter { $0.0 <= w[i].0 && $0.0 > w[i].0.addingTimeInterval(-7 * 86400) }.map(\.1)
            return (w[i].0, Stats.mean(window))
        }
    }

    private func weeklyRate(_ w: [(Date, Double)]) -> Double? {
        guard let last = w.last?.0 else { return nil }
        let recent = w.filter { $0.0 > last.addingTimeInterval(-28 * 86400) }
        guard recent.count >= 6 else { return nil }
        let xs = recent.map { $0.0.timeIntervalSince(last) / (7 * 86400) }, ys = recent.map(\.1)
        let mx = Stats.mean(xs), my = Stats.mean(ys)
        let sxx = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard sxx > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
    }
}
