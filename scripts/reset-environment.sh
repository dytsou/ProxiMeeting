#!/usr/bin/env bash
# Nuclear environment reset for ProxiMeeting.
#
# Removes every on-disk copy of ProxiMeeting and its local diagnostic sibling,
# purges stale Launch Services registrations (per-path -u + -gc), wipes
# per-bundle-id state under ~/Library, resets Calendar/AddressBook TCC, and
# restarts Dock. Writes a before/after lsregister snapshot to /tmp so reset
# failures have a diagnostic breadcrumb.
#
# Scope is hardcoded: the script does NOT accept BUNDLE_IDS / APP_NAMES
# overrides from the environment. Accepting them would let an invoker redirect
# rm -rf / tccutil reset / mdfind at arbitrary bundles, falsifying the plan's
# "other apps are untouched" guarantee.
#
# Exit codes:
#   0   Reset completed; no residual ghost rows; all target paths removed.
#   1   Purge did not converge (ghost rows still present) or some path could
#       not be removed without sudo. Final banner points at the documented
#       lsregister -delete + reboot fallback.
#
# Flags:
#   --yes / -y                  Skip the interactive "Continue?" preflight prompt.
#   PROXIMEETING_RESET_YES=1     Same as --yes (for automation / CI contexts).
#
# Maintenance hazard: `lsregister` has already lost its `-kill` option on
# current macOS releases. If Apple moves the binary or further changes flags,
# start by re-reading `lsregister -h` and comparing against the step 5/6 calls
# here.

set -euo pipefail
shopt -s nullglob

readonly BUNDLE_IDS=(com.proximeeting.app com.proximeeting.app.traytest)
readonly APP_NAMES=(ProxiMeeting MeetingTrayTest)

readonly LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
readonly LOG=/tmp/proximeeting-reset-$(date +%s).log

YES=0
if [[ "${PROXIMEETING_RESET_YES:-0}" = "1" ]]; then
	YES=1
fi
for arg in "$@"; do
	case "$arg" in
		--yes|-y) YES=1 ;;
		*) echo "reset-environment: unknown argument: $arg" >&2; exit 2 ;;
	esac
done

FAILED_PATHS=()
SIP_PROTECTED_PATHS=()

lsdump_filtered() {
	# Prints lsregister rows whose nearby text mentions any of our bundle ids.
	# Using `|| true` because rg exits 1 when the pattern doesn't match
	# (expected after a successful purge).
	"$LSREG" -dump 2>/dev/null | rg -B1 -A18 'com\.proximeeting\.app(\.[a-z]+)?' || true
}

count_ghost_rows() {
	# A "ghost" row is one whose resolved bundle path is gone from disk,
	# identifiable by the exact marker lsregister emits for such rows.
	# Informational only — ghosts without `launch-disabled` don't break
	# routing because LS marks them unresolvable.
	lsdump_filtered | rg -c 'Bundle node not found on disk' || true
}

count_blocking_rows() {
	# Counts ProxiMeeting-namespace rows that could actually mis-route a
	# `com.proximeeting.app` binding:
	#   - flagged `launch-disabled`
	#   - NOT in the user's .Trash (LS excludes trash rows from routing)
	# These are the rows whose presence is the bug we're trying to fix.
	"$LSREG" -dump 2>/dev/null \
		| rg -B4 'launch-disabled' \
		| rg -B1 'path:[[:space:]]*.*com\.proximeeting\.app|path:[[:space:]]*.*ProxiMeeting\.app' \
		| rg -v '/\.Trash/' \
		| rg -c 'launch-disabled' || true
}

safe_rm() {
	local p="$1"
	if [[ ! -e "$p" && ! -L "$p" ]]; then
		return 0
	fi
	# Strip macOS container/sandbox xattrs where possible. xattr -cr no-ops
	# on paths with no xattrs and fails (silently) on paths holding the
	# com.apple.rootless kernel-enforced xattr, which cannot be stripped
	# without SIP disabled.
	xattr -cr -- "$p" 2>/dev/null || true
	local err
	err="$(rm -rf -- "$p" 2>&1)" || true
	if [[ ! -e "$p" && ! -L "$p" ]]; then
		echo "  removed $p"
		return 0
	fi
	# Classify the failure: Container dirs for our bundle ids hold a
	# com.apple.rootless-protected containermanagerd.metadata.plist that
	# even the file's owner cannot delete. Our ad-hoc build is NOT
	# sandboxed, so a surviving Container holds no live state and does not
	# affect Launch Services routing or tray visibility. Treat these as a
	# benign "cannot fix, does not block the fix" class.
	if [[ "$p" == "$HOME/Library/Containers/"* ]] && printf '%s\n' "$err" | rg -q 'containermanagerd\.metadata\.plist.*Operation not permitted'; then
		echo "  WARN: $p is SIP-protected (com.apple.rootless on containermanagerd.metadata.plist); harmless for ad-hoc builds, leaving in place"
		SIP_PROTECTED_PATHS+=("$p")
	else
		echo "  WARN: could not remove $p${err:+ ($err)}" >&2
		FAILED_PATHS+=("$p")
	fi
}

# ---------------------------------------------------------------------------
# Step 0 — pre-snapshot
# ---------------------------------------------------------------------------
echo "==> [0/12] Capturing pre-reset lsregister snapshot to $LOG"
{
	printf '==== ProxiMeeting reset log — %s ====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf 'scope:\n'
	for bid in "${BUNDLE_IDS[@]}"; do printf '  bundle_id: %s\n' "$bid"; done
	for name in "${APP_NAMES[@]}"; do printf '  app_name:  %s\n' "$name"; done
	printf '\n---- BEFORE ----\n'
	lsdump_filtered
	printf '\n'
} >"$LOG"

GHOSTS_BEFORE="$(count_ghost_rows)"
: "${GHOSTS_BEFORE:=0}"

# ---------------------------------------------------------------------------
# Step 1 — destructiveness banner
# ---------------------------------------------------------------------------
echo "==> [1/12] About to nuke local ProxiMeeting environment"
echo "    - Detected ghost lsregister rows (bundle path missing): $GHOSTS_BEFORE"
echo "    - Processes to terminate:          ${APP_NAMES[*]}"
echo "    - /Applications/ & ~/Applications/ copies for: ${APP_NAMES[*]}"
echo "    - ~/Library state wipe for:        ${BUNDLE_IDS[*]}"
echo "    - TCC resets (Calendar,AddressBook) for: ${BUNDLE_IDS[*]}"
echo "    - Dock will restart (<1s flicker). cfprefsd is NOT touched."
echo "    - Diagnostic snapshot:             $LOG"

# ---------------------------------------------------------------------------
# Step 2 — preflight confirmation
# ---------------------------------------------------------------------------
if [[ "$YES" -ne 1 ]]; then
	read -r -p "==> [2/12] Continue? [y/N] " reply
	case "${reply:-}" in
		[yY]|[yY][eE][sS]) ;;
		*)
			echo "==> Aborted by user. Nothing was changed. Snapshot only: $LOG"
			exit 0
			;;
	esac
else
	echo "==> [2/12] Preflight auto-confirmed (--yes / PROXIMEETING_RESET_YES=1)"
fi

# ---------------------------------------------------------------------------
# Step 3 — pkill
# ---------------------------------------------------------------------------
echo "==> [3/12] Terminating running instances"
for name in "${APP_NAMES[@]}"; do
	if pkill -x "$name" 2>/dev/null; then
		echo "  terminated: $name"
	fi
done

# ---------------------------------------------------------------------------
# Step 4 — per-path lsregister -u (BEFORE removing bundles, so the paths still
# exist on disk and `lsregister -u` can successfully unregister them).
# ---------------------------------------------------------------------------
echo "==> [4/12] Unregistering live Launch Services rows (lsregister -u)"
for bid in "${BUNDLE_IDS[@]}"; do
	# mdfind returns zero hits on an unindexed system; tolerate that.
	hits="$(mdfind "kMDItemCFBundleIdentifier == '$bid'" 2>/dev/null || true)"
	if [[ -n "$hits" ]]; then
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			"$LSREG" -u "$path" >/dev/null 2>&1 || true
			echo "  unregistered: $path"
		done <<<"$hits"
	fi
done

# ---------------------------------------------------------------------------
# Step 5 — remove on-disk app bundles
# ---------------------------------------------------------------------------
echo "==> [5/12] Removing on-disk .app bundles"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for name in "${APP_NAMES[@]}"; do
	safe_rm "/Applications/$name.app"
	safe_rm "$HOME/Applications/$name.app"
	safe_rm "$ROOT/$name.app"
done

# ---------------------------------------------------------------------------
# Step 6 — lsregister -gc (garbage-collect orphan rows)
# ---------------------------------------------------------------------------
echo "==> [6/12] Garbage-collecting stale Launch Services rows (lsregister -gc)"
if "$LSREG" -gc >/dev/null 2>&1; then
	echo "  lsregister -gc OK"
else
	echo "  WARN: lsregister -gc returned non-zero (the purge-convergence check will catch residual rows)" >&2
fi

# ---------------------------------------------------------------------------
# Step 7 — wipe ~/Library state
# ---------------------------------------------------------------------------
echo "==> [7/12] Wiping per-bundle-id ~/Library state"
for bid in "${BUNDLE_IDS[@]}"; do
	safe_rm "$HOME/Library/Containers/$bid"
	for p in "$HOME/Library/Group Containers/"*.$bid; do safe_rm "$p"; done
	safe_rm "$HOME/Library/Preferences/$bid.plist"
	for p in "$HOME/Library/Preferences/ByHost/$bid".*.plist; do safe_rm "$p"; done
	safe_rm "$HOME/Library/Caches/$bid"
	safe_rm "$HOME/Library/HTTPStorages/$bid"
	safe_rm "$HOME/Library/HTTPStorages/$bid.binarycookies"
	safe_rm "$HOME/Library/Saved Application State/$bid.savedState"
	safe_rm "$HOME/Library/WebKit/$bid"
	safe_rm "$HOME/Library/Application Support/$bid"
	safe_rm "$HOME/Library/Application Scripts/$bid"
	safe_rm "$HOME/Library/Cookies/$bid.binarycookies"
done

# ---------------------------------------------------------------------------
# Step 8 — tccutil reset (Calendar + AddressBook, with stderr triage)
# ---------------------------------------------------------------------------
echo "==> [8/12] Resetting Calendar & AddressBook TCC grants"
for bid in "${BUNDLE_IDS[@]}"; do
	for svc in Calendar AddressBook; do
		out="$(tccutil reset "$svc" "$bid" 2>&1)" && rc=0 || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			echo "  tccutil reset $svc $bid OK"
		else
			# Benign: no prior grant existed for this bundle.
			if printf '%s\n' "$out" | rg -q -i 'no such bundle identifier|not (registered|recognized)'; then
				echo "  tccutil reset $svc $bid (no prior grant)"
			else
				echo "  WARN: tccutil reset $svc $bid rc=$rc: $out" >&2
			fi
		fi
	done
done

# ---------------------------------------------------------------------------
# Step 9 — killall Dock (LS icon-cache reload). Deliberately NOT cfprefsd.
# ---------------------------------------------------------------------------
echo "==> [9/12] Restarting Dock (LS icon-cache reload)"
killall Dock 2>/dev/null || echo "  WARN: killall Dock returned non-zero (Dock will rehydrate on next click)" >&2

# ---------------------------------------------------------------------------
# Step 10 — post-snapshot
# ---------------------------------------------------------------------------
echo "==> [10/12] Capturing post-reset lsregister snapshot"
{
	printf '\n---- AFTER ----\n'
	lsdump_filtered
	printf '\n'
} >>"$LOG"

GHOSTS_AFTER="$(count_ghost_rows)"
: "${GHOSTS_AFTER:=0}"
BLOCKING_AFTER="$(count_blocking_rows)"
: "${BLOCKING_AFTER:=0}"

# ---------------------------------------------------------------------------
# Step 11 — purge-convergence check
# ---------------------------------------------------------------------------
echo "==> [11/12] Verifying purge convergence"
echo "  informational: 'Bundle node not found on disk' rows = $GHOSTS_AFTER (was $GHOSTS_BEFORE); these are benign and get deprioritized by LS."
CONVERGED=1
if [[ "$BLOCKING_AFTER" -gt 0 ]]; then
	CONVERGED=0
	echo "  BLOCKING: $BLOCKING_AFTER non-trash ProxiMeeting row(s) still flagged launch-disabled; LS may route to these" >&2
fi

if [[ "${#SIP_PROTECTED_PATHS[@]}" -gt 0 ]]; then
	echo ""
	echo "==> SIP_PROTECTED_PATHS (${#SIP_PROTECTED_PATHS[@]}) — cannot be removed without SIP disabled; harmless for ad-hoc builds:"
	for p in "${SIP_PROTECTED_PATHS[@]}"; do echo "    $p"; done
fi

if [[ "${#FAILED_PATHS[@]}" -gt 0 ]]; then
	echo ""
	echo "==> FAILED_PATHS (${#FAILED_PATHS[@]}) — not removable without sudo:" >&2
	for p in "${FAILED_PATHS[@]}"; do echo "    $p" >&2; done
fi

# ---------------------------------------------------------------------------
# Step 12 — final banner + exit code
# ---------------------------------------------------------------------------
echo ""
if [[ "$CONVERGED" -eq 1 && "${#FAILED_PATHS[@]}" -eq 0 ]]; then
	echo "==> [12/12] Reset complete. Diagnostic snapshot: $LOG"
	echo "==> Run 'make install' to reinstall a clean ProxiMeeting.app."
	exit 0
else
	echo "==> [12/12] Reset INCOMPLETE. Diagnostic snapshot: $LOG" >&2
	if [[ "$CONVERGED" -eq 0 ]]; then
		cat >&2 <<'EOF'

Fallback: a non-trash ProxiMeeting row is still flagged launch-disabled. Run
the nuclear fallback (requires reboot):

  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -delete
  sudo reboot

After reboot, re-run `make install` and the freshly-registered bundle should
be the only com.proximeeting.app row.
EOF
	fi
	if [[ "${#FAILED_PATHS[@]}" -gt 0 ]]; then
		cat >&2 <<EOF

Fallback: the paths above are root-owned (likely from a legacy sandboxed cask
install). Remove them with:

  sudo rm -rf ${FAILED_PATHS[*]@Q}

Then re-run \`make reset\`.
EOF
	fi
	exit 1
fi
