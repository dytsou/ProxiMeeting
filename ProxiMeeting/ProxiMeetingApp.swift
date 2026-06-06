import SwiftUI
import AppKit
import Combine
import OSLog

/// Unified logging for “tray not visible” reports (Console / `log show` — subsystem = bundle id, category = MenuBarTray).
private enum TrayOSLog {
    private static var log: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.proximeeting.app", category: "MenuBarTray")
    }

    static func notice(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
}

// #region agent log
/// NDJSON instrumentation for Cursor debug sessions (writes to workspace `.cursor/debug-*.log`).
private enum AgentDebugNDJSON {
    static let path = "/Users/dytsou/src/ProxiMeeting/.cursor/debug-128e40.log"
    static let sessionId = "128e40"

    private struct Line: Encodable {
        let sessionId: String
        let runId: String
        let timestamp: Int64
        let hypothesisId: String
        let location: String
        let message: String
        let data: [String: String]
    }

    /// - Note: synchronous append from MainActor call sites only; avoids reorder.
    static func log(
        runId: String = "pre-fix",
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let payload = Line(
            sessionId: sessionId,
            runId: runId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hypothesisId: hypothesisId,
            location: location,
            message: message,
            data: data
        )
        guard let json = try? JSONEncoder().encode(payload),
              var text = String(data: json, encoding: .utf8) else { return }
        text += "\n"
        guard let chunk = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: chunk)
        } catch {}
    }
}
// #endregion

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
        // #region agent log
        let hadController = statusBarController != nil
        AgentDebugNDJSON.log(
            hypothesisId: "H2",
            location: "ApplicationSession.installStatusBarIfNeeded.entry",
            message: "entered",
            data: ["alreadyHadController": hadController ? "true" : "false"]
        )
        // #endregion
        guard statusBarController == nil else {
            TrayOSLog.notice("installStatusBarIfNeeded: already installed — skipping")
            return
        }
        TrayOSLog.notice("installStatusBarIfNeeded: creating StatusBarController")
        statusBarController = StatusBarController(manager: calendarManager, calendarSelection: calendarSelection)
        AppDebug.log("Installed NSStatusItem (application session ready)")
    }
}

/// Handles `proximeeting://…` URLs (Raycast extension, scripts, Automation).
final class ProxiMeetingApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var session: ApplicationSession?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // #region agent log
        AgentDebugNDJSON.log(
            hypothesisId: "H5",
            location: "ProxiMeetingApplicationDelegate.applicationWillFinishLaunching",
            message: "willFinishLaunching",
            data: [
                "activationPolicyRaw": "\(NSApp.activationPolicy().rawValue)",
                "bundleLeaf": Bundle.main.bundleURL.lastPathComponent
            ]
        )
        // #endregion
        TrayOSLog.notice(
            "applicationWillFinishLaunching: bundle=\(Bundle.main.bundleURL.lastPathComponent) policyRaw=\(NSApp.activationPolicy().rawValue)"
        )
        // Without applying `.accessory` here, merging a SwiftUI App with a delegate can leave policy unset briefly.
        if NSApp.activationPolicy() != .accessory {
            let ok = NSApp.setActivationPolicy(.accessory)
            // `false` alone is not definitive — policy may already be `.accessory` from App init.
            if !ok, NSApp.activationPolicy() != .accessory {
                AppDebug.log("setActivationPolicy(.accessory) failed — menu bar tray may not appear")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // #region agent log
        AgentDebugNDJSON.log(
            hypothesisId: "H1",
            location: "ProxiMeetingApplicationDelegate.applicationDidFinishLaunching",
            message: "didFinishLaunching session wired",
            data: ["sessionNil": session == nil ? "true" : "false"]
        )
        // #endregion
        TrayOSLog.notice("applicationDidFinishLaunching: scheduling immediate Tray Task + deferred retry")
        // First chance: ASAP on MainActor while still in launch transient.
        Task { @MainActor [weak self] in
            if NSApp.activationPolicy() != .accessory {
                _ = NSApp.setActivationPolicy(.accessory)
            }
            TrayOSLog.notice(
                "tray-install pass A: policyRaw=\(NSApp.activationPolicy().rawValue)"
            )
            // #region agent log
            AgentDebugNDJSON.log(
                hypothesisId: "H5",
                location: "ProxiMeetingApplicationDelegate.trayPassA",
                message: "pass A before install",
                data: ["activationPolicyRaw": "\(NSApp.activationPolicy().rawValue)", "sessionNil": self?.session == nil ? "true" : "false"]
            )
            // #endregion
            self?.session?.installStatusBarIfNeeded()
        }
        // Second chance after SwiftUI / scene bootstrap has progressed one runloop.
        DispatchQueue.main.async { [weak self] in
            if NSApp.activationPolicy() != .accessory {
                let okRetry = NSApp.setActivationPolicy(.accessory)
                if !okRetry, NSApp.activationPolicy() != .accessory {
                    AppDebug.log("Deferred setActivationPolicy(.accessory) failed — tray may be missing until next launch.")
                }
            }
            TrayOSLog.notice(
                "tray-install pass B: policyRaw=\(NSApp.activationPolicy().rawValue)"
            )
            // #region agent log
            AgentDebugNDJSON.log(
                hypothesisId: "H5",
                location: "ProxiMeetingApplicationDelegate.trayPassB",
                message: "pass B before install",
                data: ["activationPolicyRaw": "\(NSApp.activationPolicy().rawValue)", "sessionNil": self?.session == nil ? "true" : "false"]
            )
            // #endregion
            Task { @MainActor [weak self] in
                self?.session?.installStatusBarIfNeeded()
            }
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
            guard url.scheme?.caseInsensitiveCompare("proximeeting") == .orderedSame else { continue }

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
                    NotificationCenter.default.post(name: .proxiMeetingOpenJoinSettings, object: nil)
                }
                AppDebug.log("DeepLink: open-preferences")
            default:
                AppDebug.log("DeepLink: ignored URL \(url.absoluteString)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // #region agent log
        AgentDebugNDJSON.log(
            hypothesisId: "H3",
            location: "ProxiMeetingApplicationDelegate.applicationWillTerminate",
            message: "willTerminate",
            data: [:]
        )
        // #endregion
    }
}

@main
struct ProxiMeetingApp: App {
    @NSApplicationDelegateAdaptor(ProxiMeetingApplicationDelegate.self) private var appDelegate
    private let session = ApplicationSession()

    init() {
        if NSApplication.shared.activationPolicy() != .accessory {
            let ok = NSApplication.shared.setActivationPolicy(.accessory)
            if !ok, NSApplication.shared.activationPolicy() != .accessory {
                AppDebug.log("init: setActivationPolicy(.accessory) failed")
            }
        }
        TrayOSLog.notice(
            "ProxiMeetingApp.init: policyRaw=\(NSApplication.shared.activationPolicy().rawValue) bundleLeaf=\(Bundle.main.bundleURL.lastPathComponent)"
        )
        appDelegate.session = session
        // #region agent log
        AgentDebugNDJSON.log(
            hypothesisId: "H1",
            location: "ProxiMeetingApp.init",
            message: "init session assigned to delegate",
            data: [
                "activationPolicyRaw": "\(NSApplication.shared.activationPolicy().rawValue)",
                "bundleLeaf": Bundle.main.bundleURL.lastPathComponent,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""
            ]
        )
        // #endregion
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
            let display =
                (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
            button.toolTip = display
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
            forName: .proxiMeetingDismissPopover,
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

        TrayOSLog.notice(
            "StatusBarController.init: isVisible=\(statusItem.isVisible) buttonNil=\(statusItem.button == nil)"
        )
        // #region agent log
        AgentDebugNDJSON.log(
            hypothesisId: "H4",
            location: "StatusBarController.init",
            message: "after NSStatusItem wiring",
            data: [
                "isVisible": statusItem.isVisible ? "true" : "false",
                "buttonNil": statusItem.button == nil ? "true" : "false"
            ]
        )
        // #endregion

        DispatchQueue.main.async { [weak self] in
            guard let self, let btn = self.statusItem.button else {
                TrayOSLog.notice("StatusBarController postLayout: button is nil")
                // #region agent log
                AgentDebugNDJSON.log(
                    hypothesisId: "H4",
                    location: "StatusBarController.postLayout",
                    message: "button nil",
                    data: [:]
                )
                // #endregion
                return
            }
            TrayOSLog.notice(
                "StatusBarController postLayout: w=\(String(format: "%.1f", btn.frame.width)) h=\(String(format: "%.1f", btn.frame.height)) hidden=\(btn.isHidden) inWindow=\(btn.window != nil)"
            )
            // #region agent log
            AgentDebugNDJSON.log(
                hypothesisId: "H4",
                location: "StatusBarController.postLayout",
                message: "layout",
                data: [
                    "w": String(format: "%.1f", btn.frame.width),
                    "h": String(format: "%.1f", btn.frame.height),
                    "buttonHidden": btn.isHidden ? "true" : "false",
                    "inWindow": btn.window != nil ? "true" : "false",
                    "nsAppHidden": NSApp.isHidden ? "true" : "false",
                    "nsAppActive": NSApp.isActive ? "true" : "false"
                ]
            )
            // #endregion
        }

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

    /// Opens the transient popover (used by Raycast commands and `proximeeting://open-popover`).
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
        button.imageScaling = .scaleProportionallyDown

        guard let meeting else {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            return
        }

        button.imagePosition = .imageLeft

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
