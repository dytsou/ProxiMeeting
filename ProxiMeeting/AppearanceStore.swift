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

    var popoverListHeight: Double {
        get {
            let v = defaults.double(forKey: "appearance.popoverListHeight")
            return v == 0 ? 360 : v
        }
        set {
            defaults.set(newValue, forKey: "appearance.popoverListHeight")
            objectWillChange.send()
        }
    }
}
