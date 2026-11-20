import Foundation

public struct JournalFactor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var symbol: String
    /// Where the app learns about it without you logging anything.
    public var source: String

    public init(id: String, label: String, symbol: String, source: String) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "tag"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "You"
    }

    /// Every factor the app tracks. All but alcohol are detected automatically;
    /// alcohol is suspected from overnight heart rate and confirmed with one yes/no.
    public static let all: [JournalFactor] = [
        .init(id: "alcohol", label: "Alcohol", symbol: "wineglass", source: "Overnight heart rate · you confirm"),
        .init(id: "late_meal", label: "Late meal", symbol: "fork.knife", source: "Food log"),
        .init(id: "late_caffeine", label: "Caffeine after 2pm", symbol: "cup.and.saucer", source: "Food log"),
        .init(id: "late_workout", label: "Late workout", symbol: "figure.run", source: "Fitbit"),
        .init(id: "late_meeting", label: "Meeting past 7pm", symbol: "calendar", source: "Calendar"),
        .init(id: "packed_day", label: "Packed calendar", symbol: "calendar.badge.clock", source: "Calendar"),
        .init(id: "hot_night", label: "Hot night", symbol: "thermometer.sun", source: "Weather"),
        .init(id: "travel", label: "Travel", symbol: "airplane", source: "Time zone"),
        .init(id: "mindful", label: "Mindful minutes", symbol: "brain.head.profile", source: "Apple Health"),
        .init(id: "high_protein", label: "140g+ protein", symbol: "fish", source: "Food log"),
        .init(id: "big_dinner", label: "Big dinner", symbol: "takeoutbag.and.cup.and.straw", source: "Food log"),
        .init(id: "high_stress", label: "Stressful day", symbol: "waveform.path.ecg", source: "Heart rate vs movement"),
    ]

    public static func named(_ id: String) -> JournalFactor? { all.first { $0.id == id } }
}

/// Answers you gave (only ever the one daily question) plus anything you chose to add.
/// Automatic factors are recomputed from data every time, never stored.
public struct JournalEntry: Codable, Sendable {
    public var date: String
    /// Factors confirmed present.
    public var factors: Set<String>
    /// Factors you said did NOT happen (overrides a detector's guess).
    public var denied: Set<String>
    public var note: String

    public init(date: String, factors: Set<String> = [], denied: Set<String> = [], note: String = "") {
        self.date = date
        self.factors = factors
        self.denied = denied
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        factors = try c.decodeIfPresent(Set<String>.self, forKey: .factors) ?? []
        denied = try c.decodeIfPresent(Set<String>.self, forKey: .denied) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

