import Foundation
import HealthKit

/// Every Apple Health type DOOP reads beyond the ones its engines use directly, so nothing any app writes
/// (WHOOP, Fitbit, Zepp, Omada, Apple Watch…) is left behind. Each becomes one daily value in `DayRecord.extras`.
enum HealthCatalog {
    static let quantities: [HKQuantityTypeIdentifier] = [
        // Heart
        .walkingHeartRateAverage, .heartRateRecoveryOneMinute, .atrialFibrillationBurden,
        // Activity
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
        .flightsClimbed, .basalEnergyBurned, .appleExerciseTime, .appleStandTime, .appleMoveTime, .physicalEffort,
        .pushCount, .swimmingStrokeCount, .numberOfTimesFallen,
        // Running and cycling
        .runningPower, .runningSpeed, .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime,
        .cyclingPower, .cyclingCadence, .cyclingSpeed, .cyclingFunctionalThresholdPower,
        // Mobility
        .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
        .appleWalkingSteadiness, .sixMinuteWalkTestDistance, .stairAscentSpeed, .stairDescentSpeed,
        // Body
        .bodyFatPercentage, .leanBodyMass, .bodyMassIndex, .waistCircumference,
        // Vitals and lab-style readings
        .bloodPressureSystolic, .bloodPressureDiastolic, .bloodGlucose, .appleSleepingBreathingDisturbances,
        .electrodermalActivity, .peakExpiratoryFlowRate, .forcedVitalCapacity, .forcedExpiratoryVolume1,
        .bloodAlcoholContent, .insulinDelivery, .inhalerUsage, .basalBodyTemperature,
        // Nutrition beyond meals
        .dietaryWater, .dietarySugar, .dietarySodium, .dietaryFiber, .dietaryCholesterol, .dietaryFatSaturated,
        // Environment
        .timeInDaylight, .environmentalAudioExposure, .headphoneAudioExposure, .uvExposure,
        .underwaterDepth, .waterTemperature,
    ]

    /// Category types stored as a count per day.
    static let events: [HKCategoryTypeIdentifier] = [
        .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent, .lowCardioFitnessEvent,
        .sleepApneaEvent, .environmentalAudioExposureEvent, .headphoneAudioExposureEvent,
        .appleStandHour, .handwashingEvent, .toothbrushingEvent, .menstrualFlow, .appleWalkingSteadinessEvent,
    ]

    static var readTypes: Set<HKObjectType> {
        Set(quantities.map { HKQuantityType($0) as HKObjectType } + events.map { HKCategoryType($0) as HKObjectType })
    }

    static func eventKey(_ id: HKCategoryTypeIdentifier) -> String { "event." + id.rawValue }

    /// "HKQuantityTypeIdentifierWalkingHeartRateAverage" → "Walking heart rate average".
    static func label(_ key: String) -> String {
        if key.contains(" ") { return key }
        let isEvent = key.hasPrefix("event.")
        var raw = isEvent ? String(key.dropFirst(6)) : key
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "Apple"] where raw.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count))
        }
        var words: [String] = []
        var current = ""
        for ch in raw {
            if ch.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let text = words.enumerated().map { i, w in i == 0 ? w : (w.count > 1 && w == w.uppercased() ? w : w.lowercased()) }.joined(separator: " ")
        return isEvent ? text + " (count)" : text
    }
}
