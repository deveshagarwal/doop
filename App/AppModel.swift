import Foundation
import SwiftUI
import Observation
import WidgetKit

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: StoreSnapshot
    private(set) var analysis: Analysis = .empty
    private(set) var syncing = false
    private(set) var syncLog: [SyncLogEntry] = []
    var errorMessage: String?
    var selectedTab: Tab = .today

    enum Tab: Hashable { case today, sleep, train, learn, body }

    private let store = Store()
    private let healthKit = HealthKitSync()
    private let googleAuth = GoogleAuth()
    private let calendar = CalendarSource()
    let weather = WeatherSource()
    /// Demo mode runs on generated data held in memory; your real store is untouched.
    private var demo: (days: [String: DayRecord], journal: [String: JournalEntry])?

    init() {
        snapshot = store.load()
        // Launch arguments for simulator screenshots: --demo, --tab <name>
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") { snapshot.settings.demoMode = true }
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            selectedTab = ["sleep": .sleep, "train": .train, "learn": .learn, "body": .body][args[i + 1]] ?? .today
        }
        if snapshot.settings.demoMode { demo = DemoData.generate() }
        recompute()
    }

    // MARK: Derived

    var settings: UserSettings { snapshot.settings }
    var days: [String: DayRecord] { demo?.days ?? snapshot.mergedDays }
    var journal: [String: JournalEntry] { demo?.journal ?? snapshot.journal }
    var today: DayScore? { analysis.latest }
    var isGoogleConnected: Bool { googleAuth.isConnected }
    var hasAppleHealthData: Bool { !snapshot.days.isEmpty }
    /// True once any food app has written nutrition to Apple Health; food UI stays hidden until then.
    var hasMealData: Bool { snapshot.newestSample["meals"] != nil }
    var hasAnyData: Bool { !days.isEmpty }
    var calendarConnected: Bool { calendar.isAuthorized }
    var isDemo: Bool { demo != nil }

    func record(_ key: String) -> DayRecord? { days[key] }

    var askClaudeText: String { AskClaudeSummary.build(analysis: analysis, days: days, settings: settings) }

    // MARK: Mutations

    func updateSettings(_ f: (inout UserSettings) -> Void) {
        let wasDemo = snapshot.settings.demoMode
        f(&snapshot.settings)
        if snapshot.settings.demoMode != wasDemo { demo = snapshot.settings.demoMode ? DemoData.generate() : nil }
        persist()
        recompute()
    }

    /// The one daily question. `yes == nil` means skipped.
    func answer(_ q: DailyQuestion, yes: Bool?) {
        var entry = journal[q.day] ?? JournalEntry(date: q.day)
        switch yes {
        case true?: entry.factors.insert(q.factor); entry.denied.remove(q.factor)
        case false?: entry.denied.insert(q.factor); entry.factors.remove(q.factor)
        case nil: entry.denied.insert(q.factor + "_skipped")
        }
        if demo != nil { demo?.journal[q.day] = entry } else { snapshot.journal[q.day] = entry }
        persist()
        recompute()
    }

    /// Correct a detection you disagree with, from the Day log.
    func setFactor(_ id: String, on day: String, present: Bool) {
        var entry = journal[day] ?? JournalEntry(date: day)
        if present { entry.factors.insert(id); entry.denied.remove(id) } else { entry.denied.insert(id); entry.factors.remove(id) }
        if demo != nil { demo?.journal[day] = entry } else { snapshot.journal[day] = entry }
        persist()
        recompute()
    }

    private func persist() { store.save(snapshot) }

    private func recompute() {
        let days = self.days, journal = self.journal, settings = self.settings
        Task.detached(priority: .userInitiated) {
            let a = Analyzer.run(days: days, journal: journal, settings: settings)
            await MainActor.run {
                self.analysis = a
                WidgetBridge.publish(a)
            }
        }
    }

    // MARK: Connections

    func connectAppleHealth() async {
        guard HealthKitSync.isAvailable else { errorMessage = "Apple Health isn't available on this device."; return }
        do {
            try await healthKit.requestAuthorization()
            let p = healthKit.profile()
            updateSettings { s in
                if let age = p.age { s.age = age }
                if let sex = p.sex { s.sex = sex }
            }
            await Notifier.requestPermission()
            startBackgroundDelivery()
            await sync()
        } catch { errorMessage = error.localizedDescription }
    }

    func connectCalendar() async {
        if await calendar.requestAccess() { await sync() }
    }

    func connectWeather() {
        weather.requestAccess()
        Task { try? await Task.sleep(for: .seconds(2)); await sync() }
    }

    func startBackgroundDelivery() {
        guard HealthKitSync.isAvailable else { return }
        healthKit.enableBackgroundDelivery { [weak self] in await self?.sync(background: true) }
    }

    func connectGoogle(clientID: String) async {
        let config = GoogleOAuthConfig(clientID: clientID)
        guard config.isValid, let scheme = config.reversedClientScheme else { errorMessage = AuthError.invalidClientID.localizedDescription; return }
        updateSettings { $0.googleClientID = config.clientID }
        let pkce = PKCE(), state = UUID().uuidString
        guard let url = googleAuth.authorizationURL(config: config, pkce: pkce, state: state) else { return }
        do {
            let callback = try await WebAuthenticator.shared.authenticate(url: url, callbackScheme: scheme)
            guard let code = GoogleAuth.extractCode(from: callback, expectedState: state) else {
                errorMessage = "Google sign-in was cancelled or returned no code."
                return
            }
            try await googleAuth.exchange(code: code, pkce: pkce, config: config)
            googleSignedIn(at: Date())
            await sync()
        } catch { errorMessage = error.localizedDescription }
    }

    // If Google ever rejects the sign-in, only a person can approve a new one,
    // so DOOP opens the renewal itself the next time the app is opened.
    private static let googleLapsedKey = "googleLapsed"
    private var lastAutoReconnect: Date?

    private func googleSignedIn(at date: Date) {
        UserDefaults.standard.set(false, forKey: Self.googleLapsedKey)
    }

    private func googleLapsed() {
        guard !UserDefaults.standard.bool(forKey: Self.googleLapsedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.googleLapsedKey)
        Notifier.send(id: "google-lapsed", title: "Google sign-in expired",
                      body: "HRV is paused. Open DOOP and it renews in one tap.")
    }

    /// Called when the app comes to the foreground. Opens Google's sign-in on its own when the
    /// sign-in has lapsed; at most once every 6 hours if dismissed.
    func renewGoogleIfNeeded() async {
        guard googleAuth.isConnected, !settings.googleClientID.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: Self.googleLapsedKey), Date().timeIntervalSince(lastAutoReconnect ?? .distantPast) > 6 * 3600 else { return }
        lastAutoReconnect = Date()
        await connectGoogle(clientID: settings.googleClientID)
    }

    func disconnectGoogle() {
        googleAuth.disconnect()
        snapshot.googleDays = [:]
        persist()
        recompute()
    }

    // MARK: Sync

    func sync(background: Bool = false) async {
        guard !syncing, demo == nil else { return }
        syncing = true
        defer { syncing = false }
        var log: [SyncLogEntry] = []
        let firstSync = snapshot.lastSync["appleHealth"] == nil
        let daysBack = firstSync ? settings.historyDays : 10

        if HealthKitSync.isAvailable {
            let r = await healthKit.sync(daysBack: daysBack)
            for (k, v) in r.days { snapshot.days[k] = v }
            snapshot.lastSync["appleHealth"] = Date()
            if let n = r.newest { snapshot.newestSample["appleHealth"] = n }
            if let w = r.days.values.filter({ $0.weightKg != nil }).map(\.date).max() { snapshot.newestSample["weight"] = DayKey.date(from: w) }
            if let m = r.days.values.compactMap({ $0.meals?.map(\.time).max() }).max() { snapshot.newestSample["meals"] = m }
            log += r.log
        }

        if googleAuth.isConnected, !settings.googleClientID.isEmpty {
            let client = HealthAPIClient(auth: googleAuth, config: GoogleOAuthConfig(clientID: settings.googleClientID))
            let r = await GoogleSync.sync(client: client, daysBack: snapshot.lastSync["google"] == nil ? settings.historyDays : 10)
            for (k, v) in r.days { snapshot.googleDays[k] = v }
            snapshot.lastSync["google"] = Date()
            if let n = r.days.values.filter({ $0.hrvRmssd != nil }).compactMap({ DayKey.date(from: $0.date) }).max() { snapshot.newestSample["google"] = n }
            log += r.log
            if r.log.contains(where: { $0.detail.contains("expired") }) { googleLapsed() }
        }

        // Context the app collects itself.
        var ctx = snapshot.context
        let todayKey = DayKey.today()
        ctx[todayKey, default: DayRecord(date: todayKey)].timeZoneID = TimeZone.current.identifier
        for (k, v) in calendar.summary(daysBack: daysBack) {
            ctx[k, default: DayRecord(date: k)].lastEventEnd = v.lastEnd
            ctx[k, default: DayRecord(date: k)].eventHours = v.hours
        }
        for (k, w) in await weather.fetch(daysBack: daysBack) { ctx[k, default: DayRecord(date: k)].weather = w }
        snapshot.context = ctx

        syncLog = log
        persist()
        let a = Analyzer.run(days: days, journal: journal, settings: settings)
        analysis = a
        WidgetBridge.publish(a)
        notify(a)
    }

    private func notify(_ a: Analysis) {
        guard let t = a.latest else { return }
        if settings.notifyIllness, t.illness.level == .alert, !snapshot.notifiedAlerts.contains("illness-\(t.date)") {
            Notifier.send(id: "illness-\(t.date)", title: "Your vitals are off baseline", body: t.illness.message)
            snapshot.notifiedAlerts.insert("illness-\(t.date)")
        }
        if settings.notifyRecovery, let r = t.recovery, !snapshot.notifiedAlerts.contains("recovery-\(t.date)") {
            let zone = r.zone == .green ? "primed" : r.zone == .yellow ? "steady" : "run down"
            if let q = a.question {
                Notifier.ask(id: "recovery-\(t.date)", title: "Recovery \(r.score)% · \(zone)",
                             body: "Quick one: \(q.prompt.lowercased()) \(q.evidence).", day: q.day, factor: q.factor)
            } else {
                let target = t.strainTarget.map { String(format: " Strain target %.1f.", $0) } ?? ""
                Notifier.send(id: "recovery-\(t.date)", title: "Recovery \(r.score)% · \(zone)", body: "Your day is scored.\(target)")
            }
            snapshot.notifiedAlerts.insert("recovery-\(t.date)")
        }
        if settings.notifyBedtime, let s = a.suggestions.first(where: { $0.kind == .bedtime }), let bed = t.bedtimeTonight {
            Notifier.schedule(id: "bedtime-\(t.date)", at: bed.addingTimeInterval(-45 * 60), title: "Wind down", body: s.title)
        }
        persist()
    }
}
