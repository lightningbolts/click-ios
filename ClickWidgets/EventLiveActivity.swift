import ActivityKit
import SwiftUI
import WidgetKit

/// The event Live Activity: a countdown to an event you're going to, then "on now" with how much
/// is left, wearing the event's own colors. Tapping opens the event; "Pass" opens your Click Pass.
struct EventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.eventURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EventBadge(attributes: context.attributes, checkedIn: context.state.checkedIn, size: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PassLink(url: context.attributes.passURL)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let place = context.attributes.place {
                            Text(place)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Status(state: context.state, isStale: context.isStale, tint: Palette(context.attributes.gradient).accent)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                EventBadge(attributes: context.attributes, checkedIn: context.state.checkedIn, size: 22)
            } compactTrailing: {
                CompactTime(state: context.state, isStale: context.isStale)
                    .foregroundStyle(Palette(context.attributes.gradient).accent)
            } minimal: {
                EventBadge(attributes: context.attributes, checkedIn: context.state.checkedIn, size: 22)
            }
            .widgetURL(context.attributes.eventURL)
            .keylineTint(Palette(context.attributes.gradient).accent)
        }
    }
}

/// Before the start, until it's on (the content goes stale at the start, and a render after the
/// start reads the clock).
private func isOn(_ state: EventActivityAttributes.ContentState, isStale: Bool, now: Date) -> Bool {
    isStale || state.start <= now
}

/// Past the end (the content goes stale at the end once it's on, so this renders without the app).
private func isOver(_ state: EventActivityAttributes.ContentState, now: Date) -> Bool {
    now >= state.end
}

/// Now until the start, never inverted (a countdown range must not start after it ends).
private func untilStart(_ state: EventActivityAttributes.ContentState, now: Date) -> ClosedRange<Date> {
    now...max(now, state.start)
}

private struct LockScreenView: View {
    let context: ActivityViewContext<EventActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            EventBadge(attributes: context.attributes, checkedIn: context.state.checkedIn, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                if let place = context.attributes.place {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Status(state: context.state, isStale: context.isStale, tint: Palette(context.attributes.gradient).accent)
            }
            Spacer(minLength: 0)
            PassLink(url: context.attributes.passURL)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// "Starts in 12:04" → "On now · until 10 PM" with a progress bar ("You're in" once checked in)
/// → "Ended".
private struct Status: View {
    let state: EventActivityAttributes.ContentState
    let isStale: Bool
    let tint: Color

    var body: some View {
        let now = Date()
        if isOver(state, now: now) {
            Text(state.checkedIn ? "Ended · thanks for coming" : "Ended")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isOn(state, isStale: isStale, now: now) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(state.checkedIn ? "You're in" : "On now")
                        .fontWeight(.semibold)
                    Text("· until \(state.end, style: .time)")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                ProgressView(timerInterval: state.start...state.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(tint)
            }
        } else {
            HStack(spacing: 4) {
                Text("Starts in")
                    .foregroundStyle(.secondary)
                Text(timerInterval: untilStart(state, now: now), countsDown: true)
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
        }
    }
}

private struct CompactTime: View {
    let state: EventActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let now = Date()
        if isOver(state, now: now) {
            Image(systemName: "flag.checkered")
                .font(.caption.weight(.bold))
        } else if isOn(state, isStale: isStale, now: now) {
            Image(systemName: state.checkedIn ? "checkmark" : "dot.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
        } else {
            Text(timerInterval: untilStart(state, now: now), countsDown: true)
                .monospacedDigit()
                .font(.caption.weight(.semibold))
                .frame(maxWidth: 52)
        }
    }
}

/// The event's colors in a rounded square, with its state on top.
private struct EventBadge: View {
    let attributes: EventActivityAttributes
    let checkedIn: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: Palette(attributes.gradient).colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: checkedIn ? "checkmark" : "calendar")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct PassLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 3) {
                Image(systemName: "qrcode")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pass")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Show Click Pass")
    }
}

/// The event's generated gradient (hex stops from the app's `CardVisual`).
private struct Palette {
    let colors: [Color]

    init(_ hexes: [String]) {
        let parsed = hexes.compactMap(Self.color)
        colors = parsed.isEmpty ? [Color(red: 0.49, green: 0.23, blue: 0.93)] : parsed
    }

    /// The lightest stop reads best as an accent on the dark activity background.
    var accent: Color { colors.last ?? .purple }

    private static func color(_ hex: String) -> Color? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
