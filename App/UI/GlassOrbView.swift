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
/// Six beats at resting HR each time Home is shown: on appear and every time the app comes back to the foreground.
struct HeartbeatHaptics: ViewModifier {
    let bpm: Double
    @Environment(\.scenePhase) private var phase
    @State private var tick = 0
    @State private var opens = 0

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: tick)
            .onChange(of: phase) { _, p in if p == .active { opens += 1 } }
            .task(id: opens) {
                let interval = 60 / max(bpm, 35)
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(interval))
                    tick += 1
                }
            }
    }
}
