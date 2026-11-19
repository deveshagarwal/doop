import Foundation

public struct JournalFactor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var symbol: String
    /// Whether the factor is generally expected to help (used only for wording).
    public var expectedPositive: Bool

    public init(id: String, label: String, symbol: String, expectedPositive: Bool) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.expectedPositive = expectedPositive
    }

    public static let defaults: [JournalFactor] = [
        .init(id: "alcohol", label: "Alcohol", symbol: "wineglass", expectedPositive: false),
        .init(id: "late_caffeine", label: "Caffeine after 2pm", symbol: "cup.and.saucer", expectedPositive: false),
        .init(id: "late_meal", label: "Ate within 2h of bed", symbol: "fork.knife", expectedPositive: false),
        .init(id: "screens_in_bed", label: "Screens in bed", symbol: "iphone", expectedPositive: false),
        .init(id: "high_stress", label: "High stress", symbol: "exclamationmark.triangle", expectedPositive: false),
        .init(id: "travel", label: "Traveled", symbol: "airplane", expectedPositive: false),
        .init(id: "feeling_sick", label: "Feeling sick", symbol: "facemask", expectedPositive: false),
        .init(id: "meditation", label: "Meditated", symbol: "brain.head.profile", expectedPositive: true),
        .init(id: "sauna", label: "Sauna", symbol: "flame", expectedPositive: true),
        .init(id: "cold_exposure", label: "Cold exposure", symbol: "snowflake", expectedPositive: true),
        .init(id: "magnesium", label: "Magnesium", symbol: "pills", expectedPositive: true),
        .init(id: "sunlight_am", label: "Morning sunlight", symbol: "sun.max", expectedPositive: true),
        .init(id: "read_before_bed", label: "Read before bed", symbol: "book", expectedPositive: true),
    ]
}

/// What you did on a given day. The effect is measured on the NEXT morning's recovery.
public struct JournalEntry: Codable, Sendable {
    public var date: String
    public var factors: Set<String>
    public var note: String

    public init(date: String, factors: Set<String> = [], note: String = "") {
        self.date = date
        self.factors = factors
        self.note = note
    }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date

    public init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.date = Date()
    }
}
