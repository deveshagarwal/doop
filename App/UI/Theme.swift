import SwiftUI

enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let cardBorder = Color.white.opacity(0.06)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.3)

    static let green = Color(red: 0.13, green: 0.85, blue: 0.47)
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let red = Color(red: 1.0, green: 0.30, blue: 0.30)
    static let strain = Color(red: 0.27, green: 0.62, blue: 1.0)
    static let sleep = Color(red: 0.62, green: 0.52, blue: 1.0)
    static let load = Color(red: 1.0, green: 0.56, blue: 0.25)

    static func recovery(_ zone: RecoveryResult.Zone?) -> Color {
        switch zone {
        case .green: return green
        case .yellow: return yellow
        case .red: return red
        case nil: return tertiary
        }
    }

    static func illness(_ level: IllnessSignal.Level) -> Color {
        switch level {
        case .clear: return green
        case .watch: return yellow
        case .alert: return red
        }
    }

    static func stage(_ s: SleepStage) -> Color {
        switch s {
        case .awake: return Color.white.opacity(0.75)
        case .light: return Color(red: 0.45, green: 0.55, blue: 1.0)
        case .deep: return Color(red: 0.32, green: 0.22, blue: 0.85)
        case .rem: return Color(red: 0.35, green: 0.85, blue: 0.95)
        case .unknown: return Color.gray
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Theme.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.tertiary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.cardBorder))
    }
}

/// The signature ring: value fraction, optional target tick, big number in the middle.
struct ScoreRing: View {
    let fraction: Double
    let color: Color
    let value: String
    let label: String
    var target: Double?
    var size: CGFloat = 104

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.8), value: fraction)
                if let target {
                    Capsule().fill(.white).frame(width: 3, height: 15)
                        .offset(y: -size / 2)
                        .rotationEffect(.degrees(360 * min(1, target)))
                }
                Text(value).font(.system(size: size * 0.26, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Theme.secondary)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var sub: String?
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            if let sub { Text(sub).font(.caption2).foregroundStyle(Theme.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Theme.tertiary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}

enum Fmt {
    static func hm(_ minutes: Double) -> String { "\(Int(minutes) / 60)h \(String(format: "%02d", Int(minutes) % 60))m" }
    static func clock(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "–" }
    static func relative(_ d: Date?) -> String {
        guard let d else { return "never" }
        return d.formatted(.relative(presentation: .named))
    }
    static func dayTitle(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        if key == DayKey.today() { return "Today" }
        if key == DayKey.addDays(DayKey.today(), -1) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month().day())
    }
}

extension View {
    func screenBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.background.ignoresSafeArea())
    }
}
