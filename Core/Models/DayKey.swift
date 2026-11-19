import Foundation

/// Calendar-day keys in "yyyy-MM-dd" form, local time zone.
public enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    public static func string(from date: Date) -> String { formatter.string(from: date) }

    /// Local midnight of the day.
    public static func date(from key: String) -> Date? { formatter.date(from: key) }

    public static func today() -> String { string(from: Date()) }

    public static func addDays(_ key: String, _ n: Int) -> String {
        guard let d = date(from: key),
              let shifted = Calendar.current.date(byAdding: .day, value: n, to: d) else { return key }
        return string(from: shifted)
    }

    /// Every day from `from` to `to`, inclusive.
    public static func keys(from: String, to: String) -> [String] {
        guard var current = date(from: from), let end = date(from: to), current <= end else { return [] }
        var result: [String] = []
        while current <= end {
            result.append(string(from: current))
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return result
    }

    /// Assigns an overnight measurement to the day you woke up:
    /// anything after 18:00 counts toward the next day.
    public static func nightKey(for time: Date) -> String {
        string(from: time.addingTimeInterval(6 * 3600))
    }

    public static func shortLabel(_ key: String) -> String {
        guard let d = date(from: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: d)
    }
}
