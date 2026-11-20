import Foundation

/// One food in a logged meal. Numbers come from the database for `grams`, and any you typed over them win.
public struct LoggedItem: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    /// USDA FNDDS id, nil for a quick-add entry.
    public var foodID: Int?
    /// The amount as shown, e.g. "1 cup" or "150 g".
    public var amount: String
    public var grams: Double
    public var nutrients: Nutrients
    /// True once you've typed over a number; changing the amount then asks before recalculating.
    public var edited = false

    public init(name: String, foodID: Int?, amount: String, grams: Double, nutrients: Nutrients) {
        self.name = name
        self.foodID = foodID
        self.amount = amount
        self.grams = grams
        self.nutrients = nutrients
    }

    /// Item for `food` at `grams`, numbers from the database.
    public init(food: FoodItem, amount: String, grams: Double) {
        self.init(name: food.name, foodID: food.id, amount: amount, grams: grams, nutrients: food.per100.scaled(grams / 100))
    }
}

/// A meal you logged in DOOP. Stored on the phone and mirrored to Apple Health.
public struct LoggedMeal: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case text, photo, search, repeatMeal, quick }

    public var id = UUID()
    public var time: Date
    /// What you typed, kept so a meal can be re-parsed or reused.
    public var text: String
    public var items: [LoggedItem]
    public var source: Source

    public init(time: Date, text: String, items: [LoggedItem], source: Source) {
        self.time = time
        self.text = text
        self.items = items
        self.source = source
    }

    public var totals: Nutrients { items.reduce(Nutrients()) { $0 + $1.nutrients } }

    /// Short title for lists: the first two foods.
    public var title: String {
        let names = items.map { Self.shortName($0.name) }
        guard !names.isEmpty else { return text.isEmpty ? "Meal" : text }
        return names.count <= 2 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    /// "Chicken breast, baked or broiled, skin not eaten" → "Chicken breast".
    public static func shortName(_ usda: String) -> String {
        String(usda.split(separator: ",").first ?? Substring(usda)).trimmingCharacters(in: .whitespaces)
    }

    /// Breakfast, lunch, dinner or snack from the time of day.
    public static func label(for date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 4..<11: return "Breakfast"
        case 11..<15: return "Lunch"
        case 17..<22: return "Dinner"
        default: return "Snack"
        }
    }

    /// The analysis engines' view of this meal.
    public var asMeal: Meal {
        let t = totals
        return Meal(time: time, kcal: t.kcal, proteinG: t.protein, caffeineMg: t.caffeine > 0 ? t.caffeine : nil,
                    alcoholG: t.alcohol > 0 ? t.alcohol : nil, carbG: t.carb, fatG: t.fat, fiberG: t.fiber)
    }
}
