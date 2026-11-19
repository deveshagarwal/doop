import Foundation
import AuthenticationServices
import UIKit
import UserNotifications

/// Presents Google sign-in in the system browser sheet.
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthenticator()
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? AuthError.exchangeFailed("No callback")) }
            }
            s.presentationContextProvider = self
            session = s
            if !s.start() { cont.resume(throwing: AuthError.exchangeFailed("Couldn't open the sign-in sheet")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

enum Notifier {
    static let questionCategory = "DAILY_QUESTION"

    static func requestPermission() async {
        let yes = UNNotificationAction(identifier: "YES", title: "Yes")
        let no = UNNotificationAction(identifier: "NO", title: "No")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: questionCategory, actions: [yes, no], intentIdentifiers: []),
        ])
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func send(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// Morning notification carrying the one yes/no, answerable without opening the app.
    static func ask(id: String, title: String, body: String, day: String, factor: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = questionCategory
        c.userInfo = ["day": day, "factor": factor]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    static func schedule(id: String, at date: Date, title: String, body: String) {
        guard date > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c,
                                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}
