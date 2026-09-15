import Foundation
import UserNotifications

/// Local notifications with a daily budget. Only genuinely useful content, never "come back".
@MainActor
final class NotificationService {
    static let categoryFollowUp = "MOMENT_FOLLOW_UP"
    static let categoryUpcoming = "MOMENT_UPCOMING"
    static let actionDone = "MOMENT_DONE"
    static let actionRemindTomorrow = "MOMENT_REMIND_TOMORROW"

    private let center = UNUserNotificationCenter.current()
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        registerCategories()
    }

    private func registerCategories() {
        let done = UNNotificationAction(identifier: Self.actionDone, title: "Done", options: [])
        let later = UNNotificationAction(identifier: Self.actionRemindTomorrow, title: "Remind me tomorrow", options: [])
        let followUp = UNNotificationCategory(identifier: Self.categoryFollowUp, actions: [done, later], intentIdentifiers: [])
        let upcoming = UNNotificationCategory(identifier: Self.categoryUpcoming, actions: [later], intentIdentifiers: [])
        center.setNotificationCategories([followUp, upcoming])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces MOMENT's scheduled notifications with the given recommendations, respecting the
    /// daily budget. Explicit user reminders always keep their slot.
    func schedule(_ recommendations: [SurfaceEngine.Recommendation], explicitReminders: [(memory: Memory, date: Date)], now: Date = .now) async {
        guard settings.notificationsEnabled, await authorizationStatus() == .authorized else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("surface-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        // Explicit reminders
        for (memory, date) in explicitReminders where date > now {
            let content = UNMutableNotificationContent()
            if settings.notificationDetails {
                content.title = memory.title
                content.body = memory.summary.isBlank ? "You asked to be reminded." : memory.summary
            } else {
                content.title = "Reminder"
                content.body = "Something you saved is due now. Open MOMENT to see it."
            }
            content.categoryIdentifier = Self.categoryFollowUp
            content.userInfo = ["memoryID": memory.id.uuidString]
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "reminder-\(memory.id.uuidString)", content: content, trigger: trigger))
        }

        // Budgeted surface notifications
        let planned = NotificationBudget.plan(recommendations, budgetPerDay: settings.dailyNotificationBudget, now: now)
        for (rec, fireDate) in planned {
            let content = UNMutableNotificationContent()
            content.title = rec.category.rawValue
            content.body = settings.notificationDetails ? rec.headline + (rec.detail.map { " \($0)" } ?? "") : Self.genericBody(for: rec.category)
            content.categoryIdentifier = rec.category == .followUp ? Self.categoryFollowUp : Self.categoryUpcoming
            content.userInfo = ["memoryID": rec.memoryID.uuidString]
            content.sound = .default
            content.threadIdentifier = rec.category.rawValue
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "surface-\(rec.memoryID.uuidString)", content: content, trigger: trigger))
        }
        Log.notifications.info("Scheduled \(planned.count) surface notifications")
    }

    /// Content-free wording used unless the user enables details.
    static func genericBody(for category: SurfaceEngine.Category) -> String {
        switch category {
        case .followUp: "A promise you saved is still open."
        case .upcoming: "Something you saved is coming up soon."
        case .plan: "A plan you talked about is getting close."
        case .today: "Something you saved is due today."
        case .opportunity: "A gift idea you saved may be timely."
        case .remembered, .people: "Something you saved is relevant now."
        }
    }

    func cancelReminder(for memoryID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["reminder-\(memoryID.uuidString)", "surface-\(memoryID.uuidString)"])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// Pure budgeting: at most N per calendar day, highest priority first, only recommendations that allow it.
enum NotificationBudget {
    static func plan(_ recommendations: [SurfaceEngine.Recommendation], budgetPerDay: Int, now: Date, calendar: Calendar = .current) -> [(SurfaceEngine.Recommendation, Date)] {
        guard budgetPerDay > 0 else { return [] }
        var perDay: [String: Int] = [:]
        var out: [(SurfaceEngine.Recommendation, Date)] = []
        let candidates = recommendations
            .filter { $0.notificationAllowed && ($0.surfaceType == .notification || $0.surfaceType == .both) }
            .sorted { $0.priority > $1.priority }
        for rec in candidates {
            var fireDate = rec.recommendedTime ?? calendar.date(bySettingHour: 9, minute: 30, second: 0, of: now.adding(days: 1, calendar: calendar)) ?? now
            if fireDate <= now { fireDate = calendar.date(byAdding: .minute, value: 5, to: now) ?? now }
            let dayKey = calendar.startOfDay(for: fireDate).timeIntervalSinceReferenceDate.description
            guard perDay[dayKey, default: 0] < budgetPerDay else { continue }
            perDay[dayKey, default: 0] += 1
            out.append((rec, fireDate))
        }
        return out
    }
}
