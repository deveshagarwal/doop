import Foundation
import EventKit
import CoreLocation

/// Calendar context: when the day's last meeting ended and how packed it was. Read-only.
final class CalendarSource: @unchecked Sendable {
    private let store = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Per day: end of the last timed event, and total hours of timed events.
    func summary(daysBack: Int) -> [String: (lastEnd: Date?, hours: Double)] {
        guard isAuthorized,
              let start = DayKey.date(from: DayKey.addDays(DayKey.today(), -(daysBack - 1))) else { return [:] }
        let predicate = store.predicateForEvents(withStart: start, end: Date().addingTimeInterval(86400), calendars: nil)
        var out: [String: (lastEnd: Date?, hours: Double)] = [:]
        for e in store.events(matching: predicate) where !e.isAllDay && e.endDate.timeIntervalSince(e.startDate) < 8 * 3600 {
            let k = DayKey.string(from: e.startDate)
            var v = out[k] ?? (nil, 0)
            v.lastEnd = max(v.lastEnd ?? .distantPast, e.endDate)
            v.hours += e.endDate.timeIntervalSince(e.startDate) / 3600
            out[k] = v
        }
        return out
    }
}

/// Weather for hot-night detection. One coarse location fix, then Open-Meteo (free, no key, no account).
@MainActor
final class WeatherSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func location() async -> CLLocation? {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return await withCheckedContinuation { c in
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in continuation?.resume(returning: locations.last); continuation = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in continuation?.resume(returning: nil); continuation = nil }
    }

    /// Daily max temperature and the overnight low (the next day's minimum), for the last `daysBack` days.
    func fetch(daysBack: Int) async -> [String: DayWeather] {
        guard let loc = await location() else { return [:] }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", loc.coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", loc.coordinate.longitude)),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "past_days", value: "\(min(daysBack, 92))"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
        ]
        struct Response: Decodable {
            struct Daily: Decodable { let time: [String]; let temperature_2m_max: [Double?]; let temperature_2m_min: [Double?] }
            let daily: Daily
        }
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(Response.self, from: data) else { return [:] }
        var out: [String: DayWeather] = [:]
        for (i, day) in r.daily.time.enumerated() {
            let nightLow = i + 1 < r.daily.time.count ? r.daily.temperature_2m_min[i + 1] : nil
            out[day] = DayWeather(maxTempC: r.daily.temperature_2m_max[i], nightMinTempC: nightLow, aqi: nil)
        }
        return out
    }
}
