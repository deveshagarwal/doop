import SwiftUI

/// The ember palette: near-black, warm bone, one ember accent. Nothing else.
enum Ember {
    static let ink = Color(red: 0.024, green: 0.024, blue: 0.027)
    static let bone = Color(red: 0.937, green: 0.914, blue: 0.875)
    static let bone2 = bone.opacity(0.58)
    static let bone3 = bone.opacity(0.30)
    static let hair = bone.opacity(0.11)
    static let ember = Color(red: 1.0, green: 0.70, blue: 0.42)
    static let glass = LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func stage(_ s: SleepStage) -> Color {
        switch s {
        case .deep: return ember
        case .rem: return bone
        case .light: return bone2
        case .awake, .unknown: return bone3
        }
    }

    static func zoneWord(_ z: RecoveryResult.Zone?) -> String {
        switch z {
        case .green: return "primed"
        case .yellow: return "steady"
        case .red: return "run down"
        case nil: return "no data"
        }
    }
}

extension Font {
    static func ultra(_ size: CGFloat) -> Font { .system(size: size, weight: .ultraLight) }
    static func light(_ size: CGFloat) -> Font { .system(size: size, weight: .light) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// Tiny uppercase monospace label. `accent` makes it ember.
struct Label9: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    var body: some View {
        Text(text.uppercased()).font(.mono(9.5, accent ? .semibold : .medium)).tracking(1.5)
            .foregroundStyle(accent ? Ember.ember : Ember.bone2)
    }
}

/// The ⓘ: tap for a plain-English explanation of a number.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Text("i").font(.system(size: 9, weight: .semibold).italic())
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(Ember.bone3, lineWidth: 1))
                .foregroundStyle(Ember.bone2)
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 6) {
                Label9(title, accent: true)
                Text(text).font(.system(size: 13)).foregroundStyle(Ember.bone).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color(red: 0.11, green: 0.105, blue: 0.10))
        }
    }
}

/// A label with its ⓘ.
struct InfoLabel: View {
    let text: String
    var accent = false
    var info: String?
    var body: some View {
        HStack(spacing: 6) {
            Label9(text, accent: accent)
            if let info { InfoButton(title: text, text: info) }
        }
    }
}

/// Counts up from zero the first time it appears.
struct CountUp: View {
    let value: Double
    var decimals = 0
    var font: Font = .ultra(64)
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(String(format: "%.\(decimals)f", shown))
            .font(font).monospacedDigit().tracking(-2)
            .contentTransition(.numericText(value: shown))
            .onAppear {
                if reduceMotion { shown = value; return }
                withAnimation(.easeOut(duration: 1.0)) { shown = value }
            }
            .onChange(of: value) { _, v in withAnimation(.easeOut(duration: 0.5)) { shown = v } }
    }
}

/// The big number at the top of a page.
struct PageHero: View {
    let label: String
    var info: String?
    let value: Double
    var decimals = 0
    var unit: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            InfoLabel(text: label, accent: true, info: info)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUp(value: value, decimals: decimals, font: .ultra(68))
                if let unit { Text(unit).font(.light(22)).foregroundStyle(Ember.bone3) }
            }
            Text(caption).font(.system(size: 13)).foregroundStyle(Ember.bone2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bar that grows into place when it appears.
struct GrowBar: View {
    let fraction: Double
    var accent = false
    @State private var grown = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Ember.hair)
                Capsule().fill(accent ? Ember.ember : Ember.bone2)
                    .frame(width: g.size.width * (grown ? min(max(fraction, 0), 1) : 0))
            }
        }
        .frame(height: 3)
        .onAppear { withAnimation(.spring(duration: 1.1).delay(0.15)) { grown = true } }
    }
}

/// Label, value, optional ember delta, bar underneath.
struct MetricRow: View {
    let name: String
    var info: String?
    let value: String
    var delta: String?
    var fraction: Double?
    var accent = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13.5))
                if let info { InfoButton(title: name, text: info) }
                Spacer()
                Text(value).font(.light(15)).monospacedDigit()
                if let delta { Text(delta).font(.mono(10, .semibold)).foregroundStyle(Ember.ember) }
            }
            if let fraction { GrowBar(fraction: fraction, accent: accent) }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Ember.hair).frame(height: 1) }
    }
}

/// Three small stats separated by hairlines.
struct Trio: View {
    let items: [(label: String, value: String, note: String?)]
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                VStack(alignment: .leading, spacing: 2) {
                    Label9(it.label)
                    Text(it.value).font(.light(20)).monospacedDigit().tracking(-0.5)
                    if let n = it.note { Text(n).font(.mono(9.5, .semibold)).foregroundStyle(Ember.ember) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, i == 0 ? 0 : 10)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(Ember.hair).frame(width: 1) } }
            }
        }
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ember.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

/// A titled section on a page.
struct Section9<Content: View>: View {
    let title: String
    var info: String?
    var trailing: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                InfoLabel(text: title, info: info)
                Spacer()
                if let trailing { Label9(trailing) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Five little bars showing how sure a model is.
struct ConfidenceBars: View {
    let value: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(Double(i) < (value * 5).rounded() ? Ember.ember : Ember.hair).frame(width: 9, height: 3)
            }
        }
        .accessibilityLabel("Confidence \(Int(value * 100)) percent")
    }
}

/// Animates `progress` 0→1 on first appearance, for charts that draw themselves in.
struct DrawIn: ViewModifier {
    @Binding var progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.onAppear {
            if reduceMotion { progress = 1 } else { withAnimation(.easeOut(duration: 1.2)) { progress = 1 } }
        }
    }
}

/// Every page: ink background, scroll, room above the tab bar.
struct EmberPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Ember.ink.ignoresSafeArea())
        .foregroundStyle(Ember.bone)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

enum Fmt {
    static func hm(_ minutes: Double) -> String { "\(Int(minutes) / 60)h \(String(format: "%02d", Int(minutes) % 60))m" }
    static func clock(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "–" }
    static func relative(_ d: Date?) -> String { d.map { $0.formatted(.relative(presentation: .named)) } ?? "never" }
    static func dayTitle(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        if key == DayKey.today() { return "Today" }
        if key == DayKey.addDays(DayKey.today(), -1) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    static func signed(_ v: Double, _ decimals: Int = 0) -> String { String(format: "%+.\(decimals)f", v) }
}
