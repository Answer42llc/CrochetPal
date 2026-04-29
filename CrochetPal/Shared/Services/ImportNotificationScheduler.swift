import Foundation

#if os(iOS)
import UIKit
import UserNotifications
#endif

@MainActor
protocol ImportNotificationScheduling {
    func prepareForImportCompletionNotifications() async
    func notifyImportCompleted(projectID: UUID, projectTitle: String) async
}

struct NoopImportNotificationScheduler: ImportNotificationScheduling {
    func prepareForImportCompletionNotifications() async {}

    func notifyImportCompleted(projectID: UUID, projectTitle: String) async {}
}

#if os(iOS)
struct LocalImportNotificationScheduler: ImportNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func prepareForImportCompletionNotifications() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }

        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyImportCompleted(projectID: UUID, projectTitle: String) async {
        guard UIApplication.shared.applicationState != .active else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus.allowsImportCompletionNotification else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pattern 导入完成"
        content.body = "\(projectTitle) 已解析完成，可以开始编织。"
        content.sound = .default
        content.threadIdentifier = "pattern-import"
        content.userInfo = ["projectID": projectID.uuidString]

        let request = UNNotificationRequest(
            identifier: "pattern-import-completed-\(projectID.uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

private extension UNAuthorizationStatus {
    var allowsImportCompletionNotification: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}
#else
typealias LocalImportNotificationScheduler = NoopImportNotificationScheduler
#endif
