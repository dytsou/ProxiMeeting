import Combine
import Foundation

/// State for the “select all calendars” tri-state checkbox (all on, all off, or mixed).
enum CalendarBulkSelectionKind: Hashable {
    case allOn
    case allOff
    case mixed
}

@MainActor
final class CalendarSelectionStore: ObservableObject {
    private let defaults = UserDefaults.standard

    private static let includedIdsKey = "calendar.includedIds"

    /// `nil` if the user has never configured a subset (treat as “all calendars”). Non-`nil` is an explicit choice; an empty set means “none”.
    private var persistedSelection: Set<String>? {
        guard defaults.object(forKey: Self.includedIdsKey) != nil else { return nil }
        let arr = defaults.array(forKey: Self.includedIdsKey) as? [String] ?? []
        return Set(arr)
    }

    func isCalendarIncluded(_ calendarIdentifier: String, allCalendarIdentifiers: Set<String>) -> Bool {
        guard let set = persistedSelection else { return true }
        return set.contains(calendarIdentifier)
    }

    func setCalendarIncluded(_ calendarIdentifier: String, included: Bool, allCalendarIdentifiers: Set<String>) {
        var set = persistedSelection ?? allCalendarIdentifiers
        if included {
            set.insert(calendarIdentifier)
        } else {
            set.remove(calendarIdentifier)
        }
        defaults.set(Array(set), forKey: Self.includedIdsKey)
        objectWillChange.send()
    }

    func selectAllCalendarIdentifiers(_ identifiers: Set<String>) {
        defaults.set(Array(identifiers), forKey: Self.includedIdsKey)
        objectWillChange.send()
    }

    func deselectAllCalendars() {
        defaults.set([], forKey: Self.includedIdsKey)
        objectWillChange.send()
    }

    /// Returns `nil` when EventKit should query all event calendars; otherwise the calendars to pass to `predicateForEvents`.
    func calendarIdentifiersForFetch() -> Set<String>? {
        persistedSelection
    }

    /// Maps persisted selection + current EventKit calendars to a tri-state checkbox value.
    func bulkSelectionKind(allCalendarIdentifiers: Set<String>) -> CalendarBulkSelectionKind {
        guard !allCalendarIdentifiers.isEmpty else { return .allOff }
        guard let persisted = persistedSelection else { return .allOn }
        let active = persisted.intersection(allCalendarIdentifiers)
        if active.isEmpty { return .allOff }
        if active == allCalendarIdentifiers { return .allOn }
        return .mixed
    }

    /// Header checkbox: checked → clear all; off or mixed → select all.
    func toggleBulkCalendarCheckbox(allCalendarIdentifiers: Set<String>) {
        switch bulkSelectionKind(allCalendarIdentifiers: allCalendarIdentifiers) {
        case .allOn:
            deselectAllCalendars()
        case .allOff, .mixed:
            selectAllCalendarIdentifiers(allCalendarIdentifiers)
        }
    }
}
