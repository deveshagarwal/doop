// Adapted from Pulse (https://github.com/Luraxx/pulse), Apache License 2.0. See NOTICE.
import Foundation

public enum APIError: Error, LocalizedError, Sendable {
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse(let m): return "Unexpected response: \(m)"
        }
    }
}

/// Google Health API v4 client. The API launched in 2026 and some field names are still
/// settling, so it tries several read variants per data type (reconcile → list with range →
/// list from start) and remembers which one worked, and it decodes payloads tolerantly.
public final class HealthAPIClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://health.googleapis.com/v4")!
    private let auth: GoogleAuth
    private let config: GoogleOAuthConfig
    private let lock = NSLock()
    private var workingVariant: [String: Int] = [:]
    /// Google allows 300 requests/min per user; stay safely under it.
    private var nextSlot = Date.distantPast

    public init(auth: GoogleAuth, config: GoogleOAuthConfig) {
        self.auth = auth
        self.config = config
    }

    public enum TimeFormat { case physical, civilDate }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// All data points of `type` in the window, paginated.
    public func dataPoints(type: String, payloadKey: String, filterField: String,
                           start: Date, end: Date, format: TimeFormat = .physical) async throws -> [[String: Any]] {
        let field = "\(JSONExtract.snakeCase(payloadKey)).\(filterField)"
        let (s, e) = format == .physical
            ? (Self.iso.string(from: start), Self.iso.string(from: end))
            : (DayKey.string(from: start), DayKey.string(from: end))
        let range = "\(field) >= \"\(s)\" AND \(field) <= \"\(e)\""
        let from = "\(field) >= \"\(s)\""
        let variants: [(filter: String, reconcile: Bool)] = [(range, true), (range, false), (from, false)]

        let order = lock.withLock { workingVariant[type] }.map { [$0] } ?? Array(variants.indices)
        var lastError: Error?
        for i in order {
            do {
                let points = try await paginate(type: type, filter: variants[i].filter, reconcile: variants[i].reconcile)
                lock.withLock { workingVariant[type] = i }
                return points
            } catch APIError.http(let code, let body) where code == 400 || code == 404 {
                lastError = APIError.http(code, body)
            }
        }
        throw lastError ?? APIError.badResponse("no read variant worked")
    }

    private func paginate(type: String, filter: String, reconcile: Bool) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var token: String?
        var pages = 0
        repeat {
            var q = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "pageSize", value: "1000")]
            if let token { q.append(URLQueryItem(name: "pageToken", value: token)) }
            let json = try await get("/users/me/dataTypes/\(type)/dataPoints\(reconcile ? ":reconcile" : "")", q)
            out += (json["dataPoints"] as? [[String: Any]]) ?? (json["data_points"] as? [[String: Any]]) ?? []
            token = json["nextPageToken"] as? String
            pages += 1
        } while token != nil && pages < 60
        return out
    }

    /// Sample-type data (HRV, SpO₂…) as (time, value).
    public func samples(type: String, payloadKey: String, valueKeys: [String], start: Date, end: Date) async throws -> [(Date, Double)] {
        let points = try await dataPoints(type: type, payloadKey: payloadKey, filterField: "sample_time.physical_time", start: start, end: end)
        return points.compactMap { p in
            let payload = (p[payloadKey] as? [String: Any]) ?? p
            guard let v = JSONExtract.firstDouble(in: payload, keys: valueKeys),
                  let t = JSONExtract.firstDate(in: payload, keys: ["physicalTime", "startTime", "time", "endTime"]) else { return nil }
            return (t, v)
        }
    }

    /// Daily-type data (resting HR, respiratory rate…) keyed by "yyyy-MM-dd".
    public func daily(type: String, payloadKey: String, valueKeys: [String], start: Date, end: Date) async throws -> [String: Double] {
        let points = try await dataPoints(type: type, payloadKey: payloadKey, filterField: "date", start: start, end: end, format: .civilDate)
        var out: [String: Double] = [:]
        for p in points {
            let payload = (p[payloadKey] as? [String: Any]) ?? p
            guard let v = JSONExtract.firstDouble(in: payload, keys: valueKeys) else { continue }
            let key = JSONExtract.firstString(in: payload, keys: ["date"])
                ?? JSONExtract.firstDate(in: payload, keys: ["physicalTime", "startTime"]).map(DayKey.string(from:))
            if let key { out[String(key.prefix(10))] = v }
        }
        return out
    }

    public func sleepSessions(start: Date, end: Date) async throws -> [SleepSession] {
        try await dataPoints(type: "sleep", payloadKey: "sleep", filterField: "interval.end_time", start: start, end: end)
            .compactMap(Self.parseSleep)
    }

    static func parseSleep(_ point: [String: Any]) -> SleepSession? {
        let p = (point["sleep"] as? [String: Any]) ?? point
        let interval = (p["interval"] as? [String: Any]) ?? [:]
        guard let start = JSONExtract.date(interval["startTime"]) ?? JSONExtract.firstDate(in: p, keys: ["startTime"]),
              let end = JSONExtract.date(interval["endTime"]) ?? JSONExtract.firstDate(in: p, keys: ["endTime"]),
              end > start else { return nil }
        let stages: [StageSpan] = ((p["stages"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let a = JSONExtract.date(s["startTime"]), let b = JSONExtract.date(s["endTime"]), b > a else { return nil }
            return StageSpan(stage: SleepStage(apiValue: (s["type"] as? String) ?? ""), start: a, end: b)
        }.sorted { $0.start < $1.start }
        let summary = (p["summary"] as? [String: Any]) ?? [:]
        let asleep = JSONExtract.firstDouble(in: summary, keys: ["minutesAsleep", "totalMinutesAsleep"])
            ?? stages.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.minutes }
        let awake = JSONExtract.firstDouble(in: summary, keys: ["minutesAwake"])
            ?? stages.filter { $0.stage == .awake }.reduce(0) { $0 + $1.minutes }
        return SleepSession(id: (point["name"] as? String) ?? "g-\(Int(start.timeIntervalSince1970))", start: start, end: end,
                            minutesAsleep: asleep, minutesAwake: awake, stages: stages,
                            isMainSleep: (p["isMainSleep"] as? Bool) ?? false)
    }

    // MARK: HTTP

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> [String: Any] {
        var c = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.path = c.path.replacingOccurrences(of: "%3A", with: ":")
        c.queryItems = query
        guard let url = c.url else { throw APIError.badResponse("bad URL") }

        var attempt = 0
        var refreshed = false
        while true {
            await throttle()
            var req = URLRequest(url: url)
            req.setValue("Bearer \(try await auth.validAccessToken(config: config))", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw APIError.badResponse("not a JSON object")
                }
                return dict
            case 401 where !refreshed:
                refreshed = true
                try await auth.refresh(config: config)
            case 429 where attempt < 4, 500 where attempt < 4, 502 where attempt < 4, 503 where attempt < 4, 504 where attempt < 4:
                let retryAfter = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = min(retryAfter ?? pow(2, Double(attempt + 1)), 60)
                lock.withLock { nextSlot = max(nextSlot, Date().addingTimeInterval(delay)) }
                attempt += 1
            default:
                throw APIError.http(status, String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
            }
        }
    }

    private func throttle() async {
        let wait: TimeInterval = lock.withLock {
            let slot = max(nextSlot, Date())
            nextSlot = slot.addingTimeInterval(0.25)
            return slot.timeIntervalSinceNow
        }
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
}

/// Searches candidate keys breadth-first, because field names in the v4 API aren't all final.
public enum JSONExtract {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    public static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoPlain.date(from: s) ?? isoFrac.date(from: s) ?? (s.count == 10 ? DayKey.date(from: s) : nil)
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public static func firstDouble(in o: Any, keys: [String]) -> Double? {
        keys.lazy.compactMap { search(o, $0).flatMap(double) }.first
    }

    public static func firstDate(in o: Any, keys: [String]) -> Date? {
        keys.lazy.compactMap { search(o, $0).flatMap(date) }.first
    }

    public static func firstString(in o: Any, keys: [String]) -> String? {
        for k in keys {
            guard let v = search(o, k) else { continue }
            if let s = v as? String { return s }
            // Google CivilDate {year, month, day}
            if let d = v as? [String: Any], let y = double(d["year"]), let m = double(d["month"]), let dd = double(d["day"]) {
                return String(format: "%04d-%02d-%02d", Int(y), Int(m), Int(dd))
            }
        }
        return nil
    }

    static func search(_ o: Any, _ key: String, depth: Int = 4) -> Any? {
        var queue: [(Any, Int)] = [(o, 0)]
        while !queue.isEmpty {
            let (cur, lvl) = queue.removeFirst()
            guard lvl <= depth else { continue }
            if let d = cur as? [String: Any] {
                if let hit = d[key] { return hit }
                queue += d.values.map { ($0, lvl + 1) }
            } else if let a = cur as? [Any] {
                queue += a.prefix(20).map { ($0, lvl + 1) }
            }
        }
        return nil
    }

    public static func snakeCase(_ s: String) -> String {
        s.reduce(into: "") { r, c in r += c.isUppercase ? "_" + c.lowercased() : String(c) }
    }
}
