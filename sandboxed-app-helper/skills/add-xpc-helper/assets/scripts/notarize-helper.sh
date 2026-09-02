#!/bin/bash
#
# notarize-helper.sh — Notarize, staple, and verify the standalone {{HELPER_NAME}} app for
# Developer ID distribution.
#
# This script does NOT sign the app. Produce a Developer ID-signed, Hardened-Runtime app first,
# either via Xcode (Product > Archive > Distribute App > Developer ID) or `xcodebuild -exportArchive`
# with a Developer ID export options plist, then hand that .app to this script. Signing is separated
# out because getting it wrong is silent until notarization rejects the upload minutes later.
#
# One-time setup — store notary credentials in a keychain profile:
#   xcrun notarytool store-credentials {{HELPER_NAME}}-notary \
#     --apple-id "you@example.com" --team-id {{TEAM_ID}} \
#     --password "<app-specific-password>"
#
# Usage:
#   NOTARY_PROFILE={{HELPER_NAME}}-notary scripts/notarize-helper.sh build/{{HELPER_NAME}}.app
#
# Environment:
#   NOTARY_PROFILE   (required) the `notarytool store-credentials` profile name
#   DEVELOPER_ID     (optional) expected "Developer ID Application: …" authority, checked if set
#
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "error: pass the path to the signed .app (e.g. build/{{HELPER_NAME}}.app)" >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "error: no such app bundle: $APP" >&2
  exit 2
fi
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your 'notarytool store-credentials' profile name}"

echo "==> Verifying code signature (strict)"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Confirming the Hardened Runtime is enabled (required for notarization)"
if ! codesign --display --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "error: $APP is not signed with the Hardened Runtime (codesign --options runtime)" >&2
  exit 1
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  if ! codesign --display --verbose=2 "$APP" 2>&1 | grep -q "Authority=${DEVELOPER_ID}"; then
    echo "warning: signing authority does not match DEVELOPER_ID='${DEVELOPER_ID}'" >&2
  fi
fi

WORKDIR="$(cd "$(dirname "$APP")" && pwd)"
BASENAME="$(basename "${APP%.app}")"
ZIP="${WORKDIR}/${BASENAME}.zip"

echo "==> Packaging ${ZIP}"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to the Apple notary service (waits for the verdict)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the notarization ticket to the app"
xcrun stapler staple "$APP"

echo "==> Verifying the stapled app"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

# Re-zip the now-stapled app: the ticket lives inside the .app, so a stapled archive verifies on a
# machine with no network. The pre-staple zip does not.
echo "==> Re-packaging the stapled app for distribution"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done: ${APP} is notarized and stapled; distributable archive: ${ZIP}"
