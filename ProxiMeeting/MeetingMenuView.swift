import SwiftUI
import AppKit
import EventKit

extension Notification.Name {
    /// Posted before opening a meeting in the browser so the menu popover can dismiss (browser preference or native fallback).
    static let proxiMeetingDismissPopover = Notification.Name("ProxiMeetingDismissPopover")
    /// Opens the Join / Settings sheet (Raycast extension and `proximeeting://open-preferences`).
    static let proxiMeetingOpenJoinSettings = Notification.Name("ProxiMeetingOpenJoinSettings")
}

// MARK: - Root Menu View

enum MeetingTab { case today, tomorrow }

struct MeetingMenuView: View {
    @EnvironmentObject var manager: CalendarManager
    @EnvironmentObject var joinPreferences: JoinPreferenceStore
    @EnvironmentObject var calendarSelection: CalendarSelectionStore
    @EnvironmentObject var appearanceStore: AppearanceStore
    @State private var selectedTab: MeetingTab = .today
    @State private var showJoinSettings = false

    private var defaultTab: MeetingTab {
        manager.upcomingMeetings.isEmpty ? .tomorrow : .today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(selectedTab: $selectedTab, showJoinSettings: $showJoinSettings)
            Divider()
            ContentView(selectedTab: selectedTab)
            Divider()
            FooterView()
        }
        .frame(width: 340)
        .environmentObject(manager)
        .environmentObject(joinPreferences)
        .environmentObject(calendarSelection)
        .onAppear { selectedTab = defaultTab }
        .onReceive(NotificationCenter.default.publisher(for: .proxiMeetingOpenJoinSettings)) { _ in
            showJoinSettings = true
        }
        .sheet(isPresented: $showJoinSettings) {
            JoinSettingsView()
                .environmentObject(joinPreferences)
                .environmentObject(manager)
                .environmentObject(calendarSelection)
                .environmentObject(appearanceStore)
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var manager: CalendarManager
    @Binding var selectedTab: MeetingTab
    @Binding var showJoinSettings: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("header.title")
                        .font(.headline)
                    Text(Date(), format: .dateTime.year().month(.wide).day().weekday(.wide))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        manager.fetchMeetings()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("header.refresh"))

                    Button {
                        showJoinSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("footer.settings"))
                }
            }

            Picker("", selection: $selectedTab) {
                Text("tab.today").tag(MeetingTab.today)
                Text("tab.tomorrow").tag(MeetingTab.tomorrow)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - Content

private struct ContentView: View {
    @EnvironmentObject var manager: CalendarManager
    let selectedTab: MeetingTab

    var body: some View {
        if !manager.isAuthorized {
            UnauthorizedView()
        } else {
            let meetings = selectedTab == .today ? manager.upcomingMeetings : manager.tomorrowMeetings
            if meetings.isEmpty {
                NoMeetingsView(selectedTab: selectedTab)
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
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private struct NoMeetingsView: View {
    let selectedTab: MeetingTab

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Group {
                switch selectedTab {
                case .today:
                    Text("empty.no_meetings")
                case .tomorrow:
                    Text("empty.no_meetings_tomorrow")
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .id(selectedTab)
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
        .frame(maxHeight: appearanceStore.popoverListHeight)
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
