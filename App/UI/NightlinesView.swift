import SwiftUI
import CoreMotion

/// One night of heart rate, resampled to a fixed number of points across the sleep window.
struct NightLine: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let bpm: [Double]

    static let points = 140

    /// Builds the most recent `count` nights that have enough heart-rate coverage to draw.
    static func build(days: [String: DayRecord], upTo key: String, count: Int = 32) -> [NightLine] {
        let keys = DayKey.keys(from: DayKey.addDays(key, -(count + 10)), to: key)
        var out: [NightLine] = []
        for k in keys {
            guard let d = days[k], let s = d.mainSleep, s.minutesInBed > 120 else { continue }
            let inWindow: (HRSample) -> Bool = { $0.t >= s.start && $0.t <= s.end }
            let evening: [HRSample] = days[DayKey.addDays(k, -1)]?.hrSamples.filter(inWindow) ?? []
            let samples: [HRSample] = evening + d.hrSamples.filter(inWindow)
            guard samples.count > 40 else { continue }
            var bins = Array(repeating: (0.0, 0), count: points)
            let span = s.end.timeIntervalSince(s.start)
            for x in samples {
                let i = min(points - 1, Int(x.t.timeIntervalSince(s.start) / span * Double(points)))
                bins[i].0 += x.bpm
                bins[i].1 += 1
            }
            var values: [Double?] = bins.map { $0.1 > 0 ? $0.0 / Double($0.1) : nil }
            guard values.compactMap({ $0 }).count > points / 2 else { continue }
            // Fill gaps by carrying the nearest value, then smooth.
            var last = values.first(where: { $0 != nil }) ?? nil
            for i in values.indices { if let v = values[i] { last = v } else { values[i] = last } }
            var v = values.map { $0 ?? 60 }
            for _ in 0..<3 {
                v = v.indices.map { i in (v[max(0, i - 1)] + 2 * v[i] + v[min(v.count - 1, i + 1)]) / 4 }
            }
            out.append(NightLine(id: k, start: s.start, end: s.end, bpm: v))
        }
        return Array(out.suffix(count))
    }
}

@Observable
final class TiltSensor {
    var roll = 0.0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let m else { return }
            self?.roll = (self?.roll ?? 0) * 0.85 + m.attitude.roll * 0.15
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Every night of heart rate as a ridge receding into fog, last night glowing in front.
/// Left to right is clock time shared by all nights, so each ridge starts when you fell asleep
/// and ends when you woke: late nights and early mornings line up (or don't) at a glance.
/// Height is how far heart rate dropped: the taller the hill, the calmer your heart.
struct NightlinesView: View {
    let nights: [NightLine]
    @State private var tilt = TiltSensor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ember = Color(red: 1.0, green: 0.70, blue: 0.42)
    private let bone = Color(red: 0.94, green: 0.91, blue: 0.87)

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            Canvas { ctx, size in draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
        }
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
        .accessibilityLabel(accessibilitySummary)
    }

    /// Minutes since 18:00, so an evening bedtime and a morning wake share one axis.
    static func clock(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) - 18 * 60
        return m < 0 ? m + 1440 : m
    }

    /// "11:23p" from minutes after 18:00.
    static func label12(_ clockMinutes: Double) -> String {
        let m = Int(clockMinutes + 18 * 60) % 1440
        let h = m / 60
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m % 60))\(h >= 12 ? "p" : "a")"
    }

    static func label(_ clockMinutes: Double) -> String {
        let m = Int(clockMinutes + 18 * 60) % 1440
        let h = m / 60
        return h == 0 ? "12a" : (h < 12 ? "\(h)a" : (h == 12 ? "12p" : "\(h - 12)p"))
    }

    private var window: (lo: Double, hi: Double) {
        let lo = (nights.map { Self.clock($0.start) }.min() ?? 240) - 30
        let hi = (nights.map { Self.clock($0.end) }.max() ?? 780) + 30
        return (floor(lo / 60) * 60, ceil(hi / 60) * 60)
    }

    private var accessibilitySummary: String {
        let beds = nights.map { Self.clock($0.start) }.sorted(), wakes = nights.map { Self.clock($0.end) }.sorted()
        guard !beds.isEmpty else { return "No nights yet" }
        return "Last \(nights.count) nights. Typical bedtime \(Self.label(beds[beds.count / 2])), typical wake \(Self.label(wakes[wakes.count / 2]))."
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let n = nights.count
        guard n > 0 else { return }
        let w = size.width, h = size.height
        let (lo, hi) = window
        let bpmLo = nights.flatMap(\.bpm).min() ?? 45
        let bpmHi = nights.flatMap(\.bpm).max() ?? 75
        let range = max(bpmHi - bpmLo, 8)
        let front = h * 0.86, horizon = h * 0.14
        let zFar = 1 + Double(n - 1) * 0.16

        func project(_ clock: Double, z: Double) -> CGFloat {
            let sway = (sin(t * 0.35) * 0.04 + tilt.roll * 0.35) * (1 - 1 / z) * w
            let width = w * 0.92 * (0.62 + 0.38 / z)
            return w / 2 + sway + ((clock - lo) / (hi - lo) - 0.5) * width
        }
        func baseY(_ z: Double) -> CGFloat { horizon + (front - horizon) / z }

        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(Gradient(colors: [ember.opacity(0.06), .clear]),
                                       center: CGPoint(x: w / 2, y: h * 0.2), startRadius: 0, endRadius: w * 0.8))

        // Hour grid receding into the distance, labels along the front.
        var hour = lo
        while hour <= hi {
            var g = Path()
            g.move(to: CGPoint(x: project(hour, z: 1), y: front + 6))
            g.addLine(to: CGPoint(x: project(hour, z: zFar), y: baseY(zFar)))
            ctx.stroke(g, with: .color(bone.opacity(0.07)), lineWidth: 0.6)
            ctx.draw(Text(Self.label(hour)).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(bone.opacity(0.45)),
                     at: CGPoint(x: project(hour, z: 1), y: front + 16))
            hour += 120
        }

        // Typical bed and wake times as guide lines through every night.
        let beds = nights.map { Self.clock($0.start) }.sorted(), wakes = nights.map { Self.clock($0.end) }.sorted()
        for typical in [beds[beds.count / 2], wakes[wakes.count / 2]] {
            var g = Path()
            g.move(to: CGPoint(x: project(typical, z: 1), y: front + 4))
            g.addLine(to: CGPoint(x: project(typical, z: zFar), y: baseY(zFar)))
            ctx.stroke(g, with: .color(ember.opacity(0.28)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        }

        for (k, night) in nights.enumerated() {
            let isLast = k == n - 1
            let depth = Double(k) / Double(max(n - 1, 1))
            let z = 1 + Double(n - 1 - k) * 0.16
            let y0 = baseY(z)
            let amp = h * 0.30 / sqrt(z)
            let c0 = Self.clock(night.start), c1 = Self.clock(night.end)
            let points: [CGPoint] = night.bpm.enumerated().map { i, v in
                let u = Double(i) / Double(night.bpm.count - 1)
                let envelope = pow(sin(.pi * u), 0.35)
                return CGPoint(x: project(c0 + u * (c1 - c0), z: z), y: y0 - (bpmHi - v) / range * amp * envelope)
            }

            var line = Path()
            line.move(to: points[0])
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                line.addQuadCurve(to: mid, control: points[i])
            }
            line.addLine(to: points[points.count - 1])
            var fill = line
            fill.addLine(to: CGPoint(x: points.last!.x, y: y0 + 2))
            fill.addLine(to: CGPoint(x: points[0].x, y: y0 + 2))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(Color(white: 0.03)))

            // Bed and wake ends.
            let endAlpha = isLast ? 1 : 0.1 + 0.55 * pow(depth, 2)
            for p in [points[0], points[points.count - 1]] {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)),
                         with: .color((isLast ? ember : bone).opacity(endAlpha)))
            }
            // Weekday for the nearest nights.
            if n - 1 - k < 7, let date = DayKey.date(from: night.id) {
                ctx.draw(Text(isLast ? "LAST NIGHT" : date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle((isLast ? ember : bone).opacity(isLast ? 0.9 : 0.25 + 0.5 * depth)),
                         at: CGPoint(x: points[0].x - 6, y: y0 - 1), anchor: .trailing)
            }

            if isLast {
                var glow = ctx
                glow.addFilter(.shadow(color: ember.opacity(0.9), radius: 9))
                glow.stroke(line, with: .color(ember), lineWidth: 1.8)
                let timeFont = Font.system(size: 10, weight: .semibold, design: .monospaced)
                ctx.draw(Text(night.start.formatted(date: .omitted, time: .shortened)).font(timeFont).foregroundStyle(ember),
                         at: CGPoint(x: points[0].x, y: points[0].y - 14))
                ctx.draw(Text(night.end.formatted(date: .omitted, time: .shortened)).font(timeFont).foregroundStyle(ember),
                         at: CGPoint(x: points.last!.x, y: points.last!.y - 14))

                let minIndex = night.bpm.indices.min(by: { night.bpm[$0] < night.bpm[$1] }) ?? 0
                let progress = reduceMotion ? Double(minIndex) : (t * 9).truncatingRemainder(dividingBy: Double(points.count) * 1.4)
                let i = min(points.count - 1, Int(progress))
                let p = points[i]
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)),
                         with: .radialGradient(Gradient(colors: [ember.opacity(0.7), ember.opacity(0.2), .clear]),
                                               center: p, startRadius: 0, endRadius: 18))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)), with: .color(.white))
                let at = night.start.addingTimeInterval(night.end.timeIntervalSince(night.start) * Double(i) / Double(points.count - 1))
                ctx.draw(Text("\(at.formatted(date: .omitted, time: .shortened)) · \(Int(night.bpm[i])) bpm")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.68)),
                         at: CGPoint(x: min(max(p.x, 62), w - 62), y: p.y + 16))
            } else {
                ctx.stroke(line, with: .color(bone.opacity(0.05 + 0.5 * pow(depth, 1.6))), lineWidth: 0.6 + 0.7 * depth)
            }
        }
    }
}
