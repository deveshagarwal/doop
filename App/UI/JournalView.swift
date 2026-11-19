import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var model
    @State private var day = DayKey.today()
    @State private var note = ""
    @State private var newFactor = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    dayPicker
                    Card(title: "What did you do \(day == DayKey.today() ? "today" : "this day")?") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(model.factors) { f in
                                let on = model.journal[day]?.factors.contains(f.id) == true
                                Button { model.toggleFactor(f.id, on: day) } label: {
                                    Label(f.label, systemImage: f.symbol)
                                        .font(.footnote.weight(.medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 10).padding(.horizontal, 10)
                                        .background(on ? Theme.green.opacity(0.2) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.green : .clear))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("Add your own (e.g. Edibles, Late workout)", text: $newFactor)
                                .textFieldStyle(.roundedBorder).font(.footnote)
                            Button("Add") { model.addFactor(newFactor); newFactor = "" }.disabled(newFactor.isEmpty)
                        }
                        TextField("Note for the coach (how you feel, symptoms, context)", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.footnote)
                            .onSubmit { model.setNote(note, on: day) }
                            .onChange(of: note) { _, v in model.setNote(v, on: day) }
                    }
                    insights
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Journal")
            .onAppear { note = model.journal[day]?.note ?? "" }
            .onChange(of: day) { _, d in note = model.journal[d]?.note ?? "" }
        }
    }

    private var dayPicker: some View {
        HStack {
            Button { day = DayKey.addDays(day, -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(Fmt.dayTitle(day)).font(.headline)
            Spacer()
            Button { day = DayKey.addDays(day, 1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= DayKey.today())
        }
        .padding(.horizontal, 4)
    }

    private var insights: some View {
        let all = model.analysis.insights.filter { $0.outcome == "Recovery" }
        let logged = model.journal.count
        return Card(title: "What moves your recovery", trailing: "\(logged) days logged") {
            if all.isEmpty {
                Text("Log a few habits daily. Each one needs at least 5 days with it and 5 without before a pattern shows up here.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            ForEach(all) { i in InsightRow(insight: i, related: model.analysis.insights.filter { $0.factor.id == i.factor.id && $0.outcome != "Recovery" }) }
            Text("Points of next-morning recovery. Compares the morning after a logged day with mornings after days without it. Correlation, not proof.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
    }
}

struct InsightRow: View {
    let insight: FactorInsight
    let related: [FactorInsight]

    var body: some View {
        let good = insight.difference > 0
        let color = insight.strength == .none ? Theme.tertiary : (good ? Theme.green : Theme.red)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: insight.factor.symbol).frame(width: 22).foregroundStyle(Theme.secondary)
                Text(insight.factor.label).font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%+.0f pts", insight.difference)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(color)
            }
            HStack(spacing: 8) {
                Text(insight.strength == .solid ? "Solid" : (insight.strength == .trend ? "Trend" : "No clear effect"))
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
                Text("\(insight.withCount) days with, \(insight.withoutCount) without").font(.caption2).foregroundStyle(Theme.tertiary)
                ForEach(related.filter { $0.strength != .none }) { r in
                    Text(String(format: "%@ %+.0f", r.outcome == "HRV" ? "HRV" : "Sleep", r.difference)).font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.leading, 30)
        }
        .padding(.vertical, 4)
    }
}
