<p align="center">
  <img src="./ProxiMeeting/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="ProxiMeeting" width="128" height="128" />
</p>

# ProxiMeeting

![Language: Swift](https://img.shields.io/badge/Language-Swift-F05138?logo=swift&logoColor=white)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
[![Build & Release](https://github.com/dytsou/ProxiMeeting/actions/workflows/build.yml/badge.svg)](https://github.com/dytsou/ProxiMeeting/actions/workflows/build.yml)
[![Latest Release](https://img.shields.io/github/v/release/dytsou/ProxiMeeting?display_name=tag&sort=semver)](https://github.com/dytsou/ProxiMeeting/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A macOS menu bar app that shows your next meeting at a glance.

![Screenshot](./ProxiMeeting/screenshot.jpg)

## Features

- Displays the next meeting time in the menu bar
- Shows "In Progress" when a meeting is currently active
- Popup list of all remaining meetings today
- Auto-detects video conferencing links (Zoom, Google Meet, Teams, Webex, Whereby)
- One-click join button for detected meeting links; **Settings** sets **App** vs **browser** per provider (Zoom, Google Meet, Teams, Webex, Whereby)
- **Calendar selection:** in **Settings**, use the **Calendars** tab to limit which Apple Calendar sources are read
- Refreshes every 60 seconds and on calendar changes
- Daily update check (GitHub Releases) with in-app update link
- Supports English and Traditional Chinese (follows system language)

## Requirements

- macOS 13 Ventura or later
- macOS Calendar app synced with your Google account
- **To build with `./build.sh`:** Xcode Command Line Tools only (~500 MB) — full Xcode is **not** required
- **To open the generated `.xcodeproj`:** full Xcode (Option B)

## Setup

### 1. Sync Google Calendar

Open **Calendar.app** → Preferences → Accounts → add your Google account. ProxiMeeting reads events directly from the system calendar — no API keys or OAuth required.

### 2. Install with Homebrew

Install the [Homebrew tap](https://github.com/dytsou/homebrew-proximeeting) (GUI app via Cask):

```bash
brew tap dytsou/proximeeting
brew install --cask proximeeting
```

#### Upgrade with Homebrew

```bash
brew upgrade --cask proximeeting
```

If the upgrade fails, try:

```bash
brew update
brew upgrade --cask proximeeting --verbose
brew reinstall --cask proximeeting
brew doctor
```

If not using Homebrew, build the app manually.

**Option A — Command Line Tools only** (no full Xcode app):

1. Install the tools if needed. If `xcode-select --install` reports they are **already installed**, you can skip this; install updates via **System Settings → General → Software Update** when offered.

   ```bash
   xcode-select --install
   ```

2. Point the active developer directory at the standalone CLI tools (only if `xcode-select -p` shows a path inside `Xcode.app`):

   ```bash
   sudo xcode-select -s /Library/Developer/CommandLineTools
   ```

   For CLI-only builds, `xcode-select -p` should print `/Library/Developer/CommandLineTools`.

3. Build:

   ```bash
   git clone https://github.com/dytsou/ProxiMeeting.git
   cd ProxiMeeting
   ./build.sh
   ```

The script compiles with `swiftc`, creates `ProxiMeeting.app`, and offers to install it to `/Applications`.

**Option B — With Xcode** (uses xcodegen to generate the project):

```bash
git clone https://github.com/dytsou/ProxiMeeting.git
cd ProxiMeeting
./setup.sh
```

`setup.sh` installs xcodegen via Homebrew if needed, generates `ProxiMeeting.xcodeproj`, and opens it.

1. Go to **Signing & Capabilities** and select your Apple ID team
2. Press **Command+R** to build and run
3. Grant calendar access when prompted

## First launch and security

- **Menu bar app:** ProxiMeeting runs in the **menu bar** and may not appear in the Dock after launch. Look for its icon near the clock.
- **Opening from Terminal:** An `.app` bundle is a folder, not a shell command. Use **`open`**, for example:

  ```bash
  open /Applications/ProxiMeeting.app
  ```

  Or use Finder → **Applications** → **ProxiMeeting**. If Homebrew installed to your user folder, try `open ~/Applications/ProxiMeeting.app`.

- **Gatekeeper (“Apple could not verify…”):** Releases are built with ad-hoc signing and are **not** Apple-notarized, so macOS may show a warning the first time you open the app. This means the binary is not stapled with Apple’s notarization ticket—not that Apple detected malware. If you trust [this source](https://github.com/dytsou/ProxiMeeting), you can proceed: **Control-click** (or right-click) the app in Finder → **Open**, then confirm **Open**; or go to **System Settings → Privacy & Security** and use **Open Anyway** when ProxiMeeting is listed. Avoid turning off Gatekeeper entirely for the whole Mac.

## Troubleshooting: menu bar item doesn't appear

You installed ProxiMeeting, it launched, but no icon shows up near the clock — and if you **rename** the bundle before building (e.g. `APP_NAME=MeetingTrayTest make install`), the tray suddenly works. That's the telltale sign of **stale Launch Services registrations** for `com.proximeeting.app`, usually left behind by interrupted Homebrew cask upgrades (directories like `/usr/local/Caskroom/proximeeting/1.3.x.upgrading/` that no longer exist). macOS resolves the bundle id to one of those ghost rows, finds it flagged `launch-disabled`, and silently no-ops.

The one-liner recovery is:

```bash
make reset && make install
```

**What `make reset` removes** (nuclear — irreversible):

- All on-disk copies: `/Applications/ProxiMeeting.app`, `~/Applications/ProxiMeeting.app`, and the repo-local build artifact (plus the `MeetingTrayTest` diagnostic sibling if present).
- Stale Launch Services rows for `com.proximeeting.app` and `com.proximeeting.app.traytest` (via per-path `lsregister -u` followed by `lsregister -gc`).
- Per-bundle-id state under `~/Library`: `Containers/`, `Group Containers/`, `Preferences/`, `Caches/`, `HTTPStorages/`, `Saved Application State/`, `WebKit/`, `Application Support/`, and cookie stores.
- **Calendar and AddressBook TCC grants** for those bundle ids — macOS will re-prompt for calendar access the next time the app launches.
- Restarts Dock (~1 s flicker) to reload its Launch Services icon cache. Does **not** touch `cfprefsd` or any unrelated app's preferences.

**Before destroying anything**, the script prints the detected ghost rows and the exact list of paths it will remove, then asks `Continue? [y/N]`. Pass `--yes` (or set `PROXIMEETING_RESET_YES=1`) to skip the prompt in scripts/CI.

A diagnostic before/after snapshot is written to `/tmp/proximeeting-reset-<epoch>.log` — if reset-plus-install doesn't fix your tray, attach that file when reporting the issue.

If `make reset` finishes with `Reset INCOMPLETE` (exit code 1), either a ghost row survived `lsregister -gc` or a path needed `sudo`. The final banner prints the exact next command (`lsregister -delete` + reboot, or a specific `sudo rm -rf`).

## Project Structure

```
ProxiMeeting/
├── build.sh                        # Build with swiftc (no Xcode needed)
├── setup.sh                        # Generate xcodeproj with xcodegen and open
├── project.yml                     # xcodegen config
└── ProxiMeeting/
    ├── ProxiMeetingApp.swift        # App entry point + menu bar label
    ├── CalendarManager.swift       # EventKit + video link detection
    ├── CalendarSelectionStore.swift # UserDefaults: which calendars to include
    ├── JoinPreferenceStore.swift   # UserDefaults: App vs browser per service
    ├── MeetingMenuView.swift       # Popup UI
    ├── Info.plist                  # Calendar permission descriptions
    ├── ProxiMeeting.entitlements    # Sandbox + calendar entitlements
    ├── en.lproj/
    │   └── Localizable.strings
    └── zh-Hant.lproj/
        ├── Localizable.strings
        └── InfoPlist.strings
```

## Supported Video Conferencing Services

| Service         | Domain                |
| --------------- | --------------------- |
| Zoom            | `zoom.us`             |
| Google Meet     | `meet.google.com`     |
| Microsoft Teams | `teams.microsoft.com` |
| Webex           | `webex.com`           |
| Whereby         | `whereby.com`         |

Links are detected from the event URL, notes, and location fields.

**Join behavior:** Use **Settings** to set each listed provider to **App** (default) or **Browser**. **Browser** always opens a web-safe HTTPS link in your default browser and closes the panel first. **App** asks macOS to open the original URL; if no handler is installed, it closes the panel and falls back to the same HTTPS mapping as before (`zoommtg://` → `https://zoom.us/j/…`, `gmeet://` → Meet web, Teams/Meet hosts normalized to `https`, etc.). Links that are not matched to those providers always use the **Browser** path. Preferences are stored in UserDefaults.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes, build locally, and open pull requests.

## Adding a New Language

1. Create `ProxiMeeting/<locale>.lproj/Localizable.strings`
2. Copy keys from `en.lproj/Localizable.strings` and translate the values
3. Add the locale string to `CFBundleLocalizations` in `Info.plist`
4. Add the lproj path to `resources` in `project.yml` and re-run `./setup.sh`
