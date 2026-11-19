import Foundation

/// Everything the app persists, as one JSON file in Application Support.
/// It never leaves the device except through your own device backups.
public struct StoreSnapshot: Codable, Sendable {
    /// From Apple Health.
    public var days: [String: DayRecord] = [:]
    /// From the Google Health API (HRV and nightly vitals). Kept apart so each source re-syncs cleanly.
    public var googleDays: [String: DayRecord] = [:]
    public var journal: [String: JournalEntry] = [:]
    public var customFactors: [JournalFactor] = []
    public var settings = UserSettings()
    public var chat: [ChatMessage] = []
    public var lastSync: [String: Date] = [:]
    /// Newest sample timestamp seen per source, for the data-freshness readout.
    public var newestSample: [String: Date] = [:]
    public var notifiedAlerts: Set<String> = []

    public init() {}

    /// Tolerates fields added in later versions so an app update never wipes your history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: DayRecord].self, forKey: .days) ?? [:]
        googleDays = try c.decodeIfPresent([String: DayRecord].self, forKey: .googleDays) ?? [:]
        journal = try c.decodeIfPresent([String: JournalEntry].self, forKey: .journal) ?? [:]
        customFactors = try c.decodeIfPresent([JournalFactor].self, forKey: .customFactors) ?? []
        settings = try c.decodeIfPresent(UserSettings.self, forKey: .settings) ?? UserSettings()
        chat = try c.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
        lastSync = try c.decodeIfPresent([String: Date].self, forKey: .lastSync) ?? [:]
        newestSample = try c.decodeIfPresent([String: Date].self, forKey: .newestSample) ?? [:]
        notifiedAlerts = try c.decodeIfPresent(Set<String>.self, forKey: .notifiedAlerts) ?? []
    }

    /// Apple Health as the base, Google filling gaps and supplying HRV.
    public var mergedDays: [String: DayRecord] {
        var out = days
        for (k, g) in googleDays {
            if var base = out[k] { base.merge(g); out[k] = base } else { out[k] = g }
        }
        return out
    }

    public var factors: [JournalFactor] { JournalFactor.defaults + customFactors }
}

public final class Store: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "baseline.store")

    public init(directory: URL? = nil, filename: String = "baseline.json") {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func load() -> StoreSnapshot {
        queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? Self.decoder.decode(StoreSnapshot.self, from: data) else { return StoreSnapshot() }
            return snap
        }
    }

    public func save(_ snapshot: StoreSnapshot) {
        queue.sync {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            #if os(iOS)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: url, options: [.atomic])
            #endif
        }
    }
}
