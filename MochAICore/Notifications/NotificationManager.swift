import Foundation
import UserNotifications

public enum MochaiNotificationAction: String, Sendable {
    case openProject
    case openTerminal
    case resumeAtReset
    case notifyOnly
    case continueSession
    case viewDetails
}

public struct PostedNotification: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var body: String
}

@MainActor
public protocol NotificationPosting: AnyObject {
    func requestAuthorization() async -> Bool
    func registerCategories()
    func post(identifier: String, title: String, body: String, sessionID: UUID?, category: String)
}

@MainActor
public final class NotificationManager: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    public var onAction: ((MochaiNotificationAction, UUID?) -> Void)?
    public private(set) var delivered: [PostedNotification] = []
    private let center: UNUserNotificationCenter

    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            MochaiLog.notifications.error("Notification permission request failed")
            return false
        }
    }

    public func registerCategories() {
        let completion = UNNotificationCategory(
            identifier: "completion",
            actions: [UNNotificationAction(identifier: MochaiNotificationAction.openProject.rawValue, title: "Open Project")],
            intentIdentifiers: []
        )
        let input = UNNotificationCategory(
            identifier: "input",
            actions: [UNNotificationAction(identifier: MochaiNotificationAction.openTerminal.rawValue, title: "Open Terminal")],
            intentIdentifiers: []
        )
        let limit = UNNotificationCategory(
            identifier: "limit",
            actions: [
                UNNotificationAction(identifier: MochaiNotificationAction.resumeAtReset.rawValue, title: "Resume at Reset"),
                UNNotificationAction(identifier: MochaiNotificationAction.notifyOnly.rawValue, title: "Notify Only")
            ],
            intentIdentifiers: []
        )
        let available = UNNotificationCategory(
            identifier: "available",
            actions: [
                UNNotificationAction(identifier: MochaiNotificationAction.continueSession.rawValue, title: "Continue"),
                UNNotificationAction(identifier: MochaiNotificationAction.openProject.rawValue, title: "Open")
            ],
            intentIdentifiers: []
        )
        let failed = UNNotificationCategory(
            identifier: "failed",
            actions: [UNNotificationAction(identifier: MochaiNotificationAction.viewDetails.rawValue, title: "View Details")],
            intentIdentifiers: []
        )
        center.setNotificationCategories([completion, input, limit, available, failed])
    }

    public func post(identifier: String, title: String, body: String, sessionID: UUID?, category: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        if let sessionID {
            content.userInfo = ["sessionID": sessionID.uuidString]
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        delivered.append(PostedNotification(identifier: identifier, title: title, body: body))
        center.add(request) { error in
            if error != nil {
                MochaiLog.notifications.error("Could not deliver a notification")
            }
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = MochaiNotificationAction(rawValue: response.actionIdentifier)
            ?? (response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : nil)
        let session = (response.notification.request.content.userInfo["sessionID"] as? String).flatMap(UUID.init)
        let resolved = action ?? .viewDetails
        await MainActor.run {
            self.onAction?(resolved, session)
        }
    }
}
