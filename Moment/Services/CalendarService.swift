import Foundation
import EventKit

/// Optional calendar context. Never requested during onboarding, never writes without confirmation.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func connect() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Titles + dates of upcoming events, used only as context (e.g. to avoid resurfacing a plan on a busy day).
    func upcomingEvents(days: Int = 14) -> [(title: String, date: Date)] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: .now, end: .now.adding(days: days), calendars: nil)
        return store.events(matching: predicate).map { ($0.title ?? "", $0.startDate) }
    }

    /// Explicit user action only.
    func addEvent(title: String, date: Date, isAllDay: Bool, notes: String?) throws -> String {
        guard isAuthorized else { throw NSError(domain: "Moment.Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar isn't connected."]) }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = isAllDay ? date : Calendar.current.date(byAdding: .hour, value: 1, to: date)
        event.isAllDay = isAllDay
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }
}
