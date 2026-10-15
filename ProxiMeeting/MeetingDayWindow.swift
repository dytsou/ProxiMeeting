import Foundation

/// Pure calendar-day window math, density mapping, and meeting list filters.
/// Foundation-only so it can live in `ProxiMeetingCore` and be unit-tested without EventKit.
public enum MeetingDayWindow {
    public static let pastOffsetDays = 1
    public static let futureOffsetDays = 14
    public static let edgeProximityDays = 2
    public static let edgeExtendDays = 7
    public static let maxSpanDays = 28
    public static let todayLookbackHours = 4

    public struct Bounds: Equatable, Sendable {
        /// Inclusive start-of-day for the first day in the window.
        public var startDay: Date
        /// Inclusive start-of-day for the last day in the window.
        public var endDay: Date

        public init(startDay: Date, endDay: Date) {
            self.startDay = startDay
            self.endDay = endDay
        }
    }

    /// Minimal event shape for filtering / density without EventKit.
    public struct TimedEvent: Equatable, Sendable {
        public var startDate: Date
        public var endDate: Date
        public var isAllDay: Bool

        public init(startDate: Date, endDate: Date, isAllDay: Bool) {
            self.startDate = startDate
            self.endDate = endDate
            self.isAllDay = isAllDay
        }
    }

    // MARK: - Day keys

    public static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = startOfDay(date, calendar: calendar)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            return start
        }
        return next.addingTimeInterval(-1)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> Date {
        startOfDay(date, calendar: calendar)
    }

    public static func daysInWindow(bounds: Bounds, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var cursor = startOfDay(bounds.startDay, calendar: calendar)
        let end = startOfDay(bounds.endDay, calendar: calendar)
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    public static func spanDayCount(bounds: Bounds, calendar: Calendar = .current) -> Int {
        let start = startOfDay(bounds.startDay, calendar: calendar)
        let end = startOfDay(bounds.endDay, calendar: calendar)
        let comps = calendar.dateComponents([.day], from: start, to: end)
        return (comps.day ?? 0) + 1
    }

    // MARK: - Window math

    /// Default loaded span: start-of-day(today)−1 … start-of-day(today+14).
    public static func defaultBounds(around now: Date, calendar: Calendar = .current) -> Bounds {
        bounds(aroundAnchor: now, calendar: calendar)
    }

    /// Far-jump / off-window: start-of-day(selected)−1 … start-of-day(selected+14).
    public static func recenteredBounds(around selected: Date, calendar: Calendar = .current) -> Bounds {
        bounds(aroundAnchor: selected, calendar: calendar)
    }

    private static func bounds(aroundAnchor anchor: Date, calendar: Calendar) -> Bounds {
        let day = startOfDay(anchor, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -pastOffsetDays, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: futureOffsetDays, to: day) ?? day
        return Bounds(startDay: start, endDay: end)
    }

    public static func contains(_ day: Date, bounds: Bounds, calendar: Calendar = .current) -> Bool {
        let key = startOfDay(day, calendar: calendar)
        let start = startOfDay(bounds.startDay, calendar: calendar)
        let end = startOfDay(bounds.endDay, calendar: calendar)
        return key >= start && key <= end
    }

    /// Adjusts window for a browse-day selection: off-window recenters; near-edge extends by 7 days
    /// (opposite edge kept unless span would exceed 28 days, then slide).
    public static func boundsAfterSelecting(
        browseDay: Date,
        current: Bounds,
        calendar: Calendar = .current
    ) -> Bounds {
        let selected = startOfDay(browseDay, calendar: calendar)
        var start = startOfDay(current.startDay, calendar: calendar)
        var end = startOfDay(current.endDay, calendar: calendar)

        if selected < start || selected > end {
            return recenteredBounds(around: selected, calendar: calendar)
        }

        let daysFromStart = calendar.dateComponents([.day], from: start, to: selected).day ?? 0
        let daysFromEnd = calendar.dateComponents([.day], from: selected, to: end).day ?? 0

        if daysFromStart <= edgeProximityDays,
           let extended = calendar.date(byAdding: .day, value: -edgeExtendDays, to: start) {
            start = extended
        }
        if daysFromEnd <= edgeProximityDays,
           let extended = calendar.date(byAdding: .day, value: edgeExtendDays, to: end) {
            end = extended
        }

        var bounds = Bounds(startDay: start, endDay: end)
        let span = spanDayCount(bounds: bounds, calendar: calendar)
        if span > maxSpanDays {
            // Slide to keep selected visible with a future-biased ~16-day span, capped at 28.
            bounds = clampSpanKeepingSelected(selected: selected, preferred: bounds, calendar: calendar)
        }
        return bounds
    }

    private static func clampSpanKeepingSelected(
        selected: Date,
        preferred: Bounds,
        calendar: Calendar
    ) -> Bounds {
        // Prefer sliding the opposite edge so the proximity-extended edge is kept when possible.
        var start = startOfDay(preferred.startDay, calendar: calendar)
        var end = startOfDay(preferred.endDay, calendar: calendar)
        var span = spanDayCount(bounds: Bounds(startDay: start, endDay: end), calendar: calendar)

        while span > maxSpanDays {
            let distStart = calendar.dateComponents([.day], from: start, to: selected).day ?? 0
            let distEnd = calendar.dateComponents([.day], from: selected, to: end).day ?? 0
            if distStart >= distEnd {
                // Trim past edge
                guard let next = calendar.date(byAdding: .day, value: 1, to: start), next <= selected else {
                    // Fall back to recenter if we cannot trim further
                    return recenteredBounds(around: selected, calendar: calendar)
                }
                start = next
            } else {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: end), prev >= selected else {
                    return recenteredBounds(around: selected, calendar: calendar)
                }
                end = prev
            }
            span = spanDayCount(bounds: Bounds(startDay: start, endDay: end), calendar: calendar)
        }
        return Bounds(startDay: start, endDay: end)
    }

    /// EventKit predicate range covering the browse window **and** calendar today.
    ///
    /// Today is always included so tray `nextMeeting` / `upcomingMeetings` stay correct when the
    /// browse window recenters or slides away from today (far jump / max-span clamp).
    public static func fetchRange(
        bounds: Bounds,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let windowStart = startOfDay(bounds.startDay, calendar: calendar)
        let windowEnd = endOfDay(bounds.endDay, calendar: calendar)
        let todayEnd = endOfDay(now, calendar: calendar)
        let lookback = calendar.date(byAdding: .hour, value: -todayLookbackHours, to: now) ?? now
        let start = min(windowStart, lookback)
        let end = max(windowEnd, todayEnd)
        return (start, end)
    }

    // MARK: - Density

    /// 0 → 0 dots; 1–3 → that many; 4+ → 3 dots.
    public static func densityDotCount(meetingCount: Int) -> Int {
        if meetingCount <= 0 { return 0 }
        return min(meetingCount, 3)
    }

    /// Meetings that should light density dots for `day`: not finished.
    /// Past days → 0; today → remaining/ongoing; future → full-day timed count.
    public static func activeDensityMeetingCount(
        in events: [TimedEvent],
        forDay day: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let dayKey = startOfDay(day, calendar: calendar)
        let today = startOfDay(now, calendar: calendar)
        if dayKey < today { return 0 }
        return filterEvents(
            events,
            forBrowseDay: dayKey,
            now: now,
            includeEnded: false,
            calendar: calendar
        ).count
    }

    // MARK: - Filtering

    public static func isSameCalendarDay(_ a: Date, _ b: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    /// Whether a timed item belongs on today's browse list (tray / remaining-today rules).
    ///
    /// When `includeEnded` is false (default), only meetings still ending after `now` are kept.
    /// When true, also keeps meetings that already ended if they started on `browseDay`
    /// (caller typically fades those rows).
    public static func includesInTodayBrowse(
        startDate: Date,
        endDate: Date,
        now: Date,
        browseDay: Date,
        includeEnded: Bool = false,
        calendar: Calendar = .current
    ) -> Bool {
        if endDate > now {
            if calendar.isDate(startDate, inSameDayAs: browseDay) { return true }
            return startDate < now
        }
        guard includeEnded else { return false }
        return calendar.isDate(startDate, inSameDayAs: browseDay)
    }

    /// Today: non-all-day; by default still ending after `now`, started today or still ongoing.
    /// Pass `includeEnded: true` to also keep today's already-ended meetings (for fade display).
    /// Other days: non-all-day meetings whose start falls on that calendar day (full day).
    public static func filterEvents(
        _ events: [TimedEvent],
        forBrowseDay browseDay: Date,
        now: Date,
        includeEnded: Bool = false,
        calendar: Calendar = .current
    ) -> [TimedEvent] {
        let day = startOfDay(browseDay, calendar: calendar)
        let today = startOfDay(now, calendar: calendar)
        let nonAllDay = events.filter { !$0.isAllDay }

        if day == today {
            return nonAllDay
                .filter {
                    includesInTodayBrowse(
                        startDate: $0.startDate,
                        endDate: $0.endDate,
                        now: now,
                        browseDay: day,
                        includeEnded: includeEnded,
                        calendar: calendar
                    )
                }
                .sorted { $0.startDate < $1.startDate }
        }

        return nonAllDay
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Bucket non-all-day events by start-of-day of `startDate`.
    public static func bucketByStartDay(
        _ events: [TimedEvent],
        calendar: Calendar = .current
    ) -> [Date: [TimedEvent]] {
        var result: [Date: [TimedEvent]] = [:]
        for event in events where !event.isAllDay {
            let key = startOfDay(event.startDate, calendar: calendar)
            result[key, default: []].append(event)
        }
        for key in result.keys {
            result[key]?.sort { $0.startDate < $1.startDate }
        }
        return result
    }

    public static func meetingCount(
        in events: [TimedEvent],
        forDay day: Date,
        calendar: Calendar = .current
    ) -> Int {
        let key = startOfDay(day, calendar: calendar)
        return events.filter { !$0.isAllDay && calendar.isDate($0.startDate, inSameDayAs: key) }.count
    }

    public static func stepDay(_ day: Date, by offset: Int, calendar: Calendar = .current) -> Date {
        let start = startOfDay(day, calendar: calendar)
        return calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    // MARK: - Display weekdays

    /// Foundation `Calendar` weekday values (`1...7`, Sunday = 1).
    public static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    public static func isWeekdayEnabled(
        _ day: Date,
        enabledWeekdays: Set<Int>,
        calendar: Calendar = .current
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: startOfDay(day, calendar: calendar))
        return enabledWeekdays.contains(weekday)
    }

    public static func filterEnabledDays(
        _ days: [Date],
        enabledWeekdays: Set<Int>,
        calendar: Calendar = .current
    ) -> [Date] {
        days.filter { isWeekdayEnabled($0, enabledWeekdays: enabledWeekdays, calendar: calendar) }
    }

    /// Soonest day on or after `from` whose weekday is enabled.
    public static func nextEnabledDay(
        from day: Date,
        enabledWeekdays: Set<Int>,
        calendar: Calendar = .current,
        maxSearchDays: Int = 14
    ) -> Date? {
        guard !enabledWeekdays.isEmpty else { return nil }
        var cursor = startOfDay(day, calendar: calendar)
        for _ in 0..<maxSearchDays {
            if isWeekdayEnabled(cursor, enabledWeekdays: enabledWeekdays, calendar: calendar) {
                return cursor
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// Steps by ±1 among enabled weekdays, skipping disabled civil days.
    public static func stepEnabledDay(
        _ day: Date,
        by offset: Int,
        enabledWeekdays: Set<Int>,
        calendar: Calendar = .current,
        maxSearchDays: Int = 28
    ) -> Date {
        let start = startOfDay(day, calendar: calendar)
        guard offset != 0, !enabledWeekdays.isEmpty else { return start }
        let direction = offset > 0 ? 1 : -1
        var remaining = abs(offset)
        var cursor = start
        var searched = 0
        while remaining > 0, searched < maxSearchDays {
            guard let next = calendar.date(byAdding: .day, value: direction, to: cursor) else { break }
            cursor = next
            searched += 1
            if isWeekdayEnabled(cursor, enabledWeekdays: enabledWeekdays, calendar: calendar) {
                remaining -= 1
            }
        }
        return cursor
    }

    /// Day key whose remaining meetings should drive the menu-bar tray, or `nil` if none.
    /// Prefers today's remaining/ongoing list when today is enabled; otherwise looks ahead.
    public static func trayBrowseDay(
        now: Date,
        meetingsByDay: [Date: [TimedEvent]],
        enabledWeekdays: Set<Int>,
        calendar: Calendar = .current
    ) -> Date? {
        guard !enabledWeekdays.isEmpty else { return nil }
        let today = startOfDay(now, calendar: calendar)
        let allEvents = meetingsByDay.values.flatMap { $0 }

        if isWeekdayEnabled(today, enabledWeekdays: enabledWeekdays, calendar: calendar) {
            let todayList = filterEvents(
                allEvents,
                forBrowseDay: today,
                now: now,
                includeEnded: false,
                calendar: calendar
            )
            if !todayList.isEmpty { return today }
        }

        let futureKeys = meetingsByDay.keys
            .map { startOfDay($0, calendar: calendar) }
            .filter { $0 > today }
            .filter { isWeekdayEnabled($0, enabledWeekdays: enabledWeekdays, calendar: calendar) }
            .sorted()
        for key in futureKeys {
            let remaining = (meetingsByDay[key] ?? []).filter { !$0.isAllDay && $0.endDate > now }
            if !remaining.isEmpty { return key }
        }
        return nil
    }

    /// Accessibility value: formatted date plus optional meeting count.
    public static func accessibilityDayValue(
        day: Date,
        meetingCount: Int,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let datePart = formatter.string(from: startOfDay(day, calendar: calendar))
        if meetingCount == 1 {
            return "\(datePart), 1 meeting"
        }
        return "\(datePart), \(meetingCount) meetings"
    }
}
