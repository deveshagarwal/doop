import Foundation
import WidgetKit

enum WidgetBridge {
    static func publish(_ a: Analysis) {
        guard let t = a.latest, let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroup) else { return }
        let s = WidgetSnapshot(recovery: t.recovery?.score, zone: t.recovery?.zone.rawValue, strain: t.strain.strain,
                               strainTarget: t.strainTarget, bedtime: t.bedtimeTonight, updated: Date())
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: WidgetSnapshot.key)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
