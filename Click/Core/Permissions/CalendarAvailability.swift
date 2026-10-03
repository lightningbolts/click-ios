import EventKit
import Foundation
import Observation

/// Free/busy from the calendars on this iPhone (spec §81), so plans and events can say whether
/// you're free and suggest the next free time. Read-only and on-device: only busy start/end
/// times for the coming week are kept, in memory. Titles, places and people are never read into
/// Click, nothing leaves the phone, and Click never adds or changes events.
@Observable
@MainActor
final class CalendarAvailability {
    enum Fit: Equatable {
        case free
        /// Something on your calendar overlaps; `nextFree` is the first free start later that day.
        case busy(nextFree: Date?)

        var text: String {
            self == .free ? "You're free then" : "Busy on your calendar then"
        }

        var systemImage: String {
            self == .free ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        }
    }

    private(set) var isAuthorized = false
    /// Merged busy times, earliest first, from the last read up to `readUntil`.
    private(set) var busy: [DateInterval] = []
    private(set) var readUntil: Date?

    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// How far ahead the calendar is read.
    nonisolated static let window: TimeInterval = 7 * 86_400
    /// A read younger than this is reused; calendar edits invalidate it sooner.
    nonisolated static let freshFor: TimeInterval = 300
    /// Plans without an end time count as an hour.
    nonisolated static let assumedLength: TimeInterval = 3600

    private final class Store: @unchecked Sendable {
        let value = EKEventStore()
    }

    /// Created on the first read with access, so it sees the grant.
    private nonisolated static let shared = Store()

    init() {
        _ = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readAt = nil
                Task { await self.refresh() }
            }
        }
    }

    /// Reads the coming week unless a fresh read is on hand. Without access it's quiet: no
    /// prompt, nothing shown.
    func refresh() async {
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if isAuthorized != authorized { isAuthorized = authorized }
        guard authorized else {
            if readUntil != nil {
                busy = []
                readUntil = nil
            }
            readAt = nil
            return
        }
        if let readAt, Date().timeIntervalSince(readAt) < Self.freshFor { return }
        if let reading { return await reading.value }
        let task = Task {
            let start = Date()
            let end = start.addingTimeInterval(Self.window)
            let read = await Task.detached(priority: .userInitiated) { Self.readBusy(from: start, to: end) }.value
            busy = read
            readUntil = end
            readAt = start
        }
        reading = task
        await task.value
        reading = nil
    }

    /// Whether `interval` is clear on your calendar; nil without access, before the first read,
    /// or past the week that was read.
    func fit(_ interval: DateInterval) -> Fit? {
        guard isAuthorized, let readUntil, interval.start < readUntil else { return nil }
        return Self.fit(interval, busy: busy)
    }

    /// `start` to `end`, or an hour from `start`.
    func fit(start: Date, end: Date?) -> Fit? {
        fit(DateInterval(start: start, end: max(end ?? start.addingTimeInterval(Self.assumedLength), start)))
    }

    // MARK: - Pure helpers (tested)

    nonisolated static func fit(_ interval: DateInterval, busy: [DateInterval], calendar: Calendar = .current) -> Fit {
        guard busy.contains(where: { overlaps($0, interval) }) else { return .free }
        let dayEnd = calendar.dateInterval(of: .day, for: interval.start)?.end ?? interval.start
        return .busy(nextFree: nextFree(after: interval.start, length: interval.duration, busy: busy, before: dayEnd))
    }

    /// Touching isn't overlapping: a plan can start the minute a meeting ends.
    nonisolated static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// The first quarter-hour start at or after `start` that fits `length` between busy times
    /// and ends by `limit`.
    nonisolated static func nextFree(after start: Date, length: TimeInterval, busy: [DateInterval], before limit: Date) -> Date? {
        var candidate = start
        for slot in busy where slot.end > candidate {
            if slot.start >= candidate.addingTimeInterval(length) { break }
            candidate = max(candidate, roundedUpToQuarterHour(slot.end))
        }
        return candidate.addingTimeInterval(length) <= limit ? candidate : nil
    }

    /// Sorted, with overlapping and touching times joined.
    nonisolated static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, interval.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                out.append(interval)
            }
        }
        return out
    }

    nonisolated static func roundedUpToQuarterHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
    }

    /// Busy times only: all-day, free, cancelled and declined events don't count.
    private nonisolated static func readBusy(from start: Date, to end: Date) -> [DateInterval] {
        let store = shared.value
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return merged(events.compactMap { event in
            guard !event.isAllDay, event.availability != .free, event.status != .canceled,
                  event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let eventStart = event.startDate, let eventEnd = event.endDate, eventEnd > eventStart
            else { return nil }
            return DateInterval(start: eventStart, end: eventEnd)
        })
    }
}
