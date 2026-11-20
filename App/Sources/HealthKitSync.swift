import Foundation
import HealthKit

/// Reads what the Google Health app writes into Apple Health (since Google Health 5.05,
/// Aug 2026): sleep stages, heart rate, resting HR, workouts, steps and vitals. HRV does
/// not transfer, which is why the optional Google connection exists.
final class HealthKitSync: @unchecked Sendable {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let quantityTypes: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .oxygenSaturation,
        .appleSleepingWristTemperature, .bodyTemperature, .vo2Max, .stepCount, .activeEnergyBurned,
        // Written by other apps: Omada (weight), any food logger (meals, caffeine, alcohol).
        .bodyMass, .height, .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber,
        .dietaryCaffeine, .numberOfAlcoholicBeverages,
    ]

    /// What DOOP writes: meals you log, so other apps (and Nourish, if it reads nutrition) can see them.
    static let foodWrites: [(HKQuantityTypeIdentifier, HKUnit, KeyPath<Nutrients, Double>)] = [
        (.dietaryEnergyConsumed, .kilocalorie(), \.kcal), (.dietaryProtein, .gram(), \.protein),
        (.dietaryCarbohydrates, .gram(), \.carb), (.dietaryFatTotal, .gram(), \.fat), (.dietaryFiber, .gram(), \.fiber),
        (.dietarySugar, .gram(), \.sugar), (.dietarySodium, .gramUnit(with: .milli), \.sodium),
        (.dietaryCaffeine, .gramUnit(with: .milli), \.caffeine),
    ]
    static let mealIDKey = "DOOPMealID"

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(quantityTypes.map { HKQuantityType($0) })
        s.insert(HKCategoryType(.sleepAnalysis))
        s.insert(HKCategoryType(.mindfulSession))
        s.insert(HKObjectType.workoutType())
        s.insert(HKCharacteristicType(.dateOfBirth))
        s.insert(HKCharacteristicType(.biologicalSex))
        return s
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: Set(Self.foodWrites.map { HKQuantityType($0.0) }), read: readTypes)
    }

    /// Height in cm from the Health profile, if any app has recorded it.
    func heightCm() async -> Double? {
        let h = try? await quantitySamples(.height, unit: .meterUnit(with: .centi), start: .distantPast, end: Date())
        return h?.last?.1
    }

    // MARK: Writing meals

    /// Writes each food as an Apple Health food entry tagged with the meal's id, replacing any earlier copy.
    func write(_ meal: LoggedMeal) async throws {
        try await deleteMeal(id: meal.id)
        var objects: [HKObject] = []
        for item in meal.items {
            let meta: [String: Any] = [HKMetadataKeyFoodType: LoggedMeal.shortName(item.name), Self.mealIDKey: meal.id.uuidString]
            let samples: Set<HKSample> = Set(Self.foodWrites.compactMap { id, unit, kp in
                let v = item.nutrients[keyPath: kp]
                guard v > 0 else { return nil }
                return HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v),
                                        start: meal.time, end: meal.time, metadata: meta)
            })
            guard !samples.isEmpty else { continue }
            objects.append(HKCorrelation(type: HKCorrelationType(.food), start: meal.time, end: meal.time, objects: samples, metadata: meta))
        }
        guard !objects.isEmpty else { return }
        try await store.save(objects)
    }

    /// Removes a meal DOOP wrote earlier (only DOOP's own entries can be deleted).
    func deleteMeal(id: UUID) async throws {
        let p = HKQuery.predicateForObjects(withMetadataKey: Self.mealIDKey, allowedValues: [id.uuidString])
        for (type, _, _) in Self.foodWrites {
            _ = try? await store.deleteObjects(of: HKQuantityType(type), predicate: p)
        }
        _ = try? await store.deleteObjects(of: HKCorrelationType(.food), predicate: p)
    }

    /// Age and sex from the Health profile, if set.
    func profile() -> (age: Int?, sex: BiologicalSex?) {
        let age = (try? store.dateOfBirthComponents()).flatMap { c -> Int? in
            guard let date = Calendar.current.date(from: c) else { return nil }
            return Calendar.current.dateComponents([.year], from: date, to: Date()).year
        }
        let sex: BiologicalSex? = {
            switch (try? store.biologicalSex())?.biologicalSex {
            case .male: return .male
            case .female: return .female
            default: return nil
            }
        }()
        return (age, sex)
    }

    /// Wakes the app when new sleep or resting-HR data lands, so recovery is ready by the time you look.
    func enableBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) {
        for type in [HKCategoryType(.sleepAnalysis), HKQuantityType(.restingHeartRate)] as [HKSampleType] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await onUpdate()
                    completion()
                }
            }
            store.execute(query)
            // Sleep can wake the app immediately; most other types are limited to hourly.
            store.enableBackgroundDelivery(for: type, frequency: type == HKCategoryType(.sleepAnalysis) ? .immediate : .hourly) { _, _ in }
        }
    }

    // MARK: Sync

    func sync(daysBack: Int) async -> (days: [String: DayRecord], log: [SyncLogEntry], newest: Date?) {
        let end = Date()
        let start = DayKey.date(from: DayKey.addDays(DayKey.today(), -(daysBack - 1))) ?? end
        let nightStart = start.addingTimeInterval(-12 * 3600)
        var days: [String: DayRecord] = [:]
        var log: [SyncLogEntry] = []
        var newest: Date?

        func update(_ key: String, _ f: (inout DayRecord) -> Void) {
            var r = days[key] ?? DayRecord(date: key)
            f(&r)
            r.syncedAt = Date()
            days[key] = r
        }
        func note(_ metric: String, _ detail: String, _ err: Bool = false) {
            log.append(SyncLogEntry(source: "Apple Health", metric: metric, detail: detail, isError: err))
        }

        // Heart rate: one-minute averages computed by HealthKit itself (far cheaper than raw samples).
        do {
            let minutes = try await statistics(.heartRate, unit: .count().unitDivided(by: .minute()), option: .discreteAverage,
                                               start: start, end: end, interval: DateComponents(minute: 1))
            var byDay: [String: [HRSample]] = [:]
            for (t, v) in minutes { byDay[DayKey.string(from: t), default: []].append(HRSample(t: t, bpm: v)) }
            for (k, list) in byDay { update(k) { $0.hrSamples = list; $0.hrSyncedAt = Date() } }
            newest = try await newestSampleDate(.heartRate)
            note("Heart rate", "\(minutes.count) minutes across \(byDay.count) days")
        } catch { note("Heart rate", error.localizedDescription, true) }

        // Daily totals and averages.
        let dailies: [(String, HKQuantityTypeIdentifier, HKUnit, HKStatisticsOptions, (inout DayRecord, Double) -> Void)] = [
            ("Resting HR", .restingHeartRate, .count().unitDivided(by: .minute()), .discreteAverage, { $0.restingHR = $1 }),
            ("Steps", .stepCount, .count(), .cumulativeSum, { $0.steps = Int($1) }),
            ("Active energy", .activeEnergyBurned, .kilocalorie(), .cumulativeSum, { $0.activeEnergy = $1 }),
            ("VO₂max", .vo2Max, HKUnit(from: "ml/kg*min"), .discreteAverage, { $0.vo2max = $1 }),
        ]
        for (label, id, unit, option, apply) in dailies {
            do {
                let values = try await statistics(id, unit: unit, option: option, start: start, end: end, interval: DateComponents(day: 1))
                for (t, v) in values { update(DayKey.string(from: t)) { apply(&$0, v) } }
                note(label, "\(values.count) days")
            } catch { note(label, error.localizedDescription, true) }
        }

        // Overnight vitals, grouped to the morning they belong to.
        let nightly: [(String, HKQuantityTypeIdentifier, HKUnit, (inout DayRecord, [Double]) -> Void)] = [
            ("HRV (SDNN)", .heartRateVariabilitySDNN, .secondUnit(with: .milli), { $0.hrvSdnn = Stats.mean($1) }),
            ("Respiratory rate", .respiratoryRate, .count().unitDivided(by: .minute()), { $0.respiratoryRate = Stats.mean($1) }),
            ("Blood oxygen", .oxygenSaturation, .percent(), { r, v in
                r.spo2Avg = Stats.mean(v) * 100
                r.spo2Min = (v.min() ?? 0) * 100
            }),
            ("Wrist temperature", .appleSleepingWristTemperature, .degreeCelsius(), { $0.skinTemp = Stats.mean($1) }),
            ("Body temperature", .bodyTemperature, .degreeCelsius(), { r, v in if r.skinTemp == nil { r.skinTemp = Stats.mean(v) } }),
        ]
        for (label, id, unit, apply) in nightly {
            do {
                let samples = try await quantitySamples(id, unit: unit, start: nightStart, end: end)
                var byNight: [String: [Double]] = [:]
                for (t, v) in samples { byNight[DayKey.nightKey(for: t), default: []].append(v) }
                for (k, v) in byNight { update(k) { apply(&$0, v) } }
                note(label, byNight.isEmpty ? "no data" : "\(byNight.count) nights")
            } catch { note(label, error.localizedDescription, true) }
        }

        do {
            let sessions = try await sleepSessions(start: nightStart, end: end)
            var byDay: [String: [SleepSession]] = [:]
            for s in sessions { byDay[DayKey.string(from: s.end), default: []].append(s) }
            for (k, list) in byDay {
                var sorted = list.sorted { $0.start < $1.start }
                if let i = sorted.indices.max(by: { sorted[$0].minutesAsleep < sorted[$1].minutesAsleep }) {
                    for j in sorted.indices { sorted[j].isMainSleep = j == i }
                }
                update(k) { $0.sleepSessions = sorted }
            }
            note("Sleep", "\(sessions.count) sessions")
        } catch { note("Sleep", error.localizedDescription, true) }

        // Weight (Omada) and meals (food logger), via Apple Health.
        do {
            let w = try await quantitySamples(.bodyMass, unit: .gramUnit(with: .kilo), start: start, end: end)
            for (t, v) in w { update(DayKey.string(from: t)) { $0.weightKg = v } }
            note("Weight", w.isEmpty ? "none · in Omada: Settings → Health Integration" : "\(w.count) weigh-ins")
        } catch { note("Weight", error.localizedDescription, true) }
        do {
            let meals = try await mealSamples(start: start, end: end)
            var byDay: [String: [Meal]] = [:]
            for m in meals { byDay[DayKey.string(from: m.time), default: []].append(m) }
            for (k, list) in byDay { update(k) { $0.meals = list } }
            note("Meals", meals.isEmpty ? "none · no food app is writing nutrition to Health" : "\(meals.count) entries")
        } catch { note("Meals", error.localizedDescription, true) }
        do {
            let raw: [HKCategorySample] = try await samples(HKCategoryType(.mindfulSession), start: start, end: end)
            var byDay: [String: Double] = [:]
            for s in raw { byDay[DayKey.string(from: s.startDate), default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60 }
            for (k, m) in byDay { update(k) { $0.mindfulMinutes = m } }
            note("Mindful", "\(byDay.count) days")
        } catch { note("Mindful", error.localizedDescription, true) }
        // Steps per minute, recent two weeks only: enough to separate stress from movement.
        do {
            let recentStart = max(start, Date().addingTimeInterval(-14 * 86400))
            let minutes = try await statistics(.stepCount, unit: .count(), option: .cumulativeSum,
                                               start: recentStart, end: end, interval: DateComponents(minute: 1))
            var byDay: [String: [MinuteValue]] = [:]
            for (t, v) in minutes where v > 0 { byDay[DayKey.string(from: t), default: []].append(MinuteValue(t: t, v: v)) }
            for (k, list) in byDay { update(k) { $0.stepMinutes = list } }
        } catch { note("Steps per minute", error.localizedDescription, true) }

        do {
            let workouts = try await workouts(start: start, end: end)
            var byDay: [String: [Workout]] = [:]
            for w in workouts { byDay[DayKey.string(from: w.start), default: []].append(w) }
            for (k, list) in byDay { update(k) { $0.workouts = list.sorted { $0.start < $1.start } } }
            note("Workouts", "\(workouts.count) sessions")
        } catch { note("Workouts", error.localizedDescription, true) }

        return (days, log, newest)
    }

    // MARK: Queries

    private func statistics(_ id: HKQuantityTypeIdentifier, unit: HKUnit, option: HKStatisticsOptions,
                            start: Date, end: Date, interval: DateComponents) async throws -> [(Date, Double)] {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: option,
                                                anchorDate: Calendar.current.startOfDay(for: start), intervalComponents: interval)
            q.initialResultsHandler = { _, results, error in
                if let error {
                    // "No data" is not a failure.
                    if (error as? HKError)?.code == .errorNoData { cont.resume(returning: []) } else { cont.resume(throwing: error) }
                    return
                }
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let q = option == .cumulativeSum ? stat.sumQuantity() : stat.averageQuantity()
                    if let v = q?.doubleValue(for: unit) { out.append((stat.startDate, v)) }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    private func quantitySamples(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                                 otherAppsOnly: Bool = false) async throws -> [(Date, Double)] {
        var samples: [HKQuantitySample] = try await samples(HKQuantityType(id), start: start, end: end)
        if otherAppsOnly { samples = samples.filter { $0.metadata?[Self.mealIDKey] == nil } }
        return samples.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
    }

    private func samples<T: HKSample>(_ type: HKSampleType, start: Date, end: Date, limit: Int = HKObjectQueryNoLimit) async throws -> [T] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                  limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (s as? [T]) ?? []) }
            }
            store.execute(q)
        }
    }

    /// Nutrition samples grouped into meals: entries within 20 minutes of each other are one meal.
    /// DOOP's own meals are skipped here; they come from its food log so they aren't counted twice.
    private func mealSamples(start: Date, end: Date) async throws -> [Meal] {
        let kcal = try await quantitySamples(.dietaryEnergyConsumed, unit: .kilocalorie(), start: start, end: end, otherAppsOnly: true)
        let protein = try await quantitySamples(.dietaryProtein, unit: .gram(), start: start, end: end, otherAppsOnly: true)
        let carbs = try await quantitySamples(.dietaryCarbohydrates, unit: .gram(), start: start, end: end, otherAppsOnly: true)
        let fat = try await quantitySamples(.dietaryFatTotal, unit: .gram(), start: start, end: end, otherAppsOnly: true)
        let caffeine = try await quantitySamples(.dietaryCaffeine, unit: .gramUnit(with: .milli), start: start, end: end, otherAppsOnly: true)
        let alcohol = try await quantitySamples(.numberOfAlcoholicBeverages, unit: .count(), start: start, end: end, otherAppsOnly: true)
        var meals: [Meal] = []
        func slot(_ t: Date) -> Int {
            if let i = meals.firstIndex(where: { abs($0.time.timeIntervalSince(t)) < 20 * 60 }) { return i }
            meals.append(Meal(time: t))
            return meals.count - 1
        }
        for (t, v) in kcal { let i = slot(t); meals[i].kcal = (meals[i].kcal ?? 0) + v }
        for (t, v) in protein { let i = slot(t); meals[i].proteinG = (meals[i].proteinG ?? 0) + v }
        for (t, v) in carbs { let i = slot(t); meals[i].carbG = (meals[i].carbG ?? 0) + v }
        for (t, v) in fat { let i = slot(t); meals[i].fatG = (meals[i].fatG ?? 0) + v }
        for (t, v) in caffeine { let i = slot(t); meals[i].caffeineMg = (meals[i].caffeineMg ?? 0) + v }
        for (t, v) in alcohol { let i = slot(t); meals[i].alcoholG = (meals[i].alcoholG ?? 0) + v * 14 }
        return meals.sorted { $0.time < $1.time }
    }

    private func newestSampleDate(_ id: HKQuantityTypeIdentifier) async throws -> Date? {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: nil, limit: 1,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, s, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: s?.first?.endDate) }
            }
            store.execute(q)
        }
    }

    /// HealthKit delivers sleep as stage spans; stitch them into sessions (a gap over an hour splits sessions).
    private func sleepSessions(start: Date, end: Date) async throws -> [SleepSession] {
        let raw: [HKCategorySample] = try await samples(HKCategoryType(.sleepAnalysis), start: start, end: end)
        let hasStages = raw.contains { HKCategoryValueSleepAnalysis(rawValue: $0.value) != .inBed }
        let spans: [StageSpan] = raw.compactMap { s in
            let stage: SleepStage
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed: if hasStages { return nil }; stage = .unknown
            case .awake: stage = .awake
            case .asleepCore: stage = .light
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            default: stage = .unknown
            }
            return StageSpan(stage: stage, start: s.startDate, end: s.endDate)
        }.sorted { $0.start < $1.start }

        var sessions: [SleepSession] = []
        var current: [StageSpan] = []
        for span in spans {
            if let last = current.last, span.start.timeIntervalSince(last.end) > 3600 {
                if let s = SleepSession.from(stages: current, id: "hk-\(Int(current[0].start.timeIntervalSince1970))") { sessions.append(s) }
                current = []
            }
            current.append(span)
        }
        if !current.isEmpty, let s = SleepSession.from(stages: current, id: "hk-\(Int(current[0].start.timeIntervalSince1970))") {
            sessions.append(s)
        }
        return sessions.filter { $0.minutesAsleep >= 20 }
    }

    private func workouts(start: Date, end: Date) async throws -> [Workout] {
        let raw: [HKWorkout] = try await samples(HKObjectType.workoutType(), start: start, end: end)
        return raw.map { w in
            Workout(id: w.uuid.uuidString, name: w.workoutActivityType.displayName, start: w.startDate, end: w.endDate,
                    averageHR: w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())),
                    calories: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()))
        }
    }
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycling"
        case .swimming: return "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .hiking: return "Hike"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .tennis: return "Tennis"
        case .pilates: return "Pilates"
        case .dance: return "Dance"
        case .climbing: return "Climbing"
        case .crossTraining: return "Cross training"
        case .mixedCardio: return "Cardio"
        default: return "Workout"
        }
    }
}
