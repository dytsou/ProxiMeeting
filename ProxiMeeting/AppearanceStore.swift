import Combine
import Foundation

/// How already-ended meetings appear on today's browse list.
enum PastEventsDisplay: String, CaseIterable, Hashable {
    /// Omit ended meetings (menu-bar / tray behavior always uses this).
    case hide
    /// Keep ended meetings that started today, drawn faded.
    case fade
}

@MainActor
final class AppearanceStore: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Today's ended meetings in the popover list: hide (default) or fade.
    var pastEventsDisplay: PastEventsDisplay {
        get {
            guard let raw = defaults.string(forKey: "appearance.pastEventsDisplay"),
                  let mode = PastEventsDisplay(rawValue: raw) else {
                return .hide
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: "appearance.pastEventsDisplay")
            objectWillChange.send()
        }
    }

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

    /// Meeting-list viewport height inside the menu popover (corner-resizable).
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

    /// Menu popover width (corner-resizable with list height).
    static let popoverWidthDefault: Double = 340
    static let popoverWidthMin: Double = 340
    static let popoverWidthMax: Double = 560

    var popoverWidth: Double {
        get {
            let v = defaults.double(forKey: "appearance.popoverWidth")
            let raw = v == 0 ? Self.popoverWidthDefault : v
            return min(max(raw, Self.popoverWidthMin), Self.popoverWidthMax)
        }
        set {
            let clamped = min(max(newValue, Self.popoverWidthMin), Self.popoverWidthMax)
            defaults.set(clamped, forKey: "appearance.popoverWidth")
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
