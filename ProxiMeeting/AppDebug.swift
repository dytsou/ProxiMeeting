import Foundation

/// Shared debug flags usable across the app.
enum AppDebug {
    /// Set to `"1"` to enable all debug-only behaviors.
    static let debugModeEnvKey = "PROXIMEETING_DEV"

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment[debugModeEnvKey] == "1"
        #endif
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[ProxiMeeting][DEBUG] \(message())")
    }
}

