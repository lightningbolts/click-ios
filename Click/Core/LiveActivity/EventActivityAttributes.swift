import ActivityKit
import Foundation

/// The event Live Activity's data, shared by the app (which starts and updates it) and the
/// ClickWidgets extension (which draws it). Keep it small: it travels through ActivityKit.
struct EventActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var start: Date
        var end: Date
        /// Checked in at the door (by the host's scan or on-site check-in).
        var checkedIn: Bool
    }

    let beaconID: String
    let title: String
    let place: String?
    /// The event's generated colors (hex, `CardVisual`), so the activity wears them.
    let gradient: [String]
    /// You host it: the activity offers the door scanner rather than a pass. Optional, so an
    /// activity started by an earlier build still decodes.
    var isHost: Bool? = nil

    var eventURL: URL { URL(string: "click://e/\(beaconID)")! }
    var passURL: URL { URL(string: "click://pass/\(beaconID)")! }
    var scannerURL: URL { URL(string: "click://pass/\(beaconID)/scan")! }
}
