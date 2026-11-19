import WidgetKit
import SwiftUI

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snap: WidgetSnapshot(recovery: 77, zone: "green", strain: 2.2, strainTarget: 15.5, bedtime: .now, updated: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snap: WidgetSnapshot.load() ?? placeholder(in: context).snap))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snap: WidgetSnapshot.load())], policy: .after(.now.addingTimeInterval(1800))))
    }
}

private let bone = Color(red: 0.937, green: 0.914, blue: 0.875)
private let ember = Color(red: 1.0, green: 0.70, blue: 0.42)

struct DOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snap
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(s?.recovery ?? 0), in: 0...100) {
                Text("REC")
            } currentValueLabel: {
                Text(s?.recovery.map { "\($0)" } ?? "–").font(.system(size: 17, weight: .light))
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("STRAIN").font(.system(size: 9, weight: .medium, design: .monospaced))
                Text(String(format: "%.1f", s?.strain ?? 0) + (s?.strainTarget.map { String(format: " / %.1f", $0) } ?? ""))
                    .font(.system(size: 17, weight: .light))
                if let b = s?.bedtime {
                    Text("bed by " + b.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
        case .accessoryInline:
            Text("Recovery \(s?.recovery.map { "\($0)%" } ?? "–") · strain " + String(format: "%.1f", s?.strain ?? 0))
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("RECOVERY").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(bone.opacity(0.6))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(s?.recovery.map { "\($0)" } ?? "–").font(.system(size: 50, weight: .ultraLight))
                    Text("%").font(.system(size: 14, weight: .light)).foregroundStyle(bone.opacity(0.3))
                }
                Spacer(minLength: 0)
                Text(String(format: "Strain %.1f", s?.strain ?? 0) + (s?.strainTarget.map { String(format: " of %.1f", $0) } ?? ""))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(ember)
            }
            .foregroundStyle(bone)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@main
struct DOOPWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DOOPWidget", provider: Provider()) { entry in
            DOOPWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.024, green: 0.024, blue: 0.027) }
        }
        .configurationDisplayName("DOOP")
        .description("Recovery, strain and tonight's bedtime.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
