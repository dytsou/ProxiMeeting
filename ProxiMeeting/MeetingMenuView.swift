import SwiftUI
import AppKit
import EventKit
#if canImport(ProxiMeetingCore)
import ProxiMeetingCore
#endif

extension Notification.Name {
    /// Posted before opening a meeting in the browser so the menu popover can dismiss (browser preference or native fallback).
    static let proxiMeetingDismissPopover = Notification.Name("ProxiMeetingDismissPopover")
    /// Opens the Join / Settings sheet (Raycast extension and `proximeeting://open-preferences`).
    static let proxiMeetingOpenJoinSettings = Notification.Name("ProxiMeetingOpenJoinSettings")
    /// Posted when the menu popover is about to show so browse day resets to today.
    static let proxiMeetingPopoverWillShow = Notification.Name("ProxiMeetingPopoverWillShow")
    /// Posted from the local key monitor; `object` is an `Int` day offset (−1 / +1).
    static let proxiMeetingBrowseDayStep = Notification.Name("ProxiMeetingBrowseDayStep")
}

/// Gates local arrow-key capture so DatePicker / closed popover still receive keys.
@MainActor
enum BrowseDayKeyboardGate {
    /// True only while the menu popover is shown (set from `StatusBarController`).
    static var popoverIsShown = false
    /// False while DatePicker / Join Settings are up.
    static var allowsArrowCapture = false

    static var capturesArrows: Bool { popoverIsShown && allowsArrowCapture }
}

// MARK: - Root Menu View

struct MeetingMenuView: View {
    @EnvironmentObject var manager: CalendarManager
    @EnvironmentObject var joinPreferences: JoinPreferenceStore
    @EnvironmentObject var calendarSelection: CalendarSelectionStore
    @EnvironmentObject var appearanceStore: AppearanceStore
    @State private var browseDay: Date = MeetingDayWindow.startOfDay(Date())
    /// When true, browse day should follow civil "today" across midnight; false after an explicit off-today pick.
    @State private var tracksCivilToday = true
    @State private var showJoinSettings = false
    @State private var showDatePicker = false
    @State private var keyMonitor: Any?

    private var today: Date { MeetingDayWindow.startOfDay(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(
                browseDay: browseDay,
                showJoinSettings: $showJoinSettings,
                showDatePicker: $showDatePicker,
                onSelectBrowseDay: selectBrowseDay,
                onReturnToToday: { selectBrowseDay(today) }
            )
            Divider()
            DayChipStrip(
                browseDay: browseDay,
                onSelect: selectBrowseDay
            )
            Divider()
            ContentView(browseDay: browseDay)
                .frame(height: appearanceStore.popoverListHeight)
            PopoverListResizeHandle()
            Divider()
            FooterView()
        }
        .frame(width: 340)
        .environmentObject(manager)
        .environmentObject(joinPreferences)
        .environmentObject(calendarSelection)
        .onAppear {
            resetBrowseToToday()
            installKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proxiMeetingPopoverWillShow)) { _ in
            resetBrowseToToday()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proxiMeetingOpenJoinSettings)) { _ in
            showJoinSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .proxiMeetingBrowseDayStep)) { note in
            guard BrowseDayKeyboardGate.capturesArrows else { return }
            guard let offset = note.object as? Int else { return }
            stepBrowseDay(by: offset)
        }
        // CalendarManager refreshes ~60s; reuse that signal to snap browse day when civil day rolls.
        .onReceive(manager.$nextMeeting.map { _ in () }) { _ in
            reconcileBrowseDayWithCivilToday()
        }
        .onChange(of: showJoinSettings) { _ in updateArrowCaptureGate() }
        .onChange(of: showDatePicker) { _ in updateArrowCaptureGate() }
        .onDisappear {
            BrowseDayKeyboardGate.allowsArrowCapture = false
            removeKeyMonitor()
        }
        .sheet(isPresented: $showJoinSettings) {
            JoinSettingsView()
                .environmentObject(joinPreferences)
                .environmentObject(manager)
                .environmentObject(calendarSelection)
                .environmentObject(appearanceStore)
        }
    }

    private func resetBrowseToToday() {
        showDatePicker = false
        let day = MeetingDayWindow.startOfDay(Date())
        browseDay = day
        tracksCivilToday = true
        manager.resetWindowAroundToday()
        updateArrowCaptureGate()
    }

    private func selectBrowseDay(_ day: Date) {
        let keyed = MeetingDayWindow.startOfDay(day)
        browseDay = keyed
        tracksCivilToday = MeetingDayWindow.isSameCalendarDay(keyed, Date())
        manager.ensureWindow(for: keyed)
        showDatePicker = false
        updateArrowCaptureGate()
    }

    /// If the user was browsing "today" and the civil day advanced while the popover stayed open, snap forward.
    private func reconcileBrowseDayWithCivilToday() {
        guard tracksCivilToday else { return }
        let day = MeetingDayWindow.startOfDay(Date())
        guard !MeetingDayWindow.isSameCalendarDay(browseDay, day) else { return }
        browseDay = day
        manager.resetWindowAroundToday()
    }

    private func stepBrowseDay(by offset: Int) {
        let next = MeetingDayWindow.stepDay(browseDay, by: offset)
        selectBrowseDay(next)
    }

    private func updateArrowCaptureGate() {
        BrowseDayKeyboardGate.allowsArrowCapture = !showJoinSettings && !showDatePicker
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard BrowseDayKeyboardGate.capturesArrows else { return event }
            guard event.window?.isKeyWindow == true else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !mods.intersection([.command, .option, .control, .shift]).isEmpty {
                return event
            }
            switch event.keyCode {
            case 123: // left arrow
                NotificationCenter.default.post(name: .proxiMeetingBrowseDayStep, object: -1)
                return nil
            case 124: // right arrow
                NotificationCenter.default.post(name: .proxiMeetingBrowseDayStep, object: 1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var manager: CalendarManager
    @EnvironmentObject var appearanceStore: AppearanceStore
    let browseDay: Date
    @Binding var showJoinSettings: Bool
    @Binding var showDatePicker: Bool
    var onSelectBrowseDay: (Date) -> Void
    var onReturnToToday: () -> Void

    private var isToday: Bool {
        MeetingDayWindow.isSameCalendarDay(browseDay, Date())
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isToday ? "header.title" : "header.title.other_day")
                        .font(.headline)
                    Button {
                        showDatePicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(browseDay, format: .dateTime.year().month(.wide).day().weekday(.wide))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(Text("header.pick_date"))
                    .accessibilityLabel(Text("header.pick_date"))
                    // Anchor under the date control (not the whole menu) so the picker sits in the header.
                    .popover(isPresented: $showDatePicker, arrowEdge: .top) {
                        FarJumpDatePicker(selection: browseDay, onSelect: onSelectBrowseDay)
                            .environmentObject(appearanceStore)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !isToday {
                        Button(action: onReturnToToday) {
                            Image(systemName: "house")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(Text("ribbon.back_today"))
                        .accessibilityLabel(Text("ribbon.back_today"))
                    }

                    Button {
                        manager.fetchMeetings()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("header.refresh"))
                    .accessibilityLabel(Text("header.refresh"))

                    Button {
                        showJoinSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("footer.settings"))
                    .accessibilityLabel(Text("footer.settings"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - Day chip strip

private struct DayChipStrip: View {
    @EnvironmentObject var manager: CalendarManager
    let browseDay: Date
    let onSelect: (Date) -> Void

    private var today: Date { MeetingDayWindow.startOfDay(Date()) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(manager.daysInWindow, id: \.self) { day in
                        DayChip(
                            day: day,
                            isToday: MeetingDayWindow.isSameCalendarDay(day, today),
                            isSelected: MeetingDayWindow.isSameCalendarDay(day, browseDay),
                            meetingCount: manager.meetingCount(for: day)
                        ) {
                            onSelect(day)
                        }
                        .id(day)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onAppear {
                proxy.scrollTo(MeetingDayWindow.startOfDay(browseDay), anchor: .center)
            }
            .onChange(of: browseDay) { newDay in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(MeetingDayWindow.startOfDay(newDay), anchor: .center)
                }
            }
            .onChange(of: manager.windowBounds) { _ in
                proxy.scrollTo(MeetingDayWindow.startOfDay(browseDay), anchor: .center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("strip.day_selection"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSelect(MeetingDayWindow.stepDay(browseDay, by: 1))
            case .decrement:
                onSelect(MeetingDayWindow.stepDay(browseDay, by: -1))
            @unknown default:
                break
            }
        }
    }

    private var accessibilityValue: String {
        let count = manager.meetingCount(for: browseDay)
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let datePart = formatter.string(from: MeetingDayWindow.startOfDay(browseDay))
        let formatKey = count == 1 ? "strip.a11y.value_one" : "strip.a11y.value_other"
        return String(format: NSLocalizedString(formatKey, comment: ""), datePart, count)
    }
}

private struct DayChip: View {
    let day: Date
    let isToday: Bool
    let isSelected: Bool
    let meetingCount: Int
    let action: () -> Void

    private var weekdayLabel: String {
        day.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        day.formatted(.dateTime.day())
    }

    private var dotCount: Int {
        MeetingDayWindow.densityDotCount(meetingCount: meetingCount)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(weekdayLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                Text(dayNumber)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                HStack(spacing: 2) {
                    ForEach(0..<dotCount, id: \.self) { _ in
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.95) : Color.accentColor.opacity(0.85))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 40, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isToday && !isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

// MARK: - Content

private struct ContentView: View {
    @EnvironmentObject var manager: CalendarManager
    let browseDay: Date

    var body: some View {
        if !manager.isAuthorized {
            UnauthorizedView()
        } else {
            let meetings = manager.meetings(for: browseDay)
            if meetings.isEmpty {
                NoMeetingsView(browseDay: browseDay)
            } else {
                MeetingListView(meetings: meetings)
            }
        }
    }
}

private struct UnauthorizedView: View {
    @EnvironmentObject var manager: CalendarManager

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("auth.required")
                .font(.subheadline)
            Button("auth.grant") {
                manager.requestAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct NoMeetingsView: View {
    let browseDay: Date

    private var isToday: Bool {
        MeetingDayWindow.isSameCalendarDay(browseDay, Date())
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Group {
                if isToday {
                    Text("empty.no_meetings")
                } else {
                    Text(String(format: NSLocalizedString("empty.no_meetings_on_day", comment: ""), dayLabel))
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .id(MeetingDayWindow.startOfDay(browseDay))
    }

    private var dayLabel: String {
        browseDay.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
    }
}

private struct MeetingListView: View {
    let meetings: [Meeting]
    @EnvironmentObject var appearanceStore: AppearanceStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 14)
                    }
                    MeetingRow(meeting: meeting)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Drag handle under the meeting list — updates persisted `popoverListHeight`.
private struct PopoverListResizeHandle: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @State private var dragOriginHeight: Double?

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .help(Text("menu.resize_list"))
        .accessibilityLabel(Text("menu.resize_list"))
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragOriginHeight == nil {
                        dragOriginHeight = appearanceStore.popoverListHeight
                    }
                    let next = (dragOriginHeight ?? appearanceStore.popoverListHeight) + value.translation.height
                    appearanceStore.popoverListHeight = next
                }
                .onEnded { _ in
                    dragOriginHeight = nil
                }
        )
    }
}

// MARK: - Meeting Row

struct MeetingRow: View {
    let meeting: Meeting
    @EnvironmentObject var appearanceStore: AppearanceStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Time column
            VStack(alignment: .trailing, spacing: 1) {
                Text(meeting.formattedStartTime)
                    .font(.system(size: max(8, appearanceStore.fontSize - 1), weight: .semibold, design: .monospaced))
                Text(meeting.formattedEndTime)
                    .font(.system(size: max(7, appearanceStore.fontSize - 3), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50, alignment: .trailing)

            // Status bar
            RoundedRectangle(cornerRadius: 2)
                .fill(meeting.isNow ? Color.green : Color.accentColor.opacity(0.4))
                .frame(width: 3, height: 36)

            // Title + location
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: appearanceStore.fontSize))
                    .lineLimit(2)
                if let location = meeting.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: max(8, appearanceStore.fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Join button
            if let url = meeting.meetingURL {
                JoinButton(url: url, service: meeting.meetingService)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(meeting.isNow ? Color.green.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Meeting join URL

private func openMeetingJoinURL(url: URL, mode: JoinOpenMode) {
    switch mode {
    case .browser:
        let target = url.browserFallbackJoinURL() ?? url
        NotificationCenter.default.post(name: .proxiMeetingDismissPopover, object: nil)
        _ = NSWorkspace.shared.open(target)
    case .native:
        if NSWorkspace.shared.open(url) { return }
        NotificationCenter.default.post(name: .proxiMeetingDismissPopover, object: nil)
        guard let fallback = url.browserFallbackJoinURL() else { return }
        _ = NSWorkspace.shared.open(fallback)
    }
}

private extension URL {
    /// HTTPS (or same http/s) URL to open in the default browser when the native handler is missing.
    func browserFallbackJoinURL() -> URL? {
        let scheme = (self.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" {
            return self
        }
        if scheme == "zoommtg" {
            return zoomWebURLFromZoommtg()
        }
        if scheme == "gmeet" {
            return googleMeetWebURLFromGmeet()
        }
        let lower = absoluteString.lowercased()
        if lower.contains("teams.microsoft.com") || lower.contains("meet.google.com") {
            var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url
        }
        return nil
    }

    private func zoomWebURLFromZoommtg() -> URL? {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        let confnoFromQuery = items.first { $0.name.lowercased() == "confno" }?.value
        let confnoFromPath: String? = {
            let p = comps.path
            guard let r = p.range(of: "/j/") else { return nil }
            let after = p[r.upperBound...]
            let segment = after.split(separator: "/").first.map(String.init)
            return segment.flatMap { $0.isEmpty ? nil : $0 }
        }()
        guard let confno = confnoFromQuery ?? confnoFromPath, !confno.isEmpty else { return nil }
        let pwd = items.first { $0.name.lowercased() == "pwd" }?.value
        var web = URLComponents()
        web.scheme = "https"
        web.host = "zoom.us"
        web.path = "/j/\(confno)"
        if let pwd, !pwd.isEmpty {
            web.queryItems = [URLQueryItem(name: "pwd", value: pwd)]
        }
        return web.url
    }

    /// `gmeet://meeting-code` (Google Meet iOS / app deep link) → `https://meet.google.com/meeting-code`
    private func googleMeetWebURLFromGmeet() -> URL? {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        if comps.host?.lowercased() == "meet.google.com" {
            comps.scheme = "https"
            return comps.url
        }
        let trimmedPath = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let code: String? = {
            if let host = comps.host, !host.isEmpty { return host }
            if !trimmedPath.isEmpty { return trimmedPath }
            return nil
        }()
        guard let code, !code.isEmpty else { return nil }
        var web = URLComponents()
        web.scheme = "https"
        web.host = "meet.google.com"
        web.path = "/\(code)"
        return web.url
    }
}

// MARK: - Join Button

private struct JoinButton: View {
    @EnvironmentObject private var joinPreferences: JoinPreferenceStore
    let url: URL
    let service: MeetingService

    var body: some View {
        Button {
            openMeetingJoinURL(url: url, mode: joinPreferences.mode(for: service))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                Text(LocalizedStringKey(service.displayName))
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(String(format: NSLocalizedString("row.join_help", comment: ""), service.displayName))
    }
}

// MARK: - Tri-state “select all calendars” checkbox (AppKit)

private struct CalendarBulkTriStateCheckbox: NSViewRepresentable {
    @ObservedObject var store: CalendarSelectionStore
    let allCalendarIdentifiers: Set<String>

    final class Coordinator: NSObject {
        var store: CalendarSelectionStore
        var allIds: Set<String> = []

        init(store: CalendarSelectionStore) {
            self.store = store
        }

        @objc func clicked(_ sender: Any?) {
            let s = store
            let ids = allIds
            Task { @MainActor in
                s.toggleBulkCalendarCheckbox(allCalendarIdentifiers: ids)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: NSLocalizedString("settings.calendar.select_all", comment: ""),
            target: context.coordinator,
            action: #selector(Coordinator.clicked)
        )
        button.allowsMixedState = true
        button.toolTip = NSLocalizedString("settings.calendar.bulk_toggle_hint", comment: "")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.store = store
        context.coordinator.allIds = allCalendarIdentifiers
        button.title = NSLocalizedString("settings.calendar.select_all", comment: "")
        button.toolTip = NSLocalizedString("settings.calendar.bulk_toggle_hint", comment: "")
        let kind = store.bulkSelectionKind(allCalendarIdentifiers: allCalendarIdentifiers)
        switch kind {
        case .allOn:
            button.state = .on
        case .allOff:
            button.state = .off
        case .mixed:
            button.state = .mixed
        }
        button.isEnabled = !allCalendarIdentifiers.isEmpty
    }
}

// MARK: - Settings sheet

private enum SettingsSheetTab: Hashable {
    case meetingLinks
    case calendarSources
    case appearance
}

/// Same vibrancy material as `NSPopover` content (SwiftUI `Material` has no `.popover` on macOS).
private struct PopoverMaterialBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Far-jump date picker (header)

/// Matches nested `NSPopover` content chrome corner radius on recent macOS.
private let farJumpPopoverCornerRadius: CGFloat = 10

/// Bottom-trailing resize affordance — ⌝ whose bend matches the popover corner radius.
private struct CornerResizeGrip: View {
    var body: some View {
        CornerResizeGripShape(cornerRadius: farJumpPopoverCornerRadius)
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

private struct CornerResizeGripShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Keep stroke inside bounds; bend radius mirrors the outer popover frame.
        let pad: CGFloat = 1.25
        let r = min(cornerRadius, min(rect.width, rect.height) - pad * 2)
        let x = rect.maxX - pad
        let y = rect.maxY - pad
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY + pad))
        path.addLine(to: CGPoint(x: x, y: y - r))
        path.addArc(
            center: CGPoint(x: x - r, y: y - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + pad, y: y))
        return path
    }
}

/// Compact calendar chrome for far jumps — borderless AppKit picker so it sits flush in the nested popover.
private struct FarJumpDatePicker: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let selection: Date
    let onSelect: (Date) -> Void

    @State private var dragOriginScale: Double?

    private var scale: CGFloat { CGFloat(appearanceStore.datePickerScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("header.pick_date")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            // Bounds/frame scaling inside ScalingDatePickerView — outer chrome hugs this size.
            BorderlessCalendarDatePicker(date: selection, scale: scale, onChange: onSelect)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottomTrailing) {
            CornerResizeGrip()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .help(Text("menu.resize_date_picker"))
                .accessibilityLabel(Text("menu.resize_date_picker"))
                .onHover { hovering in
                    if hovering {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragOriginScale == nil {
                                dragOriginScale = appearanceStore.datePickerScale
                            }
                            let delta = (value.translation.width + value.translation.height) / 2
                            let next = (dragOriginScale ?? appearanceStore.datePickerScale) + Double(delta) / 180
                            appearanceStore.datePickerScale = next
                        }
                        .onEnded { _ in
                            dragOriginScale = nil
                        }
                )
        }
        .fixedSize()
    }
}

/// Borderless calendar `NSDatePicker` scaled via AppKit bounds/frame mapping (hugs scaled size).
private struct BorderlessCalendarDatePicker: NSViewRepresentable {
    var date: Date
    var scale: CGFloat
    var onChange: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> ScalingDatePickerView {
        let view = ScalingDatePickerView()
        view.scale = scale
        view.picker.dateValue = date
        view.picker.target = context.coordinator
        view.picker.action = #selector(Coordinator.valueChanged(_:))
        return view
    }

    func updateNSView(_ view: ScalingDatePickerView, context: Context) {
        context.coordinator.onChange = onChange
        if abs(view.scale - scale) > 0.000_1 {
            view.scale = scale
        }
        let keyed = MeetingDayWindow.startOfDay(date)
        if MeetingDayWindow.startOfDay(view.picker.dateValue) != keyed {
            view.picker.dateValue = keyed
        }
    }

    final class Coordinator: NSObject {
        var onChange: (Date) -> Void

        init(onChange: @escaping (Date) -> Void) {
            self.onChange = onChange
        }

        @objc func valueChanged(_ sender: NSDatePicker) {
            onChange(sender.dateValue)
        }
    }
}

/// Calendar picker whose header ● (between ◀ ▶) jumps to the current civil day / month.
private final class TodayAwareDatePicker: NSDatePicker {
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isInTodayControl(loc) {
            dateValue = MeetingDayWindow.startOfDay(Date())
            sendAction(action, to: target)
            return
        }
        super.mouseDown(with: event)
    }

    /// Middle control in the trailing ◀ ● ▶ cluster at the top of the calendar.
    private func isInTodayControl(_ p: NSPoint) -> Bool {
        let headerH: CGFloat = 28
        let inHeader = isFlipped
            ? (p.y >= 0 && p.y <= headerH)
            : (p.y >= bounds.height - headerH && p.y <= bounds.height)
        guard inHeader else { return false }

        // Three ~18pt controls; middle third is ● (“today”).
        let clusterW: CGFloat = 54
        let clusterMinX = bounds.maxX - clusterW - 4
        guard p.x >= clusterMinX, p.x <= bounds.maxX - 4 else { return false }
        let x = p.x - clusterMinX
        let third = clusterW / 3
        return x >= third && x < 2 * third
    }
}

/// `frame` = scaled size (for SwiftUI / popover), `bounds` = intrinsic calendar size — AppKit scales the picker to fill.
private final class ScalingDatePickerView: NSView {
    let picker: TodayAwareDatePicker = {
        let p = TodayAwareDatePicker(frame: .zero)
        p.datePickerStyle = .clockAndCalendar
        p.datePickerElements = [.yearMonthDay]
        p.datePickerMode = .single
        p.isBordered = false
        p.drawsBackground = false
        p.focusRingType = .none
        p.calendar = .current
        p.locale = .current
        return p
    }()

    var scale: CGFloat = 1 {
        didSet {
            guard abs(scale - oldValue) > 0.000_1 else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private var baseSize = NSSize(width: 198, height: 148)

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(baseSize.width * scale), height: ceil(baseSize.height * scale))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(picker)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBaseSize()
        syncBoundsToBaseSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep bounds at the unscaled calendar size so AppKit magnifies content into `frame`.
        syncBoundsToBaseSize()
    }

    override func layout() {
        super.layout()
        refreshBaseSize()
        syncBoundsToBaseSize()
        picker.frame = NSRect(origin: .zero, size: baseSize)
    }

    private func syncBoundsToBaseSize() {
        let next = NSRect(origin: .zero, size: baseSize)
        if bounds.size != baseSize {
            bounds = next
        }
    }

    private func refreshBaseSize() {
        picker.sizeToFit()
        let fitted = picker.fittingSize
        guard fitted.width > 1, fitted.height > 1 else { return }
        if fitted != baseSize {
            baseSize = fitted
            invalidateIntrinsicContentSize()
        }
    }
}

private struct JoinSettingsView: View {
    @EnvironmentObject private var joinPreferences: JoinPreferenceStore
    @EnvironmentObject private var manager: CalendarManager
    @EnvironmentObject private var calendarSelection: CalendarSelectionStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab = .meetingLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("settings.title")
                    .font(.headline)
                Spacer()
                Button("settings.done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker("", selection: $selectedTab) {
                Text("settings.tab.meeting_links").tag(SettingsSheetTab.meetingLinks)
                Text("settings.tab.calendar_sources").tag(SettingsSheetTab.calendarSources)
                Text("settings.tab.appearance").tag(SettingsSheetTab.appearance)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .meetingLinks:
                    meetingLinksPane
                case .calendarSources:
                    CalendarSourcesSettingsPane()
                case .appearance:
                    AppearanceSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 380, height: 320)
        .padding(.bottom, 8)
        .background {
            PopoverMaterialBackgroundView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var meetingLinksPane: some View {
        Form {
            Section {
                ForEach(MeetingService.joinPreferenceServices, id: \.self) { service in
                    HStack(alignment: .center) {
                        Text(LocalizedStringKey(service.joinSettingsLabelKey))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { joinPreferences.mode(for: service) },
                            set: { joinPreferences.setMode($0, for: service) }
                        )) {
                            Text("settings.join.native").tag(JoinOpenMode.native)
                            Text("settings.join.browser").tag(JoinOpenMode.browser)
                        }
                        .labelsHidden()
                        .frame(width: 196)
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("settings.join.section")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarSourcesSettingsPane: View {
    @EnvironmentObject private var manager: CalendarManager
    @EnvironmentObject private var calendarSelection: CalendarSelectionStore

    var body: some View {
        Group {
            if !manager.isAuthorized {
                VStack(spacing: 12) {
                    Text("auth.required")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("auth.grant") {
                        manager.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                calendarListContent
            }
        }
    }

    @ViewBuilder
    private var calendarListContent: some View {
        let calendars = manager.eventCalendarsForSettings()
        let allIds = Set(calendars.map(\.calendarIdentifier))

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.calendar_section")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                CalendarBulkTriStateCheckbox(store: calendarSelection, allCalendarIdentifiers: allIds)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if calendars.isEmpty {
                Text("settings.calendar.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(calendars.enumerated()), id: \.element.calendarIdentifier) { index, cal in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                            calendarRow(cal, allIds: allIds)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func calendarRow(_ cal: EKCalendar, allIds: Set<String>) -> some View {
        Toggle(isOn: Binding(
            get: { calendarSelection.isCalendarIncluded(cal.calendarIdentifier, allCalendarIdentifiers: allIds) },
            set: { calendarSelection.setCalendarIncluded(cal.calendarIdentifier, included: $0, allCalendarIdentifiers: allIds) }
        )) {
            HStack(spacing: 8) {
                calendarColorDot(cal.cgColor)
                Text(cal.title)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func calendarColorDot(_ cgColor: CGColor) -> some View {
        let color = NSColor(cgColor: cgColor) ?? .secondaryLabelColor
        return Circle()
            .fill(Color(nsColor: color))
            .frame(width: 10, height: 10)
    }
}

// MARK: - Appearance Settings Pane

private enum AppearancePreviewFocus {
    case menuBar
    case listRow
}

private struct AppearanceSettingsPane: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @State private var showFloatingPreview = false
    @State private var previewFocus: AppearancePreviewFocus = .menuBar
    @State private var hidePreviewWorkItem: DispatchWorkItem?
    @State private var isAdjustingControl = false
    @State private var isOptionPressed = false
    @State private var localFlagsMonitor: Any?
    @State private var globalFlagsMonitor: Any?

    private func updateOptionPressed(from flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.option)
        let wasPressed = isOptionPressed
        isOptionPressed = pressed

        if wasPressed && !pressed && !isAdjustingControl {
            schedulePreviewHide(after: 0.6)
        }
    }

    private func showPreview(focus: AppearancePreviewFocus) {
        previewFocus = focus
        hidePreviewWorkItem?.cancel()
        showFloatingPreview = true
    }

    private func schedulePreviewHide(after seconds: Double = 1.0) {
        guard !isOptionPressed && !isAdjustingControl else { return }
        hidePreviewWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            showFloatingPreview = false
        }
        hidePreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("settings.appearance.font_size")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appearanceStore.fontSize },
                            set: {
                                appearanceStore.fontSize = $0
                                showPreview(focus: .listRow)
                            }
                        ),
                        in: 10...18, step: 0.5,
                        onEditingChanged: { isEditing in
                            isAdjustingControl = isEditing
                            if isEditing {
                                showPreview(focus: .listRow)
                            } else {
                                schedulePreviewHide()
                            }
                        }
                    )
                    .frame(width: 110)
                    Text("\(String(format: "%.1f", appearanceStore.fontSize))pt")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("settings.appearance.menu_bar_title_font_size")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appearanceStore.menuBarTitleFontSize },
                            set: {
                                appearanceStore.menuBarTitleFontSize = $0
                                showPreview(focus: .menuBar)
                            }
                        ),
                        in: 8...18, step: 0.5,
                        onEditingChanged: { isEditing in
                            isAdjustingControl = isEditing
                            if isEditing {
                                showPreview(focus: .menuBar)
                            } else {
                                schedulePreviewHide()
                            }
                        }
                    )
                    .frame(width: 110)
                    Text("\(String(format: "%.1f", appearanceStore.menuBarTitleFontSize))pt")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("settings.appearance.menu_bar_time_font_size")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appearanceStore.menuBarTimeFontSize },
                            set: {
                                appearanceStore.menuBarTimeFontSize = $0
                                showPreview(focus: .menuBar)
                            }
                        ),
                        in: 5...12, step: 0.5,
                        onEditingChanged: { isEditing in
                            isAdjustingControl = isEditing
                            if isEditing {
                                showPreview(focus: .menuBar)
                            } else {
                                schedulePreviewHide()
                            }
                        }
                    )
                    .frame(width: 110)
                    Text("\(String(format: "%.1f", appearanceStore.menuBarTimeFontSize))pt")
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("settings.appearance.menu_bar_length")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { appearanceStore.menuBarTitleLength },
                            set: {
                                appearanceStore.menuBarTitleLength = $0
                                showPreview(focus: .menuBar)
                                schedulePreviewHide(after: 1.2)
                            }
                        ),
                        in: 5...30
                    ) {
                        Text("\(appearanceStore.menuBarTitleLength)")
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            } header: {
                Text("settings.appearance.section")
            }
        }
        .formStyle(.grouped)
        .popover(isPresented: $showFloatingPreview, arrowEdge: .trailing) {
            AppearancePreviewCard(focus: previewFocus)
                .padding(12)
                .frame(width: 280)
        }
        .onAppear {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                updateOptionPressed(from: event.modifierFlags)
                return event
            }
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                updateOptionPressed(from: event.modifierFlags)
            }
        }
        .onDisappear {
            hidePreviewWorkItem?.cancel()
            hidePreviewWorkItem = nil
            if let localFlagsMonitor {
                NSEvent.removeMonitor(localFlagsMonitor)
                self.localFlagsMonitor = nil
            }
            if let globalFlagsMonitor {
                NSEvent.removeMonitor(globalFlagsMonitor)
                self.globalFlagsMonitor = nil
            }
        }
    }
}

private struct AppearancePreviewCard: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let focus: AppearancePreviewFocus

    private var previewTitle: String {
        let raw = NSLocalizedString("settings.appearance.preview_title", comment: "")
        return raw.prefix(halfwidthUnits: appearanceStore.menuBarTitleLength)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focus == .menuBar {
                Text("settings.appearance.preview_menu_bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(NSLocalizedString("settings.appearance.preview_time", comment: ""))
                            .font(.system(size: appearanceStore.menuBarTimeFontSize, weight: .regular))
                        Text(previewTitle)
                            .font(.system(size: appearanceStore.menuBarTitleFontSize, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if focus == .listRow {
                Text("settings.appearance.preview_list_row")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.appearance.preview_meeting")
                        .font(.system(size: appearanceStore.fontSize))
                        .lineLimit(2)
                    Text("settings.appearance.preview_location")
                        .font(.system(size: max(8, appearanceStore.fontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Footer

private enum FooterLinks {
    static let license = URL(string: "https://github.com/dytsou/ProxiMeeting/blob/main/LICENSE")!
}

private struct FooterView: View {
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = updateChecker.availableDownloadURL, let version = updateChecker.availableVersion {
                Button {
                    NotificationCenter.default.post(name: .proxiMeetingDismissPopover, object: nil)
                    _ = NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(String(format: NSLocalizedString("update.available.title", comment: ""), version))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 2)
            }

            HStack {
                Button("footer.open_calendar") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("footer.quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Link(destination: FooterLinks.license) {
                Text("footer.copyright")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
