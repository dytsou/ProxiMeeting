#!/usr/bin/env bash
# Set CFBundleShortVersionString and CFBundleVersion in ProxiMeeting/Info.plist from package.json (single source of truth).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLIST="ProxiMeeting/Info.plist"
if [[ ! -f "$PLIST" ]]; then
	echo "sync-info-plist-version: missing $PLIST" >&2
	exit 1
fi

if command -v node &>/dev/null; then
	VERSION="$(node -p "require('./package.json').version")"
elif command -v python3 &>/dev/null; then
	VERSION="$(python3 -c "import json; print(json.load(open('package.json'))['version'])")"
else
	echo "sync-info-plist-version: need node or python3 to read package.json" >&2
	exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$PLIST"
echo "sync-info-plist-version: CFBundleShortVersionString & CFBundleVersion -> ${VERSION}"
