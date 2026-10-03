import SwiftUI
import UIKit

/// Birthday row for Profile Basics, made to sit in a `GroupedSection`. Starts empty (no silent
/// default birthday) and opens an inline wheel, which reaches a birth year far faster than the
/// compact calendar.
struct BirthdayField: View {
    @Binding var birthday: Date?
    @State private var isExpanded = false

    static let minimumAge = 13
    private static let wheelStart = Calendar.current.date(byAdding: .year, value: -18, to: .now) ?? .now

    static func isOldEnough(_ birthday: Date?) -> Bool {
        guard let birthday else { return false }
        return (Calendar.current.dateComponents([.year], from: birthday, to: .now).year ?? 0) >= minimumAge
    }

    /// Set but too young: the form says why it can't continue.
    static func isTooYoung(_ birthday: Date?) -> Bool {
        birthday != nil && !isOldEnough(birthday)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack {
                    Text("Birthday")
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer()
                    Text(birthday?.formatted(date: .long, time: .omitted) ?? "Add")
                        .foregroundStyle(valueColor)
                }
                .font(ClickTypography.body)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(birthday?.formatted(date: .long, time: .omitted) ?? "Not set")

            if isExpanded {
                DatePicker(
                    "Birthday",
                    selection: Binding(get: { birthday ?? Self.wheelStart }, set: { birthday = $0 }),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
    }

    private var valueColor: Color {
        if birthday == nil || isExpanded { return ClickColors.accentForeground }
        return ClickColors.textSecondary
    }

    private func toggle() {
        // The wheel replaces the keyboard; never show both.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(ClickMotion.subtleFade) {
            if birthday == nil { birthday = Self.wheelStart }
            isExpanded.toggle()
        }
    }
}
