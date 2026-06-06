import Foundation

private enum UpdateDefaultsKeys {
    static let lastUpdateCheckDate = "updates.lastUpdateCheckDate"
    static let availableVersion = "updates.availableVersion"
    static let availableDownloadURL = "updates.availableDownloadURL"
    static let lastSeenAppVersion = "updates.lastSeenAppVersion"
}

private struct GitHubLatestRelease: Decodable {
    let tag_name: String
    let html_url: String
}

@MainActor
final class UpdateChecker: ObservableObject {
    private let defaults = UserDefaults.standard
    private let releaseURL = URL(string: "https://api.github.com/repos/dytsou/ProxiMeeting/releases/latest")!

    private var dailyTimer: Timer?

    @Published private(set) var availableVersion: String?
    @Published private(set) var availableDownloadURL: URL?

    init() {
        let shouldAllowDevOverrides = AppDebug.isEnabled
        let currentRaw =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "0"

        // In normal mode, we still load the last known "update available" state so the user
        // can upgrade immediately (e.g., via Homebrew) without waiting for the next poll.
        // `checkNow()` will clear this state when it confirms we're up-to-date.
        self.availableVersion = defaults.string(forKey: UpdateDefaultsKeys.availableVersion)
        if let raw = defaults.string(forKey: UpdateDefaultsKeys.availableDownloadURL) {
            self.availableDownloadURL = URL(string: raw)
        } else {
            self.availableDownloadURL = nil
        }

        if shouldAllowDevOverrides {
            // Dev mode may overwrite the above values.
            return
        }

        // If the installed app version changes (e.g. Homebrew upgraded the app), do not keep
        // showing a stale "update available" banner from a previous run.
        let lastSeen = defaults.string(forKey: UpdateDefaultsKeys.lastSeenAppVersion)
        if lastSeen != currentRaw {
            defaults.set(currentRaw, forKey: UpdateDefaultsKeys.lastSeenAppVersion)
            defaults.removeObject(forKey: UpdateDefaultsKeys.lastUpdateCheckDate)
        }

        // If we already satisfy the persisted available version, clear it immediately so the UI
        // doesn't confuse users who upgraded and relaunched on the same day.
        if let persisted = defaults.string(forKey: UpdateDefaultsKeys.availableVersion),
           let currentVersion = SemVer(currentRaw),
           let persistedVersion = SemVer(persisted),
           currentVersion >= persistedVersion {
            clearAvailableUpdate()
        }
    }

    func start() {
        applyDevOverridesIfNeeded()
        Task { [weak self] in
            await self?.checkIfNeeded()
            await self?.scheduleNextDailyCheck()
        }
    }

    func checkIfNeeded() async {
        applyDevOverridesIfNeeded()
        if let last = defaults.object(forKey: UpdateDefaultsKeys.lastUpdateCheckDate) as? Date,
           Calendar.current.isDateInToday(last) {
            return
        }
        defaults.set(Date(), forKey: UpdateDefaultsKeys.lastUpdateCheckDate)
        await checkNow()
    }

    func scheduleNextDailyCheck() async {
        dailyTimer?.invalidate()
        dailyTimer = nil

        let now = Date()
        guard let next = Self.nextNineAM(after: now) else { return }
        let interval = max(5, next.timeIntervalSince(now))

        dailyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { [weak self] in
                await self?.checkIfNeeded()
                await self?.scheduleNextDailyCheck()
            }
        }
    }

    private func checkNow() async {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let currentVersion = SemVer(current) else { return }

        var request = URLRequest(url: releaseURL)
        request.setValue("ProxiMeeting", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let latest = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
            let latestTag = latest.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let latestVersion = SemVer(latestTag) else { return }

            guard latestVersion > currentVersion else {
                if !AppDebug.isEnabled {
                    clearAvailableUpdate()
                }
                return
            }

            let downloadURL = URL(string: latest.html_url) ?? URL(string: "https://github.com/dytsou/ProxiMeeting/releases/latest")!
            setAvailableUpdate(version: latestVersion.stringValue, downloadURL: downloadURL)
        } catch {
            // Ignore transient network/decoding errors; we will retry tomorrow.
        }
    }

    private func setAvailableUpdate(version: String, downloadURL: URL) {
        defaults.set(version, forKey: UpdateDefaultsKeys.availableVersion)
        defaults.set(downloadURL.absoluteString, forKey: UpdateDefaultsKeys.availableDownloadURL)
        availableVersion = version
        availableDownloadURL = downloadURL
    }

    private func clearAvailableUpdate() {
        defaults.removeObject(forKey: UpdateDefaultsKeys.availableVersion)
        defaults.removeObject(forKey: UpdateDefaultsKeys.availableDownloadURL)
        availableVersion = nil
        availableDownloadURL = nil
    }

    private func applyDevOverridesIfNeeded() {
        guard AppDebug.isEnabled else { return }
        AppDebug.log("Forcing update link (DEV) regardless of latest release.")
        let url = URL(string: "https://github.com/dytsou/ProxiMeeting/releases/latest")!
        setAvailableUpdate(version: "DEV", downloadURL: url)
    }

    private static func nextNineAM(after date: Date) -> Date? {
        let cal = Calendar.current
        let todayNine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)
        if let todayNine, date < todayNine { return todayNine }
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }
}

private struct SemVer: Comparable {
    let parts: [Int]
    let stringValue: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed

        let tokens = noPrefix.split(separator: ".").map { String($0) }
        let ints = tokens.compactMap { Int($0.filter(\.isNumber)) }
        guard !ints.isEmpty else { return nil }

        self.parts = ints
        self.stringValue = noPrefix
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        let maxCount = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<maxCount {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

