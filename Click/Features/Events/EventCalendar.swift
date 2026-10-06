import EventKit
import CoreLocation
import EventKitUI
import SwiftUI

/// "Add to Calendar": one tap saves the event straight to the default calendar. The first time,
/// iOS asks for add-only access (Click still can't read anything it didn't add); if that's declined,
/// the system's own add-event sheet opens instead, prefilled, which needs no access at all.
/// Added events are remembered per event, so the button reads "In Calendar" afterwards.
@MainActor
enum EventCalendar {
    enum Outcome {
        case added
        /// No access: show `EventCalendarEditor` with this prefilled event.
        case needsEditor(EKEvent, EKEventStore)
        case failed
    }

    private static let defaultsKey = "events.calendar.added"

    private static var added: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Whether this event was added from Click. With full access it's checked against the calendar,
    /// so an event deleted there can be added again.
    static func isAdded(beaconID: String) -> Bool {
        guard let identifier = added[beaconID] else { return false }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return true }
        if EKEventStore().event(withIdentifier: identifier) != nil { return true }
        added[beaconID] = nil
        return false
    }

    static func add(_ beacon: MapBeacon, url: URL) async -> Outcome {
        guard let schedule = beacon.schedule else { return .failed }
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            // A throwaway store for the prompt (as `PermissionCoordinator` does): nothing
            // non-Sendable is held across the await.
            status = (try? await EKEventStore().requestWriteOnlyAccessToEvents()) == true ? .writeOnly : .denied
        }

        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = beacon.title
        event.startDate = schedule.start
        event.endDate = schedule.end
        event.location = [beacon.locationName, beacon.formattedAddress].compactMap { $0 }.joined(separator: ", ").nonEmptyTrimmed
        let location = EKStructuredLocation(title: beacon.locationName ?? beacon.formattedAddress ?? beacon.title)
        location.geoLocation = CLLocation(latitude: beacon.latitude, longitude: beacon.longitude)
        event.structuredLocation = location
        event.url = url
        event.notes = [beacon.description, url.absoluteString].compactMap { $0?.nonEmptyTrimmed }.joined(separator: "\n\n")

        guard status == .fullAccess || status == .writeOnly else { return .needsEditor(event, store) }
        do {
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            remember(beaconID: beacon.id, identifier: event.eventIdentifier)
            return .added
        } catch {
            return .needsEditor(event, store)
        }
    }

    static func remember(beaconID: String, identifier: String?) {
        guard let identifier else { return }
        added[beaconID] = identifier
    }
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
    private(set) var isAdding = false
    var editor: Editor?

    func refresh(beaconID: String) {
        isAdded = EventCalendar.isAdded(beaconID: beaconID)
    }

    func add(_ beacon: MapBeacon) async {
        guard !isAdding, !isAdded else { return }
        isAdding = true
        defer { isAdding = false }
        switch await EventCalendar.add(beacon, url: URL(string: "https://joinclick.co/e/\(beacon.id)")!) {
        case .added:
            isAdded = true
            ClickHaptics.success()
        case .needsEditor(let event, let store):
            editor = Editor(beaconID: beacon.id, event: event, store: store)
        case .failed:
            ClickHaptics.error()
        }
    }

    /// The system sheet closed; a save there counts as added too.
    func editorFinished(saved: Bool, editor finished: Editor) {
        editor = nil
        guard saved else { return }
        EventCalendar.remember(beaconID: finished.beaconID, identifier: finished.event.eventIdentifier)
        isAdded = true
    }
}

extension View {
    /// Presents the system add-event sheet when a one-tap add needs it.
    func calendarEditorSheet(_ model: CalendarButtonModel) -> some View {
        sheet(item: Binding(get: { model.editor }, set: { model.editor = $0 })) { editor in
            EventCalendarEditor(event: editor.event, store: editor.store) { saved in
                model.editorFinished(saved: saved, editor: editor)
            }
            .ignoresSafeArea()
        }
    }
}

/// The system add-event sheet, prefilled (used when Click has no calendar access).
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
