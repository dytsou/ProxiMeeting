import Combine
import Foundation

enum JoinOpenMode: String, CaseIterable, Hashable {
    case native
    case browser
}

extension MeetingService {
    /// Services shown in Settings (unknown / “other” links always open in the browser — not configurable).
    static let joinPreferenceServices: [MeetingService] = [
        .zoom, .googleMeet, .teams, .webex, .whereby,
    ]

    fileprivate var joinPreferenceStorageKey: String {
        switch self {
        case .zoom: return "joinOpenMode.zoom"
        case .googleMeet: return "joinOpenMode.googleMeet"
        case .teams: return "joinOpenMode.teams"
        case .webex: return "joinOpenMode.webex"
        case .whereby: return "joinOpenMode.whereby"
        case .unknown: return "joinOpenMode.unknown"
        }
    }

    var joinSettingsLabelKey: String {
        switch self {
        case .zoom: return "settings.join.zoom"
        case .googleMeet: return "settings.join.google_meet"
        case .teams: return "settings.join.teams"
        case .webex: return "settings.join.webex"
        case .whereby: return "settings.join.whereby"
        case .unknown: return "settings.join.other"
        }
    }
}

@MainActor
final class JoinPreferenceStore: ObservableObject {
    private let defaults = UserDefaults.standard

    func mode(for service: MeetingService) -> JoinOpenMode {
        if service == .unknown { return .browser }
        guard let raw = defaults.string(forKey: service.joinPreferenceStorageKey),
              let mode = JoinOpenMode(rawValue: raw) else {
            return .native
        }
        return mode
    }

    func setMode(_ mode: JoinOpenMode, for service: MeetingService) {
        guard service != .unknown else { return }
        defaults.set(mode.rawValue, forKey: service.joinPreferenceStorageKey)
        objectWillChange.send()
    }
}
