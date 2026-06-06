# Default matches releases / Homebrew. Local diagnostic name: APP_NAME=MeetingTrayTest make install
# (uses bundle id com.proximeeting.app.traytest so it can run alongside the shipped app and show its own menu bar item)
APP_NAME ?= ProxiMeeting
ifeq ($(APP_NAME),ProxiMeeting)
BUNDLE_ID := com.proximeeting.app
else
BUNDLE_ID := com.proximeeting.app.traytest
endif
APP       := $(APP_NAME).app
SRC       := ProxiMeeting
INSTALL_DIR ?= /Applications

SDK       := $(shell xcrun --show-sdk-path --sdk macosx)
ARCH      := $(shell uname -m)
TARGET    := $(ARCH)-apple-macos13.0

SWIFT_SRCS := \
	$(SRC)/CalendarSelectionStore.swift \
	$(SRC)/CalendarManager.swift \
	$(SRC)/JoinPreferenceStore.swift \
	$(SRC)/AppearanceStore.swift \
	$(SRC)/AppDebug.swift \
	$(SRC)/MeetingMenuView.swift \
	$(SRC)/ProxiMeetingApp.swift \
	$(SRC)/String+HalfwidthPrefix.swift \
	$(SRC)/UpdateChecker.swift

.PHONY: all build sync-app-version setup clean install reset

all: build

## Sync CFBundleShortVersionString and CFBundleVersion from package.json into ProxiMeeting/Info.plist
sync-app-version:
	@bash scripts/sync-info-plist-version.sh

## Build the .app bundle
build: sync-app-version
	@echo "==> Cleaning previous build..."
	@rm -rf "$(APP)"
	@echo "==> Creating .app bundle structure..."
	@mkdir -p "$(APP)/Contents/MacOS"
	@mkdir -p "$(APP)/Contents/Resources"
	@echo "==> Compiling Swift sources..."
	swiftc \
		-sdk "$(SDK)" \
		-target "$(TARGET)" \
		-parse-as-library \
		-framework SwiftUI \
		-framework AppKit \
		-framework EventKit \
		-O \
		$(SWIFT_SRCS) \
		-o "$(APP)/Contents/MacOS/$(APP_NAME)"
	@echo "==> Copying resources..."
	@sed \
		-e "s/\$$(PRODUCT_BUNDLE_IDENTIFIER)/$(BUNDLE_ID)/g" \
		-e "s/\$$(EXECUTABLE_NAME)/$(APP_NAME)/g" \
		-e "s/\$$(PRODUCT_NAME)/$(APP_NAME)/g" \
		-e "s/\$$(DEVELOPMENT_LANGUAGE)/en/g" \
		"$(SRC)/Info.plist" > "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@cp -r "$(SRC)/en.lproj"       "$(APP)/Contents/Resources/"
	@cp -r "$(SRC)/zh-Hant.lproj"  "$(APP)/Contents/Resources/"
	@echo "==> App icon: packing AppIcon.icns from Assets.xcassets..."
	@ASSET="$(SRC)/Assets.xcassets/AppIcon.appiconset"; \
	if [ -f "$$ASSET/Contents.json" ]; then \
		WORK=$$(mktemp -d); \
		mkdir -p "$$WORK/AppIcon.iconset"; \
		cp "$$ASSET"/icon_*.png "$$WORK/AppIcon.iconset/"; \
		if ! iconutil -c icns "$$WORK/AppIcon.iconset" -o "$(APP)/Contents/Resources/AppIcon.icns"; then \
			echo "Warning: failed to pack AppIcon.icns (iconutil). Continuing without custom icon."; \
		fi; \
		rm -rf "$$WORK"; \
	else \
		echo "Warning: missing $$ASSET — restore ProxiMeeting/Assets.xcassets/AppIcon.appiconset from the repo."; \
	fi
	@if [ "$(APP_NAME)" != "ProxiMeeting" ]; then \
		echo "==> Alternate build: stripping URL scheme (avoid duplicate proximeeting:// handlers with shipped app)."; \
		/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$(APP)/Contents/Info.plist" 2>/dev/null || true; \
	fi
	@echo "==> Signing (ad-hoc)..."
	@tmp=$$(mktemp); \
	plutil -convert xml1 -o "$$tmp" "$(SRC)/ProxiMeeting.entitlements"; \
	codesign --force --deep --sign - --entitlements "$$tmp" "$(APP)"; \
	rm -f "$$tmp"
	@echo ""
	@echo "Build complete: ./$(APP)"

## Install to /Applications, kill any running instance, and relaunch
install: build
	@set -eu; \
	dest="$(INSTALL_DIR)"; \
	if [ ! -w "$$dest" ]; then \
		dest="$$HOME/Applications"; \
		mkdir -p "$$dest"; \
		echo "==> $(INSTALL_DIR) not writable; installing to $$dest instead."; \
	else \
		echo "==> Installing into $$dest ..."; \
	fi; \
	pkill -x "$(APP_NAME)" 2>/dev/null || true; \
	pkill -x ProxiMeeting 2>/dev/null || true; \
	pkill -x MeetingTrayTest 2>/dev/null || true; \
	install_path="$$dest/$(APP)"; \
	rm -rf "$$install_path"; \
	ditto "$$(pwd)/$(APP)" "$$install_path" || { echo >&2 "==> ditto failed (try closing all ProxiMeeting variants, or sudo if dest is locked): $$install_path"; exit 1; }; \
	echo "==> Installed: $$install_path"; \
	open "$$install_path" || { echo >&2 "==> open failed for $$install_path (check Gatekeeper / Full Disk Access)."; exit 1; }; \
	echo "==> Launched $$(basename "$$install_path")."

## Generate Xcode project via xcodegen (for IDE use)
setup:
	@echo "==> Checking for xcodegen..."
	@command -v xcodegen > /dev/null 2>&1 || brew install xcodegen
	@echo "==> Generating Xcode project..."
	xcodegen generate
	open ProxiMeeting.xcodeproj

## Remove build artifacts
clean:
	@echo "==> Cleaning..."
	rm -rf "$(APP)"
	rm -rf ProxiMeeting.app MeetingTrayTest.app
	@echo "==> Clearing cached update state (UserDefaults)..."
	@defaults delete "$(BUNDLE_ID)" updates.availableVersion 2>/dev/null || true
	@defaults delete "$(BUNDLE_ID)" updates.availableDownloadURL 2>/dev/null || true
	@defaults delete "$(BUNDLE_ID)" updates.lastUpdateCheckDate 2>/dev/null || true
	@echo "Done."

## Nuclear environment reset: remove all installs, purge Launch Services via lsregister -gc + -u, wipe ~/Library state, reset Calendar/AddressBook TCC for com.proximeeting.app(.traytest). Prompts for confirmation unless --yes / PROXIMEETING_RESET_YES=1.
reset:
	@bash scripts/reset-environment.sh
