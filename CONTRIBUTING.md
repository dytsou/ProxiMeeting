# Contributing to ProxiMeeting

Thanks for your interest in improving ProxiMeeting. This document describes how to propose changes and what to check before opening a pull request.

## Before you start

- **Small fixes:** Typos, obvious bugs, and documentation tweaks can go straight to a PR with a clear description.

## Development setup

1. Clone the repository and open it locally.
2. Build the app using one of these paths (pick what matches your environment):
   - **`./build.sh`** — uses Xcode Command Line Tools and `swiftc` (no full Xcode required).
   - **`make build`** — same idea via the Makefile.
   - **`./setup.sh`** — generates `ProxiMeeting.xcodeproj` with xcodegen (Homebrew) and opens Xcode for GUI builds and signing.

See [README.md](README.md) for calendar setup and install steps.

## Making changes

- **Match existing style:** Follow naming, structure, and SwiftUI patterns already used in `ProxiMeeting/`.
- **Keep diffs focused:** One logical change per PR is easier to review than unrelated edits bundled together.
- **Localization:** If you add or change user-visible strings, update `en.lproj/Localizable.strings` and `zh-Hant.lproj/Localizable.strings`, and follow [README.md § Adding a New Language](README.md#adding-a-new-language) if you introduce a new locale.
- **Entitlements and privacy:** Changes that touch calendar access, sandbox, or `Info.plist` permission strings should be clearly explained in the PR.

## Verify your build

Before submitting:

```bash
./build.sh
```

Or, if you use Swift Package Manager:

```bash
swift build
```

If you use the Xcode project, build and run locally and exercise the menu bar UI and calendar permission flows as needed.

## Pull requests

1. Use a descriptive title and summary of **what** changed and **why**.
2. Reference any related issue (e.g. `Fixes #123`).
3. Note any behavior change for users (e.g. new setting, new video provider).

Maintainers will review as time allows. Constructive feedback on the PR is part of the process—adjustments are normal.

## Code of conduct

Be respectful and assume good intent. Keep discussion focused on the project and the change at hand.
