import SwiftUI

/// Nearby's Place filter chips (§6.6). Shown while the Places layer is selected; active chips
/// are filled, and "Clear" appears once anything is on. No filter hides data by sample size.
struct PlaceFilterChips: View {
    @Bindable var model: MapFeatureModel
    @State private var showingAll = false

    private static let lively: Set<EnergyLabel> = [.lively, .packed]
    private static let quiet: Set<EnergyLabel> = [.chill, .steady]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("Pulse now", isOn: model.placeFilters.pulseNow) { model.placeFilters.pulseNow.toggle() }
                chip("Lively+", isOn: model.placeFilters.energies == Self.lively) {
                    model.placeFilters.energies = model.placeFilters.energies == Self.lively ? [] : Self.lively
                }
                chip("Quiet", isOn: model.placeFilters.energies == Self.quiet) {
                    model.placeFilters.energies = model.placeFilters.energies == Self.quiet ? [] : Self.quiet
                }
                chip("Events today", isOn: model.placeFilters.eventsToday) { model.placeFilters.eventsToday.toggle() }
                chip("Open now", isOn: model.placeFilters.openNow) { model.placeFilters.openNow.toggle() }
                chip("Been here", isOn: model.placeFilters.beenHere) { model.placeFilters.beenHere.toggle() }
                chip("Clicks have been", isOn: model.placeFilters.clicksBeenHere) { model.placeFilters.clicksBeenHere.toggle() }
                chip("More…", isOn: false) { showingAll = true }
                if model.placeFilters.isActive {
                    chip("Clear", isOn: false) { model.placeFilters = .none }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingAll) {
            PlaceFiltersSheet(filters: $model.placeFilters)
                .presentationDetents([.medium, .large])
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(ClickTypography.supporting.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? ClickColors.accentForeground : ClickColors.textSecondary)
                .padding(.horizontal, 14)
                .frame(minHeight: ClickMetrics.chipHeight)
                .background(isOn ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Every Place filter, including categories and minimum reports.
struct PlaceFiltersSheet: View {
    @Binding var filters: PlaceFilters
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Right now") {
                    Toggle("Pulse now", isOn: $filters.pulseNow)
                    Picker("Minimum reports", selection: $filters.minReports) {
                        Text("Any").tag(0)
                        Text("2+").tag(2)
                        Text("5+").tag(5)
                        Text("10+").tag(10)
                    }
                    Toggle("Here now", isOn: $filters.hereNow)
                    Toggle("Events today", isOn: $filters.eventsToday)
                    Toggle("Open now", isOn: $filters.openNow)
                }
                Section("Energy") {
                    ForEach(EnergyLabel.allCases, id: \.self) { label in
                        Toggle(label.title, isOn: membership(label, in: \.energies))
                    }
                }
                Section("You and your Clicks") {
                    Toggle("I've been here", isOn: $filters.beenHere)
                    Toggle("My Clicks have been here", isOn: $filters.clicksBeenHere)
                    Toggle("Has a Place Hub", isOn: $filters.hasHub)
                }
                Section("Category") {
                    ForEach(PlaceCategory.allCases, id: \.self) { category in
                        Toggle(isOn: membership(category, in: \.categories)) {
                            Label(category.label, systemImage: category.symbol)
                        }
                    }
                }
            }
            .navigationTitle("Filter Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { filters = .none }.disabled(!filters.isActive)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func membership<Element: Hashable>(_ element: Element, in keyPath: WritableKeyPath<PlaceFilters, Set<Element>>) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn { filters[keyPath: keyPath].insert(element) } else { filters[keyPath: keyPath].remove(element) }
            }
        )
    }
}
