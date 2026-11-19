import Foundation

/// The few numbers the lock-screen and home-screen widgets show, shared through the App Group.
struct WidgetSnapshot: Codable {
    var recovery: Int?
    var zone: String?
    var strain: Double
    var strainTarget: Double?
    var bedtime: Date?
    var updated: Date

    static let appGroup = "group.com.dagarwal.baseline"
    static let key = "widget.snapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

