import SwiftUI
import AppKit
import Combine

/// Shared app state installed after `applicationDidFinishLaunching` so the status item attaches with a finalized activation policy (LSUIElement + delegates).
@MainActor
final class ApplicationSession {
    let calendarSelection: CalendarSelectionStore
    let calendarManager: CalendarManager
    private(set) var statusBarController: StatusBarController?

    init() {
        calendarSelection = CalendarSelectionStore()
        calendarManager = CalendarManager(calendarSelection: calendarSelection)
    }

    func installStatusBarIfNeeded() {
        guard statusBarController == nil else { return }
        statusBarController = StatusBarController(manager: calendarManager, calendarSelection: calendarSelection)
        AppDebug.log("Installed NSStatusItem (application session ready)")
    }
}

/// Handles `nextmeeting://…` URLs (Raycast extension, scripts, Automation).
final class NextMeetingApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var session: ApplicationSession?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Without this, merging a delegate with SwiftUI can leave policy unset such that accessory UI never shows reliably.
        if !NSApp.setActivationPolicy(.accessory) {
            AppDebug.log("setActivationPolicy(.accessory) returned false — menu bar tray may not appear")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.session?.installStatusBarIfNeeded()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor [weak self] in
            self?.handleDeepLinks(urls)
        }
    }

    @MainActor
    private func handleDeepLinks(_ urls: [URL]) {
        session?.installStatusBarIfNeeded()
        guard let session, let statusBarController = session.statusBarController else { return }

        NSApp.activate(ignoringOtherApps: true)

        let calendarManager = session.calendarManager
        for url in urls {
            guard url.scheme?.caseInsensitiveCompare("nextmeeting") == .orderedSame else { continue }

            let host = (url.host ?? "").lowercased()

            switch host {
            case "refresh":
                calendarManager.fetchMeetings()
                AppDebug.log("DeepLink: refresh")
            case "open-popover":
                statusBarController.showPopoverAnchoredAtStatusItem()
                AppDebug.log("DeepLink: open-popover")
            case "open-preferences":
                statusBarController.showPopoverAnchoredAtStatusItem()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .nextMeetingOpenJoinSettings, object: nil)
                }
                AppDebug.log("DeepLink: open-preferences")
            default:
                AppDebug.log("DeepLink: ignored URL \(url.absoluteString)")
            }
        }
    }
}

@main
struct NextMeetingApp: App {
    @NSApplicationDelegateAdaptor(NextMeetingApplicationDelegate.self) private var appDelegate
    private let session = ApplicationSession()

    init() {
        appDelegate.session = session
    }

    // MenuBarExtra is no longer used — popover is managed by StatusBarController
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppKit Status Bar Controller

@MainActor
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let joinPreferenceStore = JoinPreferenceStore()
    private let calendarSelectionStore: CalendarSelectionStore
    private let appearanceStore = AppearanceStore()
    private let updateChecker = UpdateChecker()
    private var currentMeeting: Meeting?
    private var cancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?
    private var sizeObservation: NSKeyValueObservation?
    private var dismissPopoverObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var upgradeRelaunchTimer: Timer?
    private var hasScheduledRelaunch = false

    init(manager: CalendarManager, calendarSelection: CalendarSelectionStore) {
        calendarSelectionStore = calendarSelection
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        popover = NSPopover()
        let hostingController = NSHostingController(
            rootView: MeetingMenuView()
                .environmentObject(manager)
                .environmentObject(joinPreferenceStore)
                .environmentObject(calendarSelectionStore)
                .environmentObject(appearanceStore)
                .environmentObject(updateChecker)
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true

        super.init()

        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] hc, _ in
            let size = hc.preferredContentSize
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.contentSize = size
            }
        }

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        update(meeting: nil)

        cancellable = manager.$nextMeeting
            .receive(on: RunLoop.main)
            .sink { [weak self] meeting in
                self?.currentMeeting = meeting
                self?.update(meeting: meeting)
            }

        appearanceCancellable = appearanceStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.update(meeting: self?.currentMeeting)
                }
            }

        dismissPopoverObserver = NotificationCenter.default.addObserver(
            forName: .nextMeetingDismissPopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.updateChecker.checkIfNeeded()
                self.checkForOnDiskUpgradeAndRelaunchIfNeeded()
            }
        }

        updateChecker.start()

        // Homebrew upgrades replace the app on disk while it is running.
        // If the on-disk bundle version changes, relaunch to the new version automatically.
        upgradeRelaunchTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForOnDiskUpgradeAndRelaunchIfNeeded()
            }
        }
    }

    deinit {
        upgradeRelaunchTimer?.invalidate()
        upgradeRelaunchTimer = nil
        if let dismissPopoverObserver {
            NotificationCenter.default.removeObserver(dismissPopoverObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        sizeObservation?.invalidate()
        cancellable?.cancel()
        appearanceCancellable?.cancel()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Opens the transient popover (used by Raycast commands and `nextmeeting://open-popover`).
    func showPopoverAnchoredAtStatusItem() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else {
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func update(meeting: Meeting?) {
        guard let button = statusItem.button else { return }

        let symbolName = meeting?.isNow == true ? "calendar.badge.clock" : "calendar"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon?.isTemplate = true

        button.image = icon
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown

        guard let meeting else {
            let str = NSAttributedString(
                string: NSLocalizedString("label.no_meeting", comment: ""),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            button.attributedTitle = str
            return
        }

        let title = meeting.title.prefix(halfwidthUnits: appearanceStore.menuBarTitleLength)
        let time =
            meeting.formattedEndTime.isEmpty
            ? "\(meeting.formattedStartTime)"
            : "\(meeting.formattedStartTime) – \(meeting.formattedEndTime)"

        let str = NSMutableAttributedString(
            string: time + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: appearanceStore.menuBarTimeFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        str.append(NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: appearanceStore.menuBarTitleFontSize, weight: .semibold)]
        ))
        button.attributedTitle = str
    }

    private func checkForOnDiskUpgradeAndRelaunchIfNeeded() {
        guard !hasScheduledRelaunch else { return }

        let runningRaw =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "0"
        let onDiskRaw = Self.onDiskAppVersionString(bundleURL: Bundle.main.bundleURL) ?? runningRaw

        guard runningRaw != onDiskRaw else { return }

        hasScheduledRelaunch = true
        AppDebug.log("Detected on-disk upgrade: running=\(runningRaw), onDisk=\(onDiskRaw). Relaunching.")

        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func onDiskAppVersionString(bundleURL: URL) -> String? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        return (dict["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
