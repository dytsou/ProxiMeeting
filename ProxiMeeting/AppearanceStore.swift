import Combine
import Foundation

@MainActor
final class AppearanceStore: ObservableObject {
    private let defaults = UserDefaults.standard

    var fontSize: Double {
        get {
            let v = defaults.double(forKey: "appearance.fontSize")
            return v == 0 ? 13 : v
        }
        set {
            defaults.set(newValue, forKey: "appearance.fontSize")
            objectWillChange.send()
        }
    }

    var menuBarTitleFontSize: Double {
        get {
            let v = defaults.double(forKey: "appearance.menuBarTitleFontSize")
            return v == 0 ? 12 : v
        }
        set {
            defaults.set(newValue, forKey: "appearance.menuBarTitleFontSize")
            objectWillChange.send()
        }
    }

    var menuBarTimeFontSize: Double {
        get {
            let v = defaults.double(forKey: "appearance.menuBarTimeFontSize")
            return v == 0 ? 6 : v
        }
        set {
            defaults.set(newValue, forKey: "appearance.menuBarTimeFontSize")
            objectWillChange.send()
        }
    }

    var menuBarTitleLength: Int {
        get {
            let v = defaults.integer(forKey: "appearance.menuBarTitleLength")
            return v == 0 ? 10 : v
        }
        set {
            defaults.set(newValue, forKey: "appearance.menuBarTitleLength")
            objectWillChange.send()
        }
    }

    /// Meeting-list viewport height inside the menu popover (drag-resizable).
    static let popoverListHeightDefault: Double = 90
    static let popoverListHeightMin: Double = 90
    static let popoverListHeightMax: Double = 360

    var popoverListHeight: Double {
        get {
            let v = defaults.double(forKey: "appearance.popoverListHeight")
            let raw = v == 0 ? Self.popoverListHeightDefault : v
            return min(max(raw, Self.popoverListHeightMin), Self.popoverListHeightMax)
        }
        set {
            let clamped = min(max(newValue, Self.popoverListHeightMin), Self.popoverListHeightMax)
            defaults.set(clamped, forKey: "appearance.popoverListHeight")
            objectWillChange.send()
        }
    }

    /// Far-jump calendar scale (1 = intrinsic NSDatePicker size).
    static let datePickerScaleDefault: Double = 1
    static let datePickerScaleMin: Double = 1
    static let datePickerScaleMax: Double = 2.0

    var datePickerScale: Double {
        get {
            let v = defaults.double(forKey: "appearance.datePickerScale")
            let raw = v == 0 ? Self.datePickerScaleDefault : v
            return min(max(raw, Self.datePickerScaleMin), Self.datePickerScaleMax)
        }
        set {
            let clamped = min(max(newValue, Self.datePickerScaleMin), Self.datePickerScaleMax)
            defaults.set(clamped, forKey: "appearance.datePickerScale")
            objectWillChange.send()
        }
    }
}
