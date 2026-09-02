#!/bin/bash
#
# unregister-helper.sh — Remove a development machine's installed {{HELPER_NAME}} and its launch
# agent registration, so the next launch registers cleanly.
#
# Use when a machine is stuck on a stale registration: the Mach service is listed as enabled but
# looking it up fails, and the app reports "Connection invalid". See references/troubleshooting.md.
#
set -euo pipefail

HELPER_BUNDLE_ID="{{HELPER_BUNDLE_ID}}"
SERVICE_NAME="{{SERVICE_NAME}}"
HELPER_NAME="{{HELPER_NAME}}"

echo "==> Quitting $HELPER_NAME if it is running"
osascript -e "tell application \"$HELPER_NAME\" to quit" 2>/dev/null || true
sleep 1

echo "==> Attempting launchctl bootout (expected to fail for a BTM-managed agent)"
# SMAppService registrations are managed by Background Task Management, so launchctl reports
# "Input/output error (5)". That failure is normal; the real removal is the app going away plus the
# defaults key below, or System Settings > General > Login Items.
launchctl bootout "gui/$(id -u)/$SERVICE_NAME" 2>/dev/null \
  || echo "    (bootout declined — this is expected; continuing)"

echo "==> Locating installed copies"
# Skip DerivedData so a build product isn't mistaken for an installation.
mdfind "kMDItemCFBundleIdentifier == '$HELPER_BUNDLE_ID'" 2>/dev/null \
  | grep -v DerivedData \
  | while read -r app; do
      echo "    found: $app"
      osascript -e "tell application \"Finder\" to delete POSIX file \"$app\"" >/dev/null 2>&1 \
        && echo "    moved to Trash" \
        || echo "    could not move to Trash — remove it manually"
    done

echo "==> Clearing the recorded registration build"
defaults delete "$HELPER_BUNDLE_ID" "LaunchAgentRegistration.lastRegisteredBuild" 2>/dev/null || true

echo
echo "==> Done. If the service is still listed, remove '$HELPER_NAME' from"
echo "    System Settings > General > Login Items & Extensions, then reinstall."
echo "    Verify with: launchctl print \"gui/\$(id -u)/$SERVICE_NAME\""
