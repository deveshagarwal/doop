import Foundation

/// One food from USDA FNDDS 2021–2023 (public domain): nutrients per 100 g and its standard portions.
public struct FoodItem: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let per100: Nutrients
    /// ("1 cup", 244 g) pairs as USDA lists them; "Quantity not specified" is a typical single serving.
    public let portions: [Portion]

    public struct Portion: Sendable, Hashable {
        public let label: String
        public let grams: Double
    }

    /// Portions worth offering in a picker, typical serving first.
    public var pickerPortions: [Portion] {
        let typical = portions.first { $0.label == "Quantity not specified" }.map { Portion(label: "Typical serving", grams: $0.grams) }
        return ([typical].compactMap { $0 } + portions.filter { $0.label != "Quantity not specified" }).filter { $0.grams > 0 }
    }

    public var typicalGrams: Double { portions.first { $0.label == "Quantity not specified" }?.grams ?? 100 }
}

/// Calories and the nutrients DOOP tracks. Per 100 g in the database; absolute once scaled to a portion.
public struct Nutrients: Codable, Sendable, Hashable {
    public var kcal = 0.0, protein = 0.0, carb = 0.0, fat = 0.0, fiber = 0.0, sugar = 0.0
    /// mg
    public var sodium = 0.0, caffeine = 0.0
    /// g of ethanol
    public var alcohol = 0.0

    public init() {}

    public func scaled(_ f: Double) -> Nutrients {
        var n = self
        n.kcal *= f; n.protein *= f; n.carb *= f; n.fat *= f; n.fiber *= f; n.sugar *= f
        n.sodium *= f; n.caffeine *= f; n.alcohol *= f
        return n
    }

    public static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        var n = a
        n.kcal += b.kcal; n.protein += b.protein; n.carb += b.carb; n.fat += b.fat; n.fiber += b.fiber; n.sugar += b.sugar
        n.sodium += b.sodium; n.caffeine += b.caffeine; n.alcohol += b.alcohol
        return n
    }
}

/// The bundled food database with text search and amount parsing. Everything runs on the phone.
public final class FoodDatabase: Sendable {
    public let foods: [FoodItem]
    private let byID: [Int: Int]
    private let docs: [[String: Int]]
    private let docLength: [Double]
    private let df: [String: Int]
    private let avgLength: Double

    /// `data` is the bundled foods.json: [{id, name, per100: {kcal, protein, ...}, portions: [[label, grams]]}].
    public init(json data: Data) throws {
        struct Raw: Decodable { let id: Int; let name: String; let per100: [String: Double]; let portions: [[Cell]] }
        enum Cell: Decodable {
            case s(String), d(Double)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let x = try? c.decode(Double.self) { self = .d(x) } else { self = .s(try c.decode(String.self)) }
            }
        }
        let raw = try JSONDecoder().decode([Raw].self, from: data)
        foods = raw.map { r in
            var n = Nutrients()
            n.kcal = r.per100["kcal"] ?? 0; n.protein = r.per100["protein"] ?? 0; n.carb = r.per100["carb"] ?? 0
            n.fat = r.per100["fat"] ?? 0; n.fiber = r.per100["fiber"] ?? 0; n.sugar = r.per100["sugar"] ?? 0
            n.sodium = r.per100["sodium"] ?? 0; n.caffeine = r.per100["caffeine"] ?? 0; n.alcohol = r.per100["alcohol"] ?? 0
            let portions = r.portions.compactMap { p -> FoodItem.Portion? in
                guard p.count == 2, case .s(let l) = p[0], case .d(let g) = p[1] else { return nil }
                return .init(label: l, grams: g)
            }
            return FoodItem(id: r.id, name: r.name, per100: n, portions: portions)
        }
        var byID: [Int: Int] = [:], docs: [[String: Int]] = [], lens: [Double] = [], df: [String: Int] = [:]
        for (i, f) in foods.enumerated() {
            byID[f.id] = i
            let t = Self.tokens(f.name)
            var tf: [String: Int] = [:]
            for w in t { tf[w, default: 0] += 1 }
            for w in Set(t) { df[w, default: 0] += 1 }
            docs.append(tf); lens.append(Double(t.count))
        }
        self.byID = byID; self.docs = docs; self.docLength = lens; self.df = df
        avgLength = lens.reduce(0, +) / Double(max(lens.count, 1))
    }

    public func food(id: Int) -> FoodItem? { byID[id].map { foods[$0] } }

    /// BM25 ranking over USDA food names, lightly preferring plain foods over long mixed-dish names.
    public func search(_ query: String, limit: Int = 8) -> [FoodItem] {
        let q = Self.tokens(query)
        guard !q.isEmpty else { return [] }
        let n = Double(foods.count)
        var scored: [(Int, Double)] = []
        for i in docs.indices {
            var s = 0.0
            for w in q {
                guard let tf = docs[i][w], let d = df[w] else { continue }
                let idf = log(1 + (n - Double(d) + 0.5) / (Double(d) + 0.5))
                s += idf * Double(tf) * 2.2 / (Double(tf) + 1.2 * (0.25 + 0.75 * docLength[i] / avgLength))
            }
            if s > 0 { scored.append((i, s - 0.02 * docLength[i])) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { foods[$0.0] }
    }

    static let stopWords: Set<String> = ["a", "an", "the", "of", "and", "with", "or", "in", "on", "to", "for", "from", "my", "at", "some", "nfs", "ns", "as"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { w in
                if w.hasSuffix("es"), w.count > 4 { return String(w.dropLast(2)) }
                if w.hasSuffix("s"), w.count > 3 { return String(w.dropLast()) }
                return w
            }
    }
}

// MARK: - Amounts

/// Turns what someone typed ("2 large", "a medium slice", "12 fl oz", "150 g") into grams of a given food,
/// using that food's USDA portion list. Validated on NutriBench (WWEIA meals): rules beat the on-device
/// model at this step by a wide margin.
public enum PortionParser {
    static let numberWords: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                                "half": 0.5, "½": 0.5, "¼": 0.25, "quarter": 0.25, "couple": 2, "few": 3, "dozen": 12]
    static let sizeWords: Set<String> = ["small", "medium", "large", "extra", "jumbo", "regular", "mini", "king", "snack", "fun", "thin", "thick"]
    static let aliases: [String: String] = ["tbsp": "tablespoon", "tbs": "tablespoon", "tsp": "teaspoon", "cups": "cup", "slices": "slice",
                                            "pieces": "piece", "bottles": "bottle", "cans": "can", "bars": "bar", "tablespoons": "tablespoon",
                                            "teaspoons": "teaspoon", "glass": "cup", "mug": "cup", "bowl": "cup", "packets": "packet", "bags": "bag",
                                            "sticks": "stick", "links": "link", "patties": "patty", "strips": "strip", "wings": "wing", "eggs": "egg"]

    public struct Parsed: Equatable {
        public var count: Double
        public var words: [String]
        public var grams: Double?
        public init(count: Double, words: [String], grams: Double?) { self.count = count; self.words = words; self.grams = grams }
    }

    public static func parse(_ amount: String) -> Parsed {
        let low = amount.lowercased()
            .replacingOccurrences(of: "fluid ounce", with: "floz").replacingOccurrences(of: "fl oz", with: "floz")
        let raw = low.components(separatedBy: CharacterSet(charactersIn: " ,-()")).filter { !$0.isEmpty }
        var count: Double?, words: [String] = [], grams: Double?
        for (i, w) in raw.enumerated() {
            if let n = number(w) {
                let next = i + 1 < raw.count ? raw[i + 1] : ""
                switch next {
                case "g", "gram", "grams", "ml": grams = n; continue
                case "oz", "ounce", "ounces": grams = n * 28.35; continue
                case "lb", "lbs", "pound", "pounds": grams = n * 453.6; continue
                case "kg": grams = n * 1000; continue
                default: break
                }
                if w == "a" || w == "an" { if count == nil { count = 1 }; continue }
                count = (count ?? 1) * n
                continue
            }
            if w.hasSuffix("g"), w.count > 1, let g = Double(w.dropLast()) { grams = g; continue }
            if w.hasSuffix("oz"), w.count > 2, let o = Double(w.dropLast(2)) { grams = o * 28.35; continue }
            words.append(aliases[w] ?? w)
        }
        return Parsed(count: count ?? 1, words: words, grams: grams)
    }

    static func number(_ w: String) -> Double? {
        if let n = Double(w) ?? numberWords[w] { return n }
        let parts = w.split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : nil
    }

    /// Grams for `amount` of `food`, plus the USDA portion it matched (nil when it fell back to a typical serving).
    public static func grams(of food: FoodItem, amount: String, name: String = "") -> (grams: Double, portion: FoodItem.Portion?) {
        var p = parse(amount)
        if let g = p.grams { return (g, nil) }
        p.words += name.lowercased().split(separator: " ").map(String.init).filter { sizeWords.contains($0) }
        let wanted = Set(p.words)
        var best: (score: Double, perUnit: Double, portion: FoodItem.Portion)?
        for portion in food.portions where portion.label != "Quantity not specified" {
            let t = portion.label.lowercased().replacingOccurrences(of: "fl oz", with: "floz")
                .components(separatedBy: CharacterSet(charactersIn: " ,-()")).filter { !$0.isEmpty }
            let lead = t.first.flatMap(number) ?? 1
            let have = Set(t.map { aliases[$0] ?? $0 })
            let hits = wanted.intersection(have)
            guard !hits.isEmpty else { continue }
            var score = Double(hits.count) * 2 + Double(hits.filter { !sizeWords.contains($0) }.count)
            if wanted.contains(where: sizeWords.contains), !have.contains(where: sizeWords.contains) { score -= 0.5 }
            score -= Double(t.count) * 0.05
            if best == nil || score > best!.score { best = (score, portion.grams / max(lead, 0.01), portion) }
        }
        if let b = best { return (b.perUnit * p.count, b.portion) }
        if wanted.contains("floz") { return (p.count * 29.6, nil) }
        return (food.typicalGrams * p.count, nil)
    }
}
