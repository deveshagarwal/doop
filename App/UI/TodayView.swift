import SwiftUI
import Charts

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !model.hasAnyData {
                        OnboardingCard(showSettings: $showSettings)
                    } else if let t = model.today {
                        if t.illness.level != .clear { IllnessBanner(signal: t.illness) }
                        rings(t)
                        coachButton
                        RecoveryCard(day: t)
                        StrainCard(day: t, record: model.record(t.date))
                        NavigationLink { SleepDetailView(day: t, record: model.record(t.date)) } label: {
                            SleepSummaryCard(day: t)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.sync() }
            .screenBackground()
            .navigationTitle(Date().formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                if model.syncing {
                    ToolbarItem(placement: .topBarLeading) { ProgressView().controlSize(.small) }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func rings(_ t: DayScore) -> some View {
        HStack(spacing: 0) {
            ScoreRing(fraction: Double(t.recovery?.score ?? 0) / 100, color: Theme.recovery(t.recovery?.zone),
                      value: t.recovery.map { "\($0.score)%" } ?? "–", label: "Recovery")
                .frame(maxWidth: .infinity)
            ScoreRing(fraction: t.strain.strain / 21, color: Theme.strain, value: String(format: "%.1f", t.strain.strain),
                      label: "Strain", target: t.strainTarget.map { $0 / 21 })
                .frame(maxWidth: .infinity)
            ScoreRing(fraction: (t.sleep?.performance ?? 0) / 100, color: Theme.sleep,
                      value: t.sleep.map { "\(Int($0.performance.rounded()))%" } ?? "–", label: "Sleep")
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    private var coachButton: some View {
        Button { model.morningBrief() } label: {
            HStack {
                Image(systemName: "sparkles")
                Text("Morning brief from your coach")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardBorder))
        }
        .buttonStyle(.plain)
    }
}

struct IllnessBanner: View {
    let signal: IllnessSignal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: signal.level == .alert ? "cross.case.fill" : "eye.fill")
                .foregroundStyle(Theme.illness(signal.level))
            VStack(alignment: .leading, spacing: 4) {
                Text(signal.level.title).font(.subheadline.weight(.semibold))
                Text(signal.message).font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.illness(signal.level).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.illness(signal.level).opacity(0.4)))
    }
}

struct RecoveryCard: View {
    let day: DayScore

    var body: some View {
        Card(title: "Recovery", trailing: day.recovery?.calibrating == true ? "calibrating" : nil) {
            if let r = day.recovery {
                ForEach(r.contributors) { c in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(c.name).font(.subheadline)
                            Spacer()
                            Text(c.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                            if let b = c.baseline { Text("vs \(b)").font(.caption).foregroundStyle(Theme.tertiary) }
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(Theme.recovery(.init(score: Int(c.score)))).frame(width: g.size.width * c.score / 100)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                ForEach(r.notes, id: \.self) { n in
                    Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.secondary)
                }
            } else {
                Text("No overnight data yet. Recovery appears after the Google Health app syncs your sleep.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct StrainCard: View {
    let day: DayScore
    let record: DayRecord?

    var body: some View {
        Card(title: "Strain", trailing: day.strain.estimated ? "estimated" : nil) {
            HStack {
                StatTile(label: "So far", value: String(format: "%.1f", day.strain.strain), color: Theme.strain)
                StatTile(label: "Target", value: day.strainTarget.map { String(format: "%.1f", $0) } ?? "–")
                StatTile(label: "Peak HR", value: day.strain.peakHR.map { "\(Int($0))" } ?? "–")
            }
            if let target = day.strainTarget {
                let gap = target - day.strain.strain
                Text(gap > 0.5
                     ? String(format: "%.1f to go. Your recovery supports it.", gap)
                     : "Target reached. Anything more digs into tomorrow's recovery.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            if let samples = record?.hrSamples, samples.count > 30 {
                Chart(samples, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("BPM", s.bpm))
                        .foregroundStyle(Theme.strain.gradient)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 110)
            }
            ForEach(day.workouts) { w in
                HStack {
                    Image(systemName: "figure.run").foregroundStyle(Theme.strain)
                    Text(w.name).font(.subheadline)
                    Text("\(Int(w.durationMinutes)) min").font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    if let s = w.strain { Text(String(format: "%.1f", s)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                }
            }
        }
    }
}

struct SleepSummaryCard: View {
    let day: DayScore

    var body: some View {
        Card(title: "Sleep", trailing: "Details ›") {
            if let s = day.sleep {
                HStack {
                    StatTile(label: "Slept", value: Fmt.hm(s.asleepMinutes), sub: "of \(Fmt.hm(s.needMinutes)) needed")
                    StatTile(label: "Efficiency", value: s.efficiency.map { "\(Int($0))%" } ?? "–")
                    StatTile(label: "Debt", value: Fmt.hm(s.debtMinutes))
                }
            } else {
                Text("No sleep recorded for last night.").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            Divider().overlay(Theme.cardBorder)
            HStack {
                Image(systemName: "moon.stars.fill").foregroundStyle(Theme.sleep)
                Text("Tonight you need \(Fmt.hm(day.sleepNeedTonight))").font(.subheadline)
                Spacer()
                if let b = day.bedtimeTonight { Text("Bed by \(Fmt.clock(b))").font(.subheadline.weight(.semibold)) }
            }
        }
    }
}

struct OnboardingCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 44)).foregroundStyle(Theme.green).padding(.top, 30)
            Text("Baseline").font(.largeTitle.bold())
            Text("Recovery, strain, sleep and early illness signals from your Fitbit Air, scored against your own baseline. Everything stays on this phone.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.secondary)
            Card(title: "Step 1") {
                Text("In the Google Health app: Connections → Apps and services → Apple Health. Turn sharing on.")
                    .font(.subheadline)
            }
            Button {
                Task { await model.connectAppleHealth() }
            } label: {
                Label("Connect Apple Health", systemImage: "heart.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Theme.green)
            Button("Try with demo data") { model.updateSettings { $0.demoMode = true } }
                .foregroundStyle(Theme.secondary)
            Button("Add HRV via Google Health (optional)") { showSettings = true }
                .font(.footnote).foregroundStyle(Theme.tertiary)
        }
    }
}
