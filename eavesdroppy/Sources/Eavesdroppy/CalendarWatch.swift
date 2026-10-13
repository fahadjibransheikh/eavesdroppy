import EventKit
import Foundation

// D11: find calendar events that are about to start and look like a call. EventKit runs in this process; the
// permission is Droppy's, asked through host.permissions by the droplet, never here. Foundation + EventKit only.

struct CallEvent: Equatable {
    var key: String          // eventIdentifier + start: the identifier alone is shared by every occurrence of a recurring event
    var title: String
    var start: Date
    var attendees: [String]  // names, or email addresses when there is no name
    var hasLink: Bool

    var subtitle: String {
        let n = attendees.count
        return n > 0 ? "\(n) attendee\(n == 1 ? "" : "s")" : "Video call"
    }
}

enum CallEventFilter {
    /// Hosts whose URLs mean a video call, looked for in an event's url, location and notes.
    static let linkHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    static func hasMeetingLink(_ texts: [String?]) -> Bool {
        texts.contains { t in
            guard let t = t?.lowercased(), !t.isEmpty else { return false }
            return linkHosts.contains { t.contains($0) }
        }
    }

    /// A call is an event with a video link or at least one other attendee.
    static func isCall(hasLink: Bool, otherAttendees: Int) -> Bool { hasLink || otherAttendees > 0 }

    /// The window an event is offered in: it starts within the next `lead` seconds, or started at most `grace` ago.
    static func inWindow(start: Date, end: Date, now: Date, lead: TimeInterval = 60, grace: TimeInterval = 300) -> Bool {
        start <= now.addingTimeInterval(lead) && start >= now.addingTimeInterval(-grace) && end > now
    }

    /// "Name", else the address without `mailto:`.
    /// The event a call that just started most likely belongs to: the one whose start is nearest to `now`.
    static func nearest(_ events: [CallEvent], now: Date) -> CallEvent? {
        events.min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    static func displayName(name: String?, url: URL?) -> String? {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        guard let u = url?.absoluteString, !u.isEmpty else { return nil }
        return u.lowercased().hasPrefix("mailto:") ? String(u.dropFirst(7)) : nil
    }
}

/// Queries on its own serial queue (EKEventStore calls can take a while); results come back on the main queue.
final class CalendarWatcher: @unchecked Sendable {
    private let q = DispatchQueue(label: "eavesdroppy.calendar", qos: .utility)
    private var store: EKEventStore?

    /// A fresh store: the permission may have been granted after the last one was made.
    func reset() { q.async { self.store = nil } }

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Call events in the offer window now (see `CallEventFilter.inWindow`; `lead` and `grace` widen it). Empty without access.
    func upcoming(now: Date = Date(), lead: TimeInterval = 60, grace: TimeInterval = 300, done: @escaping ([CallEvent]) -> Void) {
        q.async { [self] in
            guard authorized else { DispatchQueue.main.async { done([]) }; return }
            let store = self.store ?? EKEventStore()
            self.store = store
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-grace), end: now.addingTimeInterval(lead + 1), calendars: nil)
            let events = store.events(matching: pred).compactMap { Self.callEvent($0, now: now, lead: lead, grace: grace) }
                .sorted { $0.start < $1.start }
            DispatchQueue.main.async { done(events) }
        }
    }

    private static func callEvent(_ e: EKEvent, now: Date, lead: TimeInterval, grace: TimeInterval) -> CallEvent? {
        guard !e.isAllDay, e.status != .canceled, let start = e.startDate, let end = e.endDate,
              CallEventFilter.inWindow(start: start, end: end, now: now, lead: lead, grace: grace) else { return nil }
        let people = e.attendees ?? []
        if people.first(where: \.isCurrentUser)?.participantStatus == .declined { return nil }
        let others = people.filter { !$0.isCurrentUser && $0.participantType != .resource && $0.participantType != .group }
        let link = CallEventFilter.hasMeetingLink([e.url?.absoluteString, e.location, e.notes])
        guard CallEventFilter.isCall(hasLink: link, otherAttendees: others.count) else { return nil }
        let names = others.compactMap { CallEventFilter.displayName(name: $0.name, url: $0.url) }
        let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CallEvent(key: "\(e.eventIdentifier ?? e.calendarItemIdentifier)|\(Int(start.timeIntervalSince1970))",
                         title: title.isEmpty ? "Meeting" : title, start: start, attendees: names, hasLink: link)
    }
}
