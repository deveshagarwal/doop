import Foundation
import FoundationModels

/// Typed meal → foods with amounts → USDA matches → grams and nutrients. Runs on the phone with Apple's on-device model.
///
/// Tested on NutriBench (USDA WWEIA meals in everyday words): splitting with the model, picking the database entry
/// with the model from a short list, and reading portions with rules (`PortionParser`) beat asking the model for
/// calories directly (median miss 60 vs 91 kcal on 200 meals).
@MainActor
final class MealParser {
    let db: FoodDatabase
    init(db: FoodDatabase) { self.db = db }

    @Generable struct Item {
        @Guide(description: "Generic food name in USDA style, e.g. 'pizza, pepperoni, thin crust' or 'milk, chocolate, low fat'")
        let food: String
        @Guide(description: "How it was prepared or which form, if said (fried, grilled, raw, diet, whole wheat). Empty if not said.")
        let form: String
        @Guide(description: "The amount as said, e.g. '1 slice', '12 fl oz', '2 large', '1 cup', '150 g'. '1' if no amount was said.")
        let amount: String
    }
    @Generable struct Parsed { let items: [Item] }
    @Generable struct Pick {
        @Guide(description: "Number of the best matching food from the list")
        let pick: Int
    }

    static let splitInstructions = """
    List the separate foods and drinks in the meal, each once.
    A dish described with its fillings, toppings, sauce or ingredients is ONE item: 'a cup of pasta with tomato sauce, meat and vegetables' is one item 'pasta with tomato sauce and meat'; 'a burrito with meat and beans' is one item.
    Only list items actually mentioned. Brand names stay whole ('3 Musketeers bar' is one bar).
    Put size words (small, medium, large, fun-size) and units in the amount. A single item with no amount gets amount '1'.
    """

    var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Items for `text`, each with the database's best match and alternatives for the review screen.
    func parse(_ text: String) async -> [Draft] {
        let pieces: [(food: String, form: String, amount: String)]
        if modelAvailable, let p = try? await LanguageModelSession(instructions: Self.splitInstructions)
            .respond(to: text, generating: Parsed.self, options: GenerationOptions(temperature: 0)).content {
            var seen = Set<String>()
            pieces = p.items.filter { seen.insert($0.food.lowercased() + "|" + $0.amount.lowercased()).inserted }
                .map { ($0.food, $0.form, $0.amount) }
        } else {
            pieces = Self.roughSplit(text)
        }
        var drafts: [Draft] = []
        for piece in pieces {
            let candidates = db.search(piece.food + " " + piece.form, limit: 8)
            guard !candidates.isEmpty else { continue }
            var chosen = candidates[0]
            if modelAvailable, candidates.count > 1 {
                let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
                if let r = try? await LanguageModelSession(instructions: "Match a food someone ate to a database entry.")
                    .respond(to: "Food eaten: \(piece.food) (\(piece.form)), amount: \(piece.amount)\nDatabase foods:\n\(list)",
                             generating: Pick.self, options: GenerationOptions(temperature: 0)).content,
                   (1...candidates.count).contains(r.pick) {
                    chosen = candidates[r.pick - 1]
                }
            }
            let (grams, portion) = PortionParser.grams(of: chosen, amount: piece.amount, name: piece.food)
            drafts.append(Draft(said: piece.food, item: LoggedItem(food: chosen, amount: Self.display(piece.amount, portion: portion, grams: grams), grams: grams),
                                alternatives: candidates))
        }
        return drafts
    }

    /// Fallback when Apple Intelligence is off: split on commas and "and", leading numbers as amounts.
    static func roughSplit(_ text: String) -> [(food: String, form: String, amount: String)] {
        text.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: " with ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { s in
                let words = s.split(separator: " ")
                if let first = words.first, PortionParser.number(String(first).lowercased()) != nil, words.count > 1 {
                    return (words.dropFirst().joined(separator: " "), "", String(first))
                }
                return (s, "", "1")
            }
    }

    static func display(_ amount: String, portion: FoodItem.Portion?, grams: Double) -> String {
        let a = amount.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || a == "1", let p = portion { return p.label }
        if a.isEmpty || a == "1" { return "1 serving" }
        return a
    }

    /// One parsed food on the review screen.
    struct Draft: Identifiable {
        var id: UUID { item.id }
        /// What the model heard, e.g. "fried chicken thigh".
        let said: String
        var item: LoggedItem
        /// Other database matches to swap to.
        let alternatives: [FoodItem]
    }
}
