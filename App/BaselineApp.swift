import SwiftUI
import BackgroundTasks

@main
struct BaselineApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    static let refreshID = "com.dagarwal.baseline.refresh"

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                await AppModel.shared?.sync(background: true)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.green)
                .onAppear {
                    AppModel.shared = model
                    if model.hasAppleHealthData { model.startBackgroundDelivery() }
                }
        }
        .onChange(of: phase) { _, p in
            if p == .active, model.hasAppleHealthData { Task { await model.sync() } }
            if p == .background { Self.scheduleRefresh() }
        }
    }

    /// iOS decides when this actually runs (usually overnight or early morning).
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }
}

extension AppModel {
    /// Lets the background task reach the live model.
    static weak var shared: AppModel?
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView().tabItem { Label("Today", systemImage: "circle.circle") }.tag(AppModel.Tab.today)
            TrainingView().tabItem { Label("Training", systemImage: "figure.run") }.tag(AppModel.Tab.training)
            HealthView().tabItem { Label("Health", systemImage: "heart.text.square") }.tag(AppModel.Tab.health)
            JournalView().tabItem { Label("Journal", systemImage: "book.closed") }.tag(AppModel.Tab.journal)
            CoachView().tabItem { Label("Coach", systemImage: "sparkles") }.tag(AppModel.Tab.coach)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
