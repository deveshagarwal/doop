import SwiftUI

/// Log or edit a meal: type it, check every food, amount and number, then save.
struct LogMealSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: LoggedMeal?
    let day: String

    @State private var text = ""
    @State private var time = Date()
    @State private var rows: [Row] = []
    @State private var parsing = false
    @State private var searching = false
    @State private var confirmDelete = false
    @FocusState private var typing: Bool

    /// One food on the review list: the item plus what's needed to recalculate it when the amount changes.
    struct Row: Identifiable {
        var item: LoggedItem
        var food: FoodItem?
        var portion: FoodItem.Portion
        var count: Double
        var alternatives: [FoodItem]
        var id: UUID { item.id }

        static let grams = FoodItem.Portion(label: "grams", grams: 1)

        /// Rebuild grams and numbers from the portion and count, dropping any typed-over numbers.
        mutating func recalc() {
            guard let food else { return }
            let g = portion.grams * count
            let amount = portion.label == "grams" ? "\(Int(g.rounded())) g" : "\(Self.countLabel(count)) × \(portion.label)"
            var fresh = LoggedItem(food: food, amount: amount, grams: g)
            fresh.id = item.id
            item = fresh
        }

        static func countLabel(_ c: Double) -> String {
            c == c.rounded() ? "\(Int(c))" : String(format: "%g", (c * 100).rounded() / 100)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    input
                    if rows.isEmpty && !parsing && existing == nil { recents }
                    if parsing { ProgressView("Finding foods…").tint(Ember.ember).frame(maxWidth: .infinity).padding(.vertical, 20) }
                    if !rows.isEmpty { review }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ember.ink.ignoresSafeArea())
            .foregroundStyle(Ember.bone)
            .navigationTitle(existing == nil ? LoggedMeal.label(for: time) : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Log" : "Save") { save() }.disabled(rows.isEmpty).fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $searching) { FoodSearchSheet { add($0) } }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete meal", role: .destructive) { if let existing { model.deleteMeal(existing) }; dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ember.ember)
        .onAppear(perform: load)
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What did you eat? e.g. 2 eggs, sourdough toast and an oat latte", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 16))
                .focused($typing)
                .padding(14)
                .background(Ember.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .submitLabel(.done)
                .onSubmit(find)
            HStack(spacing: 8) {
                Button(action: find) {
                    Label(rows.isEmpty ? "Find foods" : "Find again", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ember.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9).background(Ember.ember, in: Capsule())
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || parsing)
                chip("Search", "magnifyingglass") { searching = true }
                chip("Quick add", "plus") { quickAdd() }
                Spacer()
            }
            .buttonStyle(.plain)
            if model.mealParser?.modelAvailable == false {
                Text("Apple Intelligence is off, so DOOP splits your text more simply. Turn it on in Settings for better matching.")
                    .font(.system(size: 11)).foregroundStyle(Ember.bone3)
            }
        }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 9).background(Ember.glass, in: Capsule())
        }
    }

    @ViewBuilder private var recents: some View {
        let recent = model.recentMeals
        if !recent.isEmpty {
            Section9(title: "Again") {
                VStack(spacing: 0) {
                    ForEach(recent) { m in
                        Button {
                            text = m.text
                            rows = m.items.map { row(for: $0) }
                        } label: {
                            HStack {
                                Text(m.title).font(.system(size: 13.5)).lineLimit(1)
                                Spacer()
                                Text("\(Int(m.totals.kcal.rounded()))").font(.light(15)).monospacedDigit().foregroundStyle(Ember.bone2)
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Review

    private var review: some View {
        let t = rows.reduce(Nutrients()) { $0 + $1.item.nutrients }
        return VStack(alignment: .leading, spacing: 14) {
            Trio(items: [("Calories", "\(Int(t.kcal.rounded()))", nil), ("Protein", "\(Int(t.protein.rounded())) g", nil),
                         ("Carbs · fat", "\(Int(t.carb.rounded())) · \(Int(t.fat.rounded()))", nil)])
            ForEach($rows) { $r in
                ItemEditor(row: $r) { rows.removeAll { $0.id == r.id } }
            }
            Button { searching = true } label: {
                Label("Add a food", systemImage: "plus.circle").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Ember.ember)
            DatePicker("Time", selection: $time, displayedComponents: [.date, .hourAndMinute])
                .font(.system(size: 14))
            Text("Nothing is saved until you tap \(existing == nil ? "Log" : "Save"). Change any amount or number above if something's off.")
                .font(.system(size: 11)).foregroundStyle(Ember.bone3)
            if existing != nil {
                Button("Delete meal", role: .destructive) { confirmDelete = true }.font(.system(size: 14))
            }
        }
    }

    // MARK: Actions

    private func load() {
        if let e = existing {
            text = e.text
            time = e.time
            rows = e.items.map { row(for: $0) }
        } else {
            // Logging on a past day defaults to that day at the current time.
            if day != DayKey.today(), let d = DayKey.date(from: day) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                time = Calendar.current.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: d) ?? d
            }
            typing = true
        }
    }

    private func row(for item: LoggedItem) -> Row {
        let food = item.foodID.flatMap { model.foodDB?.food(id: $0) }
        let portion = food?.pickerPortions.first { item.amount.hasSuffix($0.label) } ?? Row.grams
        let count = portion.grams > 0 ? item.grams / portion.grams : 1
        return Row(item: item, food: food, portion: portion, count: max(count, 0), alternatives: [])
    }

    private func find() {
        guard let parser = model.mealParser else { return }
        let q = text
        typing = false
        parsing = true
        Task {
            let drafts = await parser.parse(q)
            rows = drafts.map { d in
                let food = d.item.foodID.flatMap { model.foodDB?.food(id: $0) }
                let match = food.flatMap { f in PortionParser.grams(of: f, amount: d.item.amount).portion }
                let portion = match ?? food?.pickerPortions.first ?? Row.grams
                return Row(item: d.item, food: food, portion: portion, count: portion.grams > 0 ? d.item.grams / portion.grams : 1,
                           alternatives: d.alternatives)
            }
            parsing = false
        }
    }

    private func add(_ food: FoodItem) {
        let p = food.pickerPortions.first ?? Row.grams
        var r = Row(item: LoggedItem(food: food, amount: p.label, grams: p.grams), food: food, portion: p, count: 1, alternatives: [])
        r.recalc()
        rows.append(r)
    }

    private func quickAdd() {
        rows.append(Row(item: LoggedItem(name: "Quick add", foodID: nil, amount: "1 serving", grams: 0, nutrients: Nutrients()),
                        food: nil, portion: Row.grams, count: 0, alternatives: []))
    }

    private func save() {
        var meal = existing ?? LoggedMeal(time: time, text: text, items: [], source: .text)
        meal.time = time
        meal.text = text
        meal.items = rows.map(\.item)
        model.saveMeal(meal)
        dismiss()
    }
}

/// One food on the review list: swap the match, change the amount, or type over any number.
struct ItemEditor: View {
    @Binding var row: LogMealSheet.Row
    let remove: () -> Void
    @State private var swapping = false

    var body: some View {
        GlassCard {
            HStack(alignment: .top) {
                if row.food != nil {
                    Menu {
                        ForEach(row.alternatives.filter { $0.id != row.food?.id }, id: \.id) { f in
                            Button(f.name) { row.food = f; row.portion = f.pickerPortions.first ?? LogMealSheet.Row.grams; row.count = 1; row.recalc() }
                        }
                        Button("Search the database…") { swapping = true }
                    } label: {
                        Text(row.item.name).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.leading)
                            .foregroundStyle(Ember.bone)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Ember.bone3)
                    }
                } else {
                    TextField("Name", text: $row.item.name).font(.system(size: 14, weight: .medium))
                }
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Ember.bone3).accessibilityLabel("Remove \(row.item.name)")
            }
            if let food = row.food {
                HStack(spacing: 10) {
                    Stepper(value: Binding(get: { row.count }, set: { row.count = max($0, 0); row.recalc() }),
                            in: 0...5000, step: row.portion.label == "grams" ? 10 : 0.25) {
                        Text(LogMealSheet.Row.countLabel(row.count)).font(.light(17)).monospacedDigit()
                    }
                    .fixedSize()
                    Menu {
                        ForEach(food.pickerPortions + [LogMealSheet.Row.grams], id: \.self) { p in
                            Button("\(p.label) · \(Int(p.grams.rounded())) g") {
                                let g = row.portion.grams * row.count
                                row.portion = p
                                row.count = p.label == "grams" ? g.rounded() : 1
                                row.recalc()
                            }
                        }
                    } label: {
                        Text(row.portion.label).font(.system(size: 12.5)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Ember.hair, in: Capsule())
                    }
                    Spacer()
                    Text("\(Int(row.item.grams.rounded())) g").font(.mono(10)).foregroundStyle(Ember.bone3)
                }
            }
            HStack(spacing: 8) {
                number("kcal", \.kcal)
                number("protein", \.protein)
                number("carbs", \.carb)
                number("fat", \.fat)
            }
            if row.item.edited {
                Text("Edited by you. Changing the amount recalculates from the database.").font(.system(size: 10.5)).foregroundStyle(Ember.bone3)
            }
        }
        .sheet(isPresented: $swapping) {
            FoodSearchSheet(initial: row.item.name) { f in
                row.food = f; row.portion = f.pickerPortions.first ?? LogMealSheet.Row.grams; row.count = 1; row.recalc()
            }
        }
    }

    private func number(_ label: String, _ kp: WritableKeyPath<Nutrients, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, value: Binding(get: { (row.item.nutrients[keyPath: kp] * 10).rounded() / 10 },
                                            set: { row.item.nutrients[keyPath: kp] = $0; row.item.edited = true }),
                      format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .font(.light(16)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Ember.hair, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label.uppercased()).font(.mono(7.5, .semibold)).foregroundStyle(Ember.bone3)
        }
    }
}

/// Search the USDA database by name.
struct FoodSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initial = ""
    let pick: (FoodItem) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.foodDB?.search(query, limit: 30) ?? [], id: \.id) { f in
                    Button {
                        pick(f)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.system(size: 14)).foregroundStyle(Ember.bone)
                            Text("\(Int(f.per100.kcal)) kcal · \(Int(f.per100.protein)) g protein per 100 g").font(.system(size: 11)).foregroundStyle(Ember.bone2)
                        }
                    }
                    .listRowBackground(Ember.ink)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Ember.ink.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Add a food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if query.isEmpty { query = initial } }
        }
        .preferredColorScheme(.dark)
        .tint(Ember.ember)
    }
}
