import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: StoreSnapshot
    private(set) var analysis: Analysis = .empty
    private(set) var syncing = false
    private(set) var syncLog: [SyncLogEntry] = []
    var errorMessage: String?
    var selectedTab: Tab = .today
    var coachStreaming = false

    enum Tab: Hashable { case today, training, health, journal, coach }

    private let store = Store()
    private let healthKit = HealthKitSync()
    private let googleAuth = GoogleAuth()
    /// Demo mode runs on generated data held in memory; your real store is untouched.
    private var demo: (days: [String: DayRecord], journal: [String: JournalEntry])?

    init() {
        snapshot = store.load()
        // Launch arguments for simulator screenshots: --demo, --tab <name>
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") { snapshot.settings.demoMode = true }
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            selectedTab = ["training": .training, "health": .health, "journal": .journal, "coach": .coach][args[i + 1]] ?? .today
        }
        if snapshot.settings.demoMode { demo = DemoData.generate() }
        recompute()
    }

    // MARK: Derived

    var settings: UserSettings { snapshot.settings }
    var days: [String: DayRecord] { demo?.days ?? snapshot.mergedDays }
    var journal: [String: JournalEntry] { demo?.journal ?? snapshot.journal }
    var factors: [JournalFactor] { snapshot.factors }
    var today: DayScore? { analysis.latest }
    var isGoogleConnected: Bool { googleAuth.isConnected }
    var hasAppleHealthData: Bool { !snapshot.days.isEmpty }
    var hasAnyData: Bool { !days.isEmpty }
    var hasClaudeKey: Bool { ClaudeClient.storedKey() != nil }

    func record(_ key: String) -> DayRecord? { days[key] }

    // MARK: Mutations

    func updateSettings(_ f: (inout UserSettings) -> Void) {
        let wasDemo = snapshot.settings.demoMode
        f(&snapshot.settings)
        if snapshot.settings.demoMode != wasDemo {
            demo = snapshot.settings.demoMode ? DemoData.generate() : nil
        }
        persist()
        recompute()
    }

    func toggleFactor(_ id: String, on day: String) {
        var entry = journal[day] ?? JournalEntry(date: day)
        if entry.factors.contains(id) { entry.factors.remove(id) } else { entry.factors.insert(id) }
        setJournal(entry)
    }

    func setNote(_ note: String, on day: String) {
        var entry = journal[day] ?? JournalEntry(date: day)
        entry.note = note
        setJournal(entry)
    }

    func addFactor(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = "custom_" + trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
        guard !factors.contains(where: { $0.id == id }) else { return }
        snapshot.customFactors.append(JournalFactor(id: id, label: trimmed, symbol: "tag", expectedPositive: true))
        persist()
    }

    private func setJournal(_ entry: JournalEntry) {
        if demo != nil { demo?.journal[entry.date] = entry } else { snapshot.journal[entry.date] = entry }
        persist()
        recompute()
    }

    private func persist() { store.save(snapshot) }

    private func recompute() {
        let days = self.days, journal = self.journal, factors = self.factors, settings = self.settings
        Task.detached(priority: .userInitiated) {
            let a = Analyzer.run(days: days, journal: journal, factors: factors, settings: settings)
            await MainActor.run { self.analysis = a }
        }
    }

    // MARK: Sync

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

    func startBackgroundDelivery() {
        guard HealthKitSync.isAvailable else { return }
        healthKit.enableBackgroundDelivery { [weak self] in await self?.sync(background: true) }
    }

    func connectGoogle(clientID: String) async {
        let config = GoogleOAuthConfig(clientID: clientID)
        guard config.isValid, let scheme = config.reversedClientScheme else { errorMessage = AuthError.invalidClientID.localizedDescription; return }
        updateSettings { $0.googleClientID = config.clientID }
        let pkce = PKCE()
        let state = UUID().uuidString
        guard let url = googleAuth.authorizationURL(config: config, pkce: pkce, state: state) else { return }
        do {
            let callback = try await WebAuthenticator.shared.authenticate(url: url, callbackScheme: scheme)
            guard let code = GoogleAuth.extractCode(from: callback, expectedState: state) else {
                errorMessage = "Google sign-in was cancelled or returned no code."
                return
            }
            try await googleAuth.exchange(code: code, pkce: pkce, config: config)
            await sync()
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnectGoogle() {
        googleAuth.disconnect()
        snapshot.googleDays = [:]
        persist()
        recompute()
    }

    func sync(background: Bool = false) async {
        guard !syncing, demo == nil else { return }
        syncing = true
        defer { syncing = false }
        var log: [SyncLogEntry] = []
        let daysBack = snapshot.lastSync["appleHealth"] == nil ? settings.historyDays : 10

        if HealthKitSync.isAvailable {
            let r = await healthKit.sync(daysBack: daysBack)
            for (k, v) in r.days { snapshot.days[k] = v }
            snapshot.lastSync["appleHealth"] = Date()
            if let n = r.newest { snapshot.newestSample["appleHealth"] = n }
            log += r.log
        }

        if googleAuth.isConnected, !settings.googleClientID.isEmpty {
            let client = HealthAPIClient(auth: googleAuth, config: GoogleOAuthConfig(clientID: settings.googleClientID))
            let gBack = snapshot.lastSync["google"] == nil ? settings.historyDays : 10
            let r = await GoogleSync.sync(client: client, daysBack: gBack)
            for (k, v) in r.days { snapshot.googleDays[k] = v }
            snapshot.lastSync["google"] = Date()
            if let newestHRV = r.days.values.filter({ $0.hrvRmssd != nil }).compactMap({ DayKey.date(from: $0.date) }).max() {
                snapshot.newestSample["google"] = newestHRV
            }
            log += r.log
            if r.log.contains(where: { $0.detail.contains("expired") }) {
                errorMessage = AuthError.refreshExpired.localizedDescription
            }
        }

        syncLog = log
        persist()
        let a = Analyzer.run(days: days, journal: journal, factors: factors, settings: settings)
        analysis = a
        notifyIfNeeded(a)
    }

    private func notifyIfNeeded(_ a: Analysis) {
        guard let t = a.latest else { return }
        if settings.notifyIllness, t.illness.level == .alert, !snapshot.notifiedAlerts.contains("illness-\(t.date)") {
            Notifier.send(id: "illness-\(t.date)", title: "Your vitals are off baseline", body: t.illness.message)
            snapshot.notifiedAlerts.insert("illness-\(t.date)")
        }
        if settings.notifyRecovery, let r = t.recovery, !snapshot.notifiedAlerts.contains("recovery-\(t.date)") {
            let target = t.strainTarget.map { String(format: " Strain target %.1f.", $0) } ?? ""
            Notifier.send(id: "recovery-\(t.date)", title: "Recovery \(r.score)%", body: "Your \(r.zone.rawValue) day is scored.\(target)")
            snapshot.notifiedAlerts.insert("recovery-\(t.date)")
        }
        persist()
    }

    // MARK: Coach

    var chat: [ChatMessage] { snapshot.chat }

    func setClaudeKey(_ key: String) { ClaudeClient.storeKey(key) }

    func clearChat() {
        snapshot.chat = []
        persist()
    }

    func ask(_ text: String) async {
        guard let key = ClaudeClient.storedKey() else { errorMessage = CoachError.noKey.localizedDescription; return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coachStreaming else { return }
        snapshot.chat.append(ChatMessage(role: .user, text: trimmed))
        let reply = ChatMessage(role: .assistant, text: "")
        snapshot.chat.append(reply)
        coachStreaming = true
        defer { coachStreaming = false; persist() }

        let context = CoachContext.build(analysis: analysis, days: days, journal: journal, factors: factors, settings: settings)
        let system = CoachContext.systemPrompt + "\n\n<my_data>\n" + context + "\n</my_data>"
        let history = Array(snapshot.chat.dropLast().suffix(20))
        do {
            for try await delta in ClaudeClient(apiKey: key).stream(system: system, messages: history) {
                if let i = snapshot.chat.firstIndex(where: { $0.id == reply.id }) { snapshot.chat[i].text += delta }
            }
        } catch {
            if let i = snapshot.chat.firstIndex(where: { $0.id == reply.id }) {
                if snapshot.chat[i].text.isEmpty { snapshot.chat.remove(at: i) }
            }
            errorMessage = error.localizedDescription
        }
    }

    func morningBrief() {
        selectedTab = .coach
        Task { await ask(CoachContext.morningBriefPrompt) }
    }
}
