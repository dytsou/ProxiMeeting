import Combine
import EventKit
import AppKit

// MARK: - Models

struct Meeting: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetingURL: URL?
    let location: String?

    var formattedStartTime: String {
        startDate.formatted(date: .omitted, time: .shortened)
    }

    var formattedEndTime: String {
        endDate.formatted(date: .omitted, time: .shortened)
    }

    var isNow: Bool {
        let now = Date()
        return startDate <= now && now <= endDate
    }

    var meetingService: MeetingService {
        guard let url = meetingURL else { return .unknown }
        let str = url.absoluteString
        if str.contains("zoom.us") { return .zoom }
        if str.contains("meet.google.com") { return .googleMeet }
        if str.contains("teams.microsoft.com") { return .teams }
        if str.contains("webex.com") { return .webex }
        if str.contains("whereby.com") { return .whereby }
        return .unknown
    }
}

enum MeetingService {
    case zoom, googleMeet, teams, webex, whereby, unknown

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Meet"
        case .teams: "Teams"
        case .webex: "Webex"
        case .whereby: "Whereby"
        case .unknown: "join.button"
        }
    }
}

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    private let eventStore = EKEventStore()
    private let calendarSelection: CalendarSelectionStore

    @Published var nextMeeting: Meeting?
    @Published var upcomingMeetings: [Meeting] = []
    @Published var tomorrowMeetings: [Meeting] = []
    @Published var isAuthorized = false

    private var timer: Timer?
    private var notificationObserver: NSObjectProtocol?
    private var selectionCancellable: AnyCancellable?
    private var fetchTask: Task<Void, Never>?
    private var lastFetchAt: Date?

    init(calendarSelection: CalendarSelectionStore) {
        self.calendarSelection = calendarSelection
        checkAndFetch()
        setupChangeObserver()
        selectionCancellable = calendarSelection.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.requestFetch(debounceSeconds: 0.25)
            }
    }

    deinit {
        timer?.invalidate()
        fetchTask?.cancel()
        selectionCancellable?.cancel()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Event calendars for the Calendar Sources settings tab, sorted by title.
    func eventCalendarsForSettings() -> [EKCalendar] {
        eventStore.calendars(for: .event).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// `nil` = all calendars; non-`nil` = explicit subset (possibly empty).
    private func calendarsForPredicate() -> [EKCalendar]? {
        guard let ids = calendarSelection.calendarIdentifiersForFetch() else { return nil }
        let all = eventStore.calendars(for: .event)
        return all.filter { ids.contains($0.calendarIdentifier) }
    }

    // MARK: Authorization

    func checkAndFetch() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            isAuthorized = true
            startRefreshing()
        case .notDetermined, .restricted:
            requestAccess()
        default:
            isAuthorized = false
        }
    }

    func requestAccess() {
        if #available(macOS 14.0, *) {
            Task {
                do {
                    let granted = try await eventStore.requestFullAccessToEvents()
                    isAuthorized = granted
                    if granted { startRefreshing() }
                } catch {
                    isAuthorized = false
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    self?.isAuthorized = granted
                    if granted { self?.startRefreshing() }
                }
            }
        }
    }

    // MARK: Refresh

    private func setupChangeObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestFetch(debounceSeconds: 0.25)
            }
        }
    }

    private func startRefreshing() {
        requestFetch(debounceSeconds: 0)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestFetch(debounceSeconds: 0.1)
            }
        }
    }

    func fetchMeetings() {
        requestFetch(debounceSeconds: 0)
    }

    private func requestFetch(debounceSeconds: TimeInterval) {
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            if debounceSeconds > 0 {
                let ns = UInt64(debounceSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }

            // Coalesce accidental back-to-back triggers (timer tick + EKEventStoreChanged, etc).
            if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 0.05 {
                return
            }
            lastFetchAt = Date()
            performFetchMeetings()
        }
    }

    private func performFetchMeetings() {
        let now = Date()
        let calendar = Calendar.current

        // Today: look back up to 4 hours to catch long ongoing meetings
        let searchStart = calendar.date(byAdding: .hour, value: -4, to: now) ?? now
        guard let endOfToday = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return }

        let calendarFilter = calendarsForPredicate()
        let todayPredicate = eventStore.predicateForEvents(withStart: searchStart, end: endOfToday, calendars: calendarFilter)
        let todayEvents = eventStore.events(matching: todayPredicate)

        let meetings = todayEvents
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { makeMeeting(from: $0) }

        upcomingMeetings = meetings
        nextMeeting = meetings.first

        // Tomorrow
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let startOfTomorrow = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow),
              let endOfTomorrow = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: tomorrow) else { return }

        let tomorrowPredicate = eventStore.predicateForEvents(withStart: startOfTomorrow, end: endOfTomorrow, calendars: calendarFilter)
        let tomorrowEvents = eventStore.events(matching: tomorrowPredicate)

        tomorrowMeetings = tomorrowEvents
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { makeMeeting(from: $0) }
    }

    // MARK: Meeting Construction

    private func makeMeeting(from event: EKEvent) -> Meeting {
        Meeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? String(localized: "event.untitled"),
            startDate: event.startDate,
            endDate: event.endDate,
            meetingURL: extractMeetingURL(from: event),
            location: event.location
        )
    }

    // MARK: URL Extraction

    private static let videoPatterns = [
        "zoom.us/j/",
        "zoom.us/my/",
        "meet.google.com/",
        "teams.microsoft.com/l/meetup-join",
        "teams.microsoft.com/meet/",
        "webex.com/meet/",
        "webex.com/join/",
        "whereby.com/",
    ]

    // Shared detector to avoid per-event allocations during refresh.
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static let maxScannedTextLength = 20_000

    private func extractMeetingURL(from event: EKEvent) -> URL? {
        // 1. Check event.url directly
        if let url = event.url,
           Self.videoPatterns.contains(where: { url.absoluteString.contains($0) }) {
            return url
        }

        // 2. Search in notes and location
        let textToSearch = [event.notes, event.location]
            .compactMap { $0 }
            .joined(separator: "\n")

        guard !textToSearch.isEmpty else { return nil }
        return extractURL(from: textToSearch)
    }

    private func extractURL(from text: String) -> URL? {
        guard let detector = Self.linkDetector else {
            return nil
        }

        // Fast pre-check to avoid scanning huge text blobs when the provider strings aren't present.
        // Use a lowercased check to be robust to event formatting.
        let lower = text.lowercased()
        guard Self.videoPatterns.contains(where: { lower.contains($0) }) else {
            return nil
        }

        let trimmedText: String = {
            if lower.count <= Self.maxScannedTextLength { return text }
            return String(text.prefix(Self.maxScannedTextLength))
        }()

        let range = NSRange(trimmedText.startIndex..., in: trimmedText)
        let matches = detector.matches(in: trimmedText, options: [], range: range)
        return matches
            .compactMap { $0.url }
            .first { url in
                Self.videoPatterns.contains(where: { url.absoluteString.contains($0) })
            }
    }
}
