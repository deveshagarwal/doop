import SwiftUI

/// Full-screen near-black with the beating glass sphere at 36% of the height.
struct GlassOrbView: View {
    var bpm: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = Float(timeline.date.timeIntervalSince(start))
            GeometryReader { g in
                Rectangle().fill(.black)
                    .colorEffect(ShaderLibrary.glassOrb(
                        .float2(Float(g.size.width), Float(g.size.height)),
                        .float(t), .float(Float(bpm)), .float(reduceMotion ? 0 : 1)))
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Taps once per heartbeat for the first few beats after the screen appears.
struct HeartbeatHaptics: ViewModifier {
    let bpm: Double
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: tick)
            .task {
                let interval = 60 / max(bpm, 35)
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(interval))
                    tick += 1
                }
            }
    }
}
