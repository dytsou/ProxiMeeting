import XCTest
@testable import ProxiMeetingCore

final class MeetingDayWindowTests: XCTestCase {
    private var calendar: Calendar!
    private var fixedNow: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = cal
        // 2026-10-11 15:00 UTC
        fixedNow = date(2026, 10, 11, 15, 0)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        comps.minute = min
        return calendar.date(from: comps)!
    }

    // MARK: - Default / recenter window

    func testDefaultWindowSpansYesterdayThroughTodayPlus14() {
        let bounds = MeetingDayWindow.defaultBounds(around: fixedNow, calendar: calendar)
        XCTAssertEqual(bounds.startDay, date(2026, 10, 10))
        XCTAssertEqual(bounds.endDay, date(2026, 10, 25))
        XCTAssertEqual(MeetingDayWindow.spanDayCount(bounds: bounds, calendar: calendar), 16)
    }

    func testFarJumpRecenterYieldsSelectedMinus1ThroughPlus14() {
        let selected = date(2026, 11, 1)
        let bounds = MeetingDayWindow.recenteredBounds(around: selected, calendar: calendar)
        XCTAssertEqual(bounds.startDay, date(2026, 10, 31))
        XCTAssertEqual(bounds.endDay, date(2026, 11, 15))
    }

    func testBrowseNearFutureEdgeExtendsBy7() {
        let current = MeetingDayWindow.defaultBounds(around: fixedNow, calendar: calendar)
        // today+14 = Oct 25; within 2 days → Oct 24
        let nearEdge = date(2026, 10, 24)
        let next = MeetingDayWindow.boundsAfterSelecting(
            browseDay: nearEdge,
            current: current,
            calendar: calendar
        )
        XCTAssertEqual(next.startDay, current.startDay)
        XCTAssertEqual(next.endDay, date(2026, 11, 1)) // Oct 25 + 7
    }

    func testBrowseNearPastEdgeExtendsBy7() {
        let current = MeetingDayWindow.defaultBounds(around: fixedNow, calendar: calendar)
        let nearEdge = date(2026, 10, 10) // window start
        let next = MeetingDayWindow.boundsAfterSelecting(
            browseDay: nearEdge,
            current: current,
            calendar: calendar
        )
        XCTAssertEqual(next.startDay, date(2026, 10, 3)) // Oct 10 - 7
        XCTAssertEqual(next.endDay, current.endDay)
    }

    func testOffWindowSelectionRecenters() {
        let current = MeetingDayWindow.defaultBounds(around: fixedNow, calendar: calendar)
        let far = date(2026, 11, 20)
        let next = MeetingDayWindow.boundsAfterSelecting(
            browseDay: far,
            current: current,
            calendar: calendar
        )
        XCTAssertEqual(next, MeetingDayWindow.recenteredBounds(around: far, calendar: calendar))
    }

    func testFetchRangeAlwaysCoversTodayWhenBrowseWindowExcludesToday() {
        // Far-jump window around Nov 20 — calendar today is Oct 11.
        let farBounds = MeetingDayWindow.recenteredBounds(around: date(2026, 11, 20), calendar: calendar)
        XCTAssertFalse(
            MeetingDayWindow.contains(fixedNow, bounds: farBounds, calendar: calendar),
            "precondition: today outside browse window"
        )
        let range = MeetingDayWindow.fetchRange(bounds: farBounds, now: fixedNow, calendar: calendar)
        let lookback = calendar.date(
            byAdding: .hour,
            value: -MeetingDayWindow.todayLookbackHours,
            to: fixedNow
        )!
        let todayEnd = MeetingDayWindow.endOfDay(fixedNow, calendar: calendar)
        // Tray remaining/ongoing slice must stay in the EventKit predicate.
        XCTAssertLessThanOrEqual(range.start, lookback)
        XCTAssertGreaterThanOrEqual(range.end, todayEnd)
        // Browse window end still covered
        XCTAssertGreaterThanOrEqual(range.end, MeetingDayWindow.endOfDay(farBounds.endDay, calendar: calendar))
    }

    func testSpanClampWhenBothEdgesWouldExceed28() {
        // Artificial wide window that selecting near both edges would blow past 28.
        let start = date(2026, 10, 1)
        let end = date(2026, 10, 28) // 28 days
        let current = MeetingDayWindow.Bounds(startDay: start, endDay: end)
        let selected = date(2026, 10, 2) // near past edge → extend past by 7 → span 35
        let next = MeetingDayWindow.boundsAfterSelecting(
            browseDay: selected,
            current: current,
            calendar: calendar
        )
        XCTAssertLessThanOrEqual(
            MeetingDayWindow.spanDayCount(bounds: next, calendar: calendar),
            MeetingDayWindow.maxSpanDays
        )
        XCTAssertTrue(MeetingDayWindow.contains(selected, bounds: next, calendar: calendar))
    }

    // MARK: - Density

    func testDensityDotMapping() {
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 0), 0)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 1), 1)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 2), 2)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 3), 3)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 4), 3)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: 10), 3)
    }

    func testActiveDensityCountExcludesFinishedAndPastDays() {
        let today = date(2026, 10, 11)
        let yesterday = date(2026, 10, 10)
        let tomorrow = date(2026, 10, 12)
        let ended = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 9, 0),
            endDate: date(2026, 10, 11, 10, 0),
            isAllDay: false
        )
        let remaining = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 16, 0),
            endDate: date(2026, 10, 11, 17, 0),
            isAllDay: false
        )
        let ongoing = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 14, 0),
            endDate: date(2026, 10, 11, 18, 0),
            isAllDay: false
        )
        let yesterdayFinished = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 10, 9, 0),
            endDate: date(2026, 10, 10, 10, 0),
            isAllDay: false
        )
        let tomorrowTimed = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 12, 9, 0),
            endDate: date(2026, 10, 12, 10, 0),
            isAllDay: false
        )
        let events = [ended, remaining, ongoing, yesterdayFinished, tomorrowTimed]

        XCTAssertEqual(
            MeetingDayWindow.activeDensityMeetingCount(
                in: events,
                forDay: today,
                now: fixedNow,
                calendar: calendar
            ),
            2,
            "today: only ongoing + remaining"
        )
        XCTAssertEqual(
            MeetingDayWindow.densityDotCount(
                meetingCount: MeetingDayWindow.activeDensityMeetingCount(
                    in: events,
                    forDay: today,
                    now: fixedNow,
                    calendar: calendar
                )
            ),
            2
        )
        XCTAssertEqual(
            MeetingDayWindow.activeDensityMeetingCount(
                in: events,
                forDay: yesterday,
                now: fixedNow,
                calendar: calendar
            ),
            0,
            "past days do not light density dots"
        )
        XCTAssertEqual(
            MeetingDayWindow.activeDensityMeetingCount(
                in: events,
                forDay: tomorrow,
                now: fixedNow,
                calendar: calendar
            ),
            1
        )
    }

    func testActiveDensityCountCapsAtThreeDots() {
        let day = date(2026, 10, 12)
        let events = (0..<5).map { i in
            MeetingDayWindow.TimedEvent(
                startDate: date(2026, 10, 12, 9 + i, 0),
                endDate: date(2026, 10, 12, 10 + i, 0),
                isAllDay: false
            )
        }
        let count = MeetingDayWindow.activeDensityMeetingCount(
            in: events,
            forDay: day,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(count, 5)
        XCTAssertEqual(MeetingDayWindow.densityDotCount(meetingCount: count), 3)
    }

    // MARK: - Filters

    func testTodayFilterKeepsOngoingAndExcludesEnded() {
        let today = date(2026, 10, 11)
        let ongoing = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 12, 0),
            endDate: date(2026, 10, 11, 18, 0),
            isAllDay: false
        )
        let ended = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 9, 0),
            endDate: date(2026, 10, 11, 10, 0),
            isAllDay: false
        )
        let startedEarlierStillGoing = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 13, 0),
            endDate: date(2026, 10, 11, 16, 0),
            isAllDay: false
        )
        let filtered = MeetingDayWindow.filterEvents(
            [ongoing, ended, startedEarlierStillGoing],
            forBrowseDay: today,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains(ongoing))
        XCTAssertTrue(filtered.contains(startedEarlierStillGoing))
        XCTAssertFalse(filtered.contains(ended))
    }

    func testTodayFilterIncludeEndedKeepsTodaysPastAndSkipsYesterdaysEnded() {
        let today = date(2026, 10, 11)
        let endedToday = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 9, 0),
            endDate: date(2026, 10, 11, 10, 0),
            isAllDay: false
        )
        let endedYesterday = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 10, 20, 0),
            endDate: date(2026, 10, 11, 8, 0),
            isAllDay: false
        )
        let ongoing = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 11, 12, 0),
            endDate: date(2026, 10, 11, 18, 0),
            isAllDay: false
        )
        let filtered = MeetingDayWindow.filterEvents(
            [endedToday, endedYesterday, ongoing],
            forBrowseDay: today,
            now: fixedNow,
            includeEnded: true,
            calendar: calendar
        )
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains(endedToday))
        XCTAssertTrue(filtered.contains(ongoing))
        XCTAssertFalse(filtered.contains(endedYesterday))
    }

    func testOtherDayFilterIncludesMorningWhenNowIsAfternoon() {
        let other = date(2026, 10, 12)
        let morning = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 12, 9, 0),
            endDate: date(2026, 10, 12, 10, 0),
            isAllDay: false
        )
        let filtered = MeetingDayWindow.filterEvents(
            [morning],
            forBrowseDay: other,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(filtered, [morning])
    }

    func testAllDayNeverInDensityOrDayLists() {
        let day = date(2026, 10, 12)
        let allDay = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 12, 0, 0),
            endDate: date(2026, 10, 13, 0, 0),
            isAllDay: true
        )
        let timed = MeetingDayWindow.TimedEvent(
            startDate: date(2026, 10, 12, 11, 0),
            endDate: date(2026, 10, 12, 12, 0),
            isAllDay: false
        )
        let filtered = MeetingDayWindow.filterEvents(
            [allDay, timed],
            forBrowseDay: day,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(filtered, [timed])
        XCTAssertEqual(
            MeetingDayWindow.meetingCount(in: [allDay, timed], forDay: day, calendar: calendar),
            1
        )
        XCTAssertEqual(
            MeetingDayWindow.densityDotCount(
                meetingCount: MeetingDayWindow.meetingCount(
                    in: [allDay],
                    forDay: day,
                    calendar: calendar
                )
            ),
            0
        )
    }

    func testBusyDayCountGreaterThanQuietDay() {
        let quiet = date(2026, 10, 13)
        let busy = date(2026, 10, 14)
        let events = [
            MeetingDayWindow.TimedEvent(
                startDate: date(2026, 10, 14, 9, 0),
                endDate: date(2026, 10, 14, 10, 0),
                isAllDay: false
            ),
            MeetingDayWindow.TimedEvent(
                startDate: date(2026, 10, 14, 11, 0),
                endDate: date(2026, 10, 14, 12, 0),
                isAllDay: false
            ),
            MeetingDayWindow.TimedEvent(
                startDate: date(2026, 10, 14, 14, 0),
                endDate: date(2026, 10, 14, 15, 0),
                isAllDay: false
            ),
        ]
        let quietCount = MeetingDayWindow.meetingCount(in: events, forDay: quiet, calendar: calendar)
        let busyCount = MeetingDayWindow.meetingCount(in: events, forDay: busy, calendar: calendar)
        XCTAssertEqual(quietCount, 0)
        XCTAssertEqual(busyCount, 3)
        XCTAssertGreaterThan(busyCount, quietCount)
        // Chip enumeration includes empty day
        let bounds = MeetingDayWindow.Bounds(startDay: quiet, endDay: busy)
        let days = MeetingDayWindow.daysInWindow(bounds: bounds, calendar: calendar)
        XCTAssertEqual(days, [quiet, busy])
    }

    func testStepDayAndAccessibilityValue() {
        let day = date(2026, 10, 11)
        XCTAssertEqual(
            MeetingDayWindow.stepDay(day, by: 1, calendar: calendar),
            date(2026, 10, 12)
        )
        XCTAssertEqual(
            MeetingDayWindow.stepDay(day, by: -1, calendar: calendar),
            date(2026, 10, 10)
        )
        let value = MeetingDayWindow.accessibilityDayValue(
            day: day,
            meetingCount: 2,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        XCTAssertTrue(value.contains("2026") || value.contains("October") || value.contains("10"))
        XCTAssertTrue(value.contains("2 meetings"))
    }

    func testEmptyStateHelperDistinguishesToday() {
        let today = MeetingDayWindow.startOfDay(fixedNow, calendar: calendar)
        let future = MeetingDayWindow.stepDay(today, by: 5, calendar: calendar)
        XCTAssertTrue(MeetingDayWindow.isSameCalendarDay(today, fixedNow, calendar: calendar))
        XCTAssertFalse(MeetingDayWindow.isSameCalendarDay(future, fixedNow, calendar: calendar))
    }
}
