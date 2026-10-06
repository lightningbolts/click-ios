import EventKit
import CoreLocation
import EventKitUI
import SwiftUI

/// "Add to Calendar": you choose where it goes. Apple Calendar opens the system add-event sheet,
/// prefilled, with its own calendar picker (iCloud and any Google, Exchange or Outlook account on
/// this iPhone) and no permission prompt; Google Calendar and Outlook open their own prefilled
/// add-event pages (their apps when installed). An event saved through the sheet is remembered,
/// so the control reads "In Calendar" afterwards.
@MainActor
enum EventCalendar {
    enum Service: String, CaseIterable, Identifiable {
        case apple, google, outlook
        var id: String { rawValue }

        var title: String {
            switch self {
            case .apple: "Apple Calendar"
            case .google: "Google Calendar"
            case .outlook: "Outlook"
            }
        }
    }

    private static let defaultsKey = "events.calendar.added"

    private static var added: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Whether this event was saved through the sheet. With full access it's checked against the
    /// calendar, so an event deleted there can be added again.
    static func isAdded(beaconID: String) -> Bool {
        guard let identifier = added[beaconID] else { return false }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return true }
        if EKEventStore().event(withIdentifier: identifier) != nil { return true }
        added[beaconID] = nil
        return false
    }

    static func remember(beaconID: String, identifier: String?) {
        guard let identifier else { return }
        added[beaconID] = identifier
    }

    /// The prefilled event for the system sheet (which saves it to whichever calendar is picked).
    static func draft(_ beacon: MapBeacon, url: URL) -> (event: EKEvent, store: EKEventStore)? {
        guard let schedule = beacon.schedule else { return nil }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = beacon.title
        event.startDate = schedule.start
        event.endDate = schedule.end
        event.location = place(beacon)
        let location = EKStructuredLocation(title: beacon.locationName ?? beacon.formattedAddress ?? beacon.title)
        location.geoLocation = CLLocation(latitude: beacon.latitude, longitude: beacon.longitude)
        event.structuredLocation = location
        event.url = url
        event.notes = notes(beacon, url: url)
        return (event, store)
    }

    /// Google Calendar's prefilled "add event" page (UTC times, `yyyyMMddTHHmmssZ`).
    static func googleURL(_ beacon: MapBeacon, url: URL) -> URL? {
        guard let schedule = beacon.schedule else { return nil }
        var components = URLComponents(string: "https://calendar.google.com/calendar/render")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: beacon.title),
            URLQueryItem(name: "dates", value: "\(compactUTC.string(from: schedule.start))/\(compactUTC.string(from: schedule.end))"),
            URLQueryItem(name: "location", value: place(beacon)),
            URLQueryItem(name: "details", value: notes(beacon, url: url)),
        ]
        return components?.url
    }

    /// Outlook's prefilled "new event" page (Outlook.com; work accounts sign in the same way).
    static func outlookURL(_ beacon: MapBeacon, url: URL) -> URL? {
        guard let schedule = beacon.schedule else { return nil }
        let iso = ISO8601DateFormatter()
        var components = URLComponents(string: "https://outlook.live.com/calendar/0/action/compose")
        components?.queryItems = [
            URLQueryItem(name: "rru", value: "addevent"),
            URLQueryItem(name: "subject", value: beacon.title),
            URLQueryItem(name: "startdt", value: iso.string(from: schedule.start)),
            URLQueryItem(name: "enddt", value: iso.string(from: schedule.end)),
            URLQueryItem(name: "location", value: place(beacon)),
            URLQueryItem(name: "body", value: notes(beacon, url: url)),
        ]
        return components?.url
    }

    private static func place(_ beacon: MapBeacon) -> String? {
        [beacon.locationName, beacon.formattedAddress].compactMap { $0 }.joined(separator: ", ").nonEmptyTrimmed
    }

    private static func notes(_ beacon: MapBeacon, url: URL) -> String {
        [beacon.description, url.absoluteString].compactMap { $0?.nonEmptyTrimmed }.joined(separator: "\n\n")
    }

    private static let compactUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// The Add to Calendar control's state, shared by the event page and the Click Pass.
@Observable
@MainActor
final class CalendarButtonModel {
    struct Editor: Identifiable {
        let id = UUID()
        /// The event that opened the sheet (another may come on screen while it's up).
        let beaconID: String
        let event: EKEvent
        let store: EKEventStore
    }

    private(set) var isAdded = false
    var editor: Editor?

    func refresh(beaconID: String) {
        isAdded = EventCalendar.isAdded(beaconID: beaconID)
    }

    func add(_ beacon: MapBeacon, to service: EventCalendar.Service) {
        let url = URL(string: "https://joinclick.co/e/\(beacon.id)")!
        switch service {
        case .apple:
            guard let draft = EventCalendar.draft(beacon, url: url) else { return }
            editor = Editor(beaconID: beacon.id, event: draft.event, store: draft.store)
        case .google:
            if let link = EventCalendar.googleURL(beacon, url: url) { UIApplication.shared.open(link) }
        case .outlook:
            if let link = EventCalendar.outlookURL(beacon, url: url) { UIApplication.shared.open(link) }
        }
    }

    /// The system sheet closed; a save there counts as added.
    func editorFinished(saved: Bool, editor finished: Editor) {
        editor = nil
        guard saved else { return }
        EventCalendar.remember(beaconID: finished.beaconID, identifier: finished.event.eventIdentifier)
        ClickHaptics.success()
        isAdded = true
    }
}

/// "Add to Calendar" as a menu of where to add it, wearing whatever label the screen uses.
struct CalendarMenu<Content: View>: View {
    let beacon: MapBeacon
    let model: CalendarButtonModel
    @ViewBuilder let label: () -> Content

    var body: some View {
        Menu {
            Section("Add to") {
                ForEach(EventCalendar.Service.allCases) { service in
                    Button(service.title) { model.add(beacon, to: service) }
                }
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .onAppear { model.refresh(beaconID: beacon.id) }
    }
}

extension View {
    /// Presents the system add-event sheet (with its calendar picker) for Apple Calendar.
    func calendarEditorSheet(_ model: CalendarButtonModel) -> some View {
        sheet(item: Binding(get: { model.editor }, set: { model.editor = $0 })) { editor in
            EventCalendarEditor(event: editor.event, store: editor.store) { saved in
                model.editorFinished(saved: saved, editor: editor)
            }
            .ignoresSafeArea()
        }
    }
}

/// The system add-event sheet, prefilled: the user picks the calendar and saves (no access needed).
struct EventCalendarEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action == .saved)
        }
    }
}
