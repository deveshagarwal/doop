import SwiftUI
import Charts

enum FuelPage: Hashable { case energy, health, healthspan, weight }

/// Food, weight and the body pages that used to live under Body.
struct FuelTab: View {
    @State private var path: [FuelPage] = LaunchArgs.page.flatMap { ["energy": FuelPage.energy, "health": .health, "healthspan": .healthspan, "weight": .weight][$0] }.map { [$0] } ?? []
    var body: some View {
        NavigationStack(path: $path) {
            FuelHome()
                .navigationDestination(for: FuelPage.self) { p in
                    switch p {
                    case .energy: EnergyPage()
                    case .health: HealthMonitorPage()
                    case .healthspan: HealthspanPage()
                    case .weight: WeightFoodPage()
                    }
                }
                .navigationDestination(for: TodayPage.self) { todayDestination($0) }
        }
    }
}

struct FuelHome: View {
    @Environment(AppModel.self) private var model
    @State private var day = DayKey.today()
    @State private var logging = false
    @State private var editing: LoggedMeal?

    var body: some View {
        let meals = model.meals(on: day)
        let budget = model.budget
        let eaten = meals.reduce(Nutrients()) { $0 + $1.totals }
        EmberPage {
            header
            BudgetCard(eaten: eaten, budget: budget, rate: model.settings.goalRateKgPerWeek)
            MacroBars(eaten: eaten, budget: budget)
            Section9(title: Fmt.dayTitle(day) == "Today" ? "Today" : Fmt.dayTitle(day),
                     info: "Each meal sits at the time you ate it, sized by its calories. Tap one to change it.",
                     trailing: meals.isEmpty ? nil : "\(meals.count) logged") {
                DayTimeline(meals: meals, isToday: day == DayKey.today()) { editing = $0 }
                if meals.isEmpty {
                    Button { logging = true } label: {
                        Text("Log your first meal").font(.system(size: 13, weight: .medium)).foregroundStyle(Ember.ember)
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 0) { ForEach(meals) { m in MealRow(meal: m) { editing = m } } }
                }
            }
            weightLink(budget)
            foodEffects
            bodySection
        }
        .sheet(isPresented: $logging) { LogMealSheet(existing: nil, day: day) }
        .sheet(item: $editing) { LogMealSheet(existing: $0, day: day) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { day = DayKey.addDays(day, -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Text(Fmt.dayTitle(day)).font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Button { day = DayKey.addDays(day, 1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= DayKey.today()).opacity(day >= DayKey.today() ? 0.25 : 1)
                .accessibilityLabel("Next day")
            Spacer()
            Button { logging = true } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(Ember.ink)
                    .frame(width: 38, height: 38).background(Ember.ember, in: Circle())
            }
            .accessibilityLabel("Log a meal")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Ember.bone)
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    @ViewBuilder private func weightLink(_ b: EnergyBudget?) -> some View {
        NavigationLink(value: FuelPage.weight) {
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label9("Trend weight")
                        if let w = b?.trendWeightKg {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(String(format: "%.1f", w)).font(.light(24)).monospacedDigit()
                                Text("kg").font(.light(12)).foregroundStyle(Ember.bone3)
                            }
                            Text(b?.weeklyRateKg.map { String(format: "%+.2f kg/week over 4 weeks", $0) } ?? "Rate after a few more weigh-ins")
                                .font(.system(size: 11.5)).foregroundStyle(Ember.bone2)
                        } else {
                            Text("No weigh-ins yet").font(.system(size: 13)).foregroundStyle(Ember.bone2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Ember.bone3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var foodEffects: some View {
        let food = model.analysis.effects.filter { ["high_protein", "big_dinner", "late_meal", "late_caffeine", "alcohol"].contains($0.factor.id) && $0.outcome == .recovery }
        if !food.isEmpty {
            Section9(title: "Food and your mornings", info: "How each eating pattern relates to next-morning recovery, holding your other habits steady.") {
                VStack(spacing: 0) {
                    let scale = max(food.map { abs($0.effect) + $0.ci }.max() ?? 8, 4)
                    ForEach(food) { ForestRow(effect: $0, scale: scale, unit: "pts") }
                }
            }
        }
    }

    private var bodySection: some View {
        Section9(title: "Body") {
            VStack(spacing: 10) {
                FuelLink(page: .energy, title: "Energy and stress",
                         detail: model.analysis.stressEnergy?.current.map { String(format: "%.0f left in the bank", $0) } ?? "Once today's heart rate syncs")
                FuelLink(page: .health, title: "Health monitor", detail: model.today.map { "Illness watch: \($0.illness.level.title.lowercased())" } ?? "")
                FuelLink(page: .healthspan, title: "Healthspan",
                         detail: model.analysis.healthspan.map { String(format: "Body age %.1f", $0.bodyAge) } ?? "Body age and pace of aging")
            }
            GlassCard {
                InfoLabel(text: "Breathe", info: "Box breathing: in for 4 seconds, hold 4, out 4, hold 4. Slow breathing raises HRV in the moment and helps bring a racing heart down.")
                BreathingView()
            }
        }
    }
}

struct FuelLink: View {
    let page: FuelPage
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

// MARK: Budget

struct BudgetCard: View {
    let eaten: Nutrients
    let budget: EnergyBudget?
    let rate: Double?
    @State private var shown = false

    var body: some View {
        let target = budget?.targetKcal ?? budget?.burnKcal
        let left = target.map { $0 - eaten.kcal }
        GlassCard {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Ember.hair, lineWidth: 9)
                    Circle().trim(from: 0, to: shown ? min(eaten.kcal / max(target ?? 1, 1), 1) : 0)
                        .stroke(left.map { $0 < 0 } == true ? Ember.bone : Ember.ember, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(left.map { "\(Int(abs($0).rounded()))" } ?? "\(Int(eaten.kcal))").font(.light(30)).monospacedDigit().tracking(-1)
                        Text(left.map { $0 < 0 ? "KCAL OVER" : "KCAL LEFT" } ?? "KCAL").font(.mono(8, .semibold)).foregroundStyle(Ember.bone3)
                    }
                }
                .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 9) {
                    stat("Eaten", Int(eaten.kcal.rounded()))
                    if let target { stat(budget?.targetKcal != nil ? "Target" : "Burn", Int(target.rounded())) }
                    Text(basisNote).font(.system(size: 11)).foregroundStyle(Ember.bone2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.1).delay(0.1)) { shown = true } }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ v: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label9(label)
            Text(v.formatted()).font(.light(19)).monospacedDigit()
        }
    }

    private var basisNote: String {
        guard let b = budget else { return "Targets appear after your first weigh-in." }
        let pace = rate.map { String(format: "for %+.2g kg/week", $0) } ?? "no goal set"
        if b.targetFloored { return "Held at a safe minimum; your goal pace would go lower." }
        switch b.basis {
        case .estimated: return "Estimated from your size and band activity, \(pace). Sharpens as you log."
        case .learning(let n): return "Learning your real burn from \(n) logged days, \(pace)."
        case .learned: return "From your own intake and weight trend, \(pace)."
        }
    }
}

struct MacroBars: View {
    let eaten: Nutrients
    let budget: EnergyBudget?
    var body: some View {
        VStack(spacing: 0) {
            row("Protein", eaten.protein, budget?.proteinG, accent: true)
            row("Carbs", eaten.carb, budget?.carbG)
            row("Fat", eaten.fat, budget?.fatG)
            row("Fiber", eaten.fiber, budget?.fiberG)
        }
    }

    private func row(_ name: String, _ v: Double, _ target: Double?, accent: Bool = false) -> some View {
        MetricRow(name: name, value: target.map { "\(Int(v.rounded())) / \(Int($0.rounded())) g" } ?? "\(Int(v.rounded())) g",
                  fraction: target.map { v / max($0, 1) } ?? 0, accent: accent)
    }
}

// MARK: Day timeline

/// The day from 6am to midnight, each meal a dot at its time sized by calories.
struct DayTimeline: View {
    let meals: [LoggedMeal]
    let isToday: Bool
    let tap: (LoggedMeal) -> Void
    static let startHour = 6.0, endHour = 24.0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, mid = g.size.height / 2 - 6
            let x: (Date) -> CGFloat = { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
                return CGFloat((min(max(h, Self.startHour), Self.endHour) - Self.startHour) / (Self.endHour - Self.startHour)) * w
            }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Ember.hair).frame(width: w, height: 2).position(x: w / 2, y: mid)
                ForEach([6, 12, 18, 24], id: \.self) { h in
                    Text(h == 24 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                        .font(.mono(8.5)).foregroundStyle(Ember.bone3)
                        .position(x: min(max(CGFloat((Double(h) - Self.startHour) / (Self.endHour - Self.startHour)) * w, 10), w - 10), y: g.size.height - 6)
                }
                if isToday {
                    Rectangle().fill(Ember.bone2).frame(width: 1, height: 22).position(x: x(Date()), y: mid)
                }
                ForEach(meals) { m in
                    let d = CGFloat(10 + min(m.totals.kcal, 1200) / 1200 * 30)
                    Button { tap(m) } label: {
                        Circle().fill(Ember.ember.opacity(0.92)).frame(width: d, height: d)
                            .overlay(Circle().stroke(Ember.ink, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .position(x: x(m.time), y: mid)
                    .accessibilityLabel("\(m.title), \(Int(m.totals.kcal)) calories at \(Fmt.clock(m.time))")
                }
            }
        }
        .frame(height: 64)
    }
}

struct MealRow: View {
    let meal: LoggedMeal
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Text(Fmt.clock(meal.time)).font(.mono(10)).foregroundStyle(Ember.bone3).frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.title).font(.system(size: 13.5)).lineLimit(1)
                    Text("\(Int(meal.totals.protein.rounded())) g protein · \(Int(meal.totals.carb.rounded())) carbs · \(Int(meal.totals.fat.rounded())) fat")
                        .font(.system(size: 11)).foregroundStyle(Ember.bone2)
                }
                Spacer()
                Text("\(Int(meal.totals.kcal.rounded()))").font(.light(16)).monospacedDigit()
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
