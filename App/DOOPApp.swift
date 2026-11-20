import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct DOOPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    static let refreshID = "com.dagarwal.doop.refresh"

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
                .tint(Ember.ember)
                .onAppear {
                    AppModel.shared = model
                    if model.hasAppleHealthData { model.startBackgroundDelivery() }
                }
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                Task {
                    await model.renewGoogleIfNeeded()
                    if model.hasAppleHealthData { await model.sync() }
                }
            }
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
    /// Lets the background task and notification handler reach the live model.
    static weak var shared: AppModel?
}

/// Answers the one question straight from the notification, without opening the app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let day = info["day"] as? String, let factor = info["factor"] as? String,
              ["YES", "NO"].contains(response.actionIdentifier) else { return }
        let yes = response.actionIdentifier == "YES"
        await MainActor.run {
            AppModel.shared?.answer(DailyQuestion(day: day, factor: factor, prompt: "", evidence: ""), yes: yes)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Today", systemImage: "circle.circle", value: AppModel.Tab.today) { TodayTab() }
            Tab("Sleep", systemImage: "moon", value: AppModel.Tab.sleep) { SleepTab() }
            Tab("Train", systemImage: "figure.run", value: AppModel.Tab.train) { TrainTab() }
            Tab("Learn", systemImage: "sparkle.magnifyingglass", value: AppModel.Tab.learn) { LearnTab() }
            Tab("Body", systemImage: "heart.text.square", value: AppModel.Tab.body) { BodyTab() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
