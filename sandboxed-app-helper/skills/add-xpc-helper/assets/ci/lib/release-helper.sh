#!/bin/bash
#
# release-helper.sh — release path for the Developer ID helper ({{HELPER_BUNDLE_ID}}).
# Sourced by ci_post_xcodebuild.sh; not executed directly.
#
# Exports a Developer ID copy from the archive, notarizes + staples it, and publishes the stapled zip
# plus a versions.json manifest as GitHub Release assets — the download channel the app fetches from.
#
# Expects: MARKETING_VERSION, CI_BUILD_NUMBER, CI_ARCHIVE_PATH, WORK_DIR, CI_PRIMARY_REPOSITORY_PATH,
# require_var, and the github.sh helpers, with github_init already called.
#
# Requires these secrets for notarytool (App Store Connect API key — CI has no keychain profile):
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64
# ...and for Developer ID signing (Xcode Cloud managed signing provides no such certificate):
#   DEVELOPER_ID_CERT_P12_BASE64  — base64 of a .p12 holding the Developer ID Application cert AND
#                                   its private key
#   DEVELOPER_ID_CERT_PASSWORD    — the .p12 export password
#
# Validate the .p12 locally with scripts/validate-developer-id-p12.sh before uploading it.

# The Apple certificates the Developer ID chain validates against. A clean CI keychain often lacks
# the intermediate, which makes a correctly-imported identity show as *invalid* — so install these
# before concluding the identity is unusable. Both CA generations are covered.
DEVELOPER_ID_CA_URLS=(
  "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
  "https://www.apple.com/certificateauthority/DeveloperIDCA.cer"
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer"
)

# install_apple_intermediates <keychain>: import the Developer ID CA chain so leaf validity can be
# evaluated.
install_apple_intermediates() {
  local keychain="$1" url tmp
  for url in "${DEVELOPER_ID_CA_URLS[@]}"; do
    tmp="$WORK_DIR/$(basename "$url")"
    if curl -fsS -o "$tmp" "$url"; then
      security import "$tmp" -k "$keychain" -T /usr/bin/codesign 2>/dev/null || true
    else
      echo "WARNING: could not download intermediate $url" >&2
    fi
  done
}

# import_developer_id_certificate: load the Developer ID Application identity into a throwaway
# keychain so exportArchive can sign for Developer ID.
#
# This must run here, not in ci_post_clone.sh: Xcode Cloud does not share keychains created by an
# earlier build script.
import_developer_id_certificate() {
  local keychain="$WORK_DIR/helper-signing.keychain-db"
  # A strong password for a keychain created, used and deleted within this job — not $RANDOM, which
  # is time/PID seeded.
  local keychain_password
  keychain_password=$(openssl rand -hex 24)
  local cert_path="$WORK_DIR/developer-id.p12"

  # Tolerate any line wrapping the CI console may have introduced, then confirm we got bytes.
  printf '%s' "$DEVELOPER_ID_CERT_P12_BASE64" | tr -d '[:space:]' | base64 --decode > "$cert_path"
  if [[ ! -s "$cert_path" ]]; then
    echo "ERROR: DEVELOPER_ID_CERT_P12_BASE64 did not decode to any data — check the secret is the" >&2
    echo "       base64 of the .p12 (e.g. \`base64 -i cert.p12\`)." >&2
    exit 1
  fi

  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"   # auto-lock after 6h
  security unlock-keychain -p "$keychain_password" "$keychain"

  # A non-zero exit here means a wrong password or a file that isn't a valid PKCS#12 — distinct from
  # "imported but no identity", which is diagnosed below.
  if ! security import "$cert_path" -k "$keychain" -P "$DEVELOPER_ID_CERT_PASSWORD" \
      -T /usr/bin/codesign -T /usr/bin/productsign; then
    echo "ERROR: 'security import' failed — DEVELOPER_ID_CERT_PASSWORD is wrong, or" >&2
    echo "       DEVELOPER_ID_CERT_P12_BASE64 is not a valid .p12." >&2
    exit 1
  fi
  # Let codesign use the private key without an interactive prompt.
  security set-key-partition-list -S apple-tool:,apple: \
    -k "$keychain_password" "$keychain" >/dev/null
  # Put the keychain on the user search list so xcodebuild finds the identity.
  local existing
  existing=$(security list-keychains -d user | sed 's/[[:space:]]*"//g;s/"//g')
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$keychain" $existing

  # Delete the keychain (which also drops it from the search list) alongside the WORK_DIR cleanup.
  trap 'security delete-keychain "'"$keychain"'" 2>/dev/null || true; rm -rf "'"$WORK_DIR"'"' EXIT

  # Diagnose. `-v` lists only *valid* identities; without it, identities that are present but
  # untrusted or expired still show. Comparing the two says exactly why signing would fail.
  echo "Code-signing identities present in the CI keychain:"
  security find-identity -p codesigning "$keychain" || true

  if ! security find-identity -p codesigning "$keychain" | grep -q "Developer ID Application"; then
    echo "ERROR: the .p12 imported but contains no Developer ID Application identity." >&2
    echo "       This is almost always a .p12 exported WITHOUT its private key. In Keychain Access," >&2
    echo "       select the *private key* (the certificate nests under it) and export that." >&2
    exit 1
  fi

  if ! security find-identity -v -p codesigning "$keychain" | grep -q "Developer ID Application"; then
    echo "Identity present but not yet valid; installing Apple's Developer ID CA chain…"
    install_apple_intermediates "$keychain"
  fi

  if ! security find-identity -v -p codesigning "$keychain" | grep -q "Developer ID Application"; then
    echo "ERROR: no VALID 'Developer ID Application' identity even after installing Apple's" >&2
    echo "       intermediates. The certificate is likely expired or revoked." >&2
    exit 1
  fi

  # Publish the keychain and the identity's SHA-1 (unambiguous, unlike a name) for the re-sign.
  SIGNING_KEYCHAIN="$keychain"
  DEVELOPER_ID_SHA1=$(security find-identity -v -p codesigning "$keychain" \
    | awk '/Developer ID Application/ {print $2; exit}')
  echo "Developer ID Application identity is present and valid ($DEVELOPER_ID_SHA1)."
}

# runtime_flag_present <app>: true iff the main bundle's CodeDirectory carries the Hardened Runtime
# flag (CS_RUNTIME = 0x10000).
#
# Bit-tests the hex flags word rather than matching the parenthetical text (e.g. "(runtime)"): the
# wording and the verbosity level at which the flags line appears both vary across codesign builds,
# which produced false negatives on the Xcode Cloud toolchain.
runtime_flag_present() {
  local flags
  flags=$(codesign -dvvv "$1" 2>&1 \
    | sed -n 's/.*flags=\(0x[0-9A-Fa-f]*\).*/\1/p' | head -n1)
  [[ -n "$flags" ]] && (( (flags & 0x10000) != 0 ))
}

# resign_with_hardened_runtime <app>: re-sign for Developer ID WITH the Hardened Runtime and a secure
# timestamp.
#
# ENABLE_HARDENED_RUNTIME=YES is set on the target, but `xcodebuild -exportArchive` with *manual*
# signing does not apply the flag the way the Organizer's automatic Developer ID export does — and
# notarization requires it on every Mach-O in the bundle. One `--deep` pass stamps every nested
# Mach-O inside-out (more reliable than a hand-rolled `find` walk, which can sign a framework before
# the dylibs inside it); entitlements are then reapplied to the outer bundle only, because a deep
# sign would push them onto nested code too.
resign_with_hardened_runtime() {
  local app="$1"

  local ent="$WORK_DIR/helper.entitlements.plist"
  local have_ent=false
  if codesign -d --entitlements ":$ent" "$app" 2>/dev/null && [[ -s "$ent" ]]; then
    have_ent=true
  fi

  codesign --force --deep --timestamp --options runtime \
    --keychain "$SIGNING_KEYCHAIN" --sign "$DEVELOPER_ID_SHA1" "$app"

  if $have_ent; then
    codesign --force --timestamp --options runtime --entitlements "$ent" \
      --keychain "$SIGNING_KEYCHAIN" --sign "$DEVELOPER_ID_SHA1" "$app"
  fi
}

publish_helper_release() {
  require_var ASC_API_KEY_ID
  require_var ASC_API_ISSUER_ID
  require_var ASC_API_KEY_P8_BASE64
  require_var DEVELOPER_ID_CERT_P12_BASE64
  require_var DEVELOPER_ID_CERT_PASSWORD

  # Tag format: <version>-<build>-helper. The trailing suffix keeps helper tags from colliding with
  # the app's own release tags in the same repository.
  local tag="${MARKETING_VERSION}-${CI_BUILD_NUMBER}-helper"
  local zip_name="{{HELPER_NAME}}-${MARKETING_VERSION}.zip"
  echo "Helper archive detected. Preparing $tag for $REPO."

  # 1. Export a Developer ID-signed copy from the archive.
  import_developer_id_certificate
  local export_dir="$WORK_DIR/export"
  xcodebuild -exportArchive \
    -archivePath "$CI_ARCHIVE_PATH" \
    -exportOptionsPlist "$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/ExportOptions-Helper.plist" \
    -exportPath "$export_dir"

  local app_path="$export_dir/{{HELPER_NAME}}.app"
  if [[ ! -d "$app_path" ]]; then
    echo "ERROR: exported app not found at $app_path" >&2
    exit 1
  fi

  echo "Signature as exported (before re-sign):"
  codesign -dvvv "$app_path" 2>&1 || true
  if runtime_flag_present "$app_path"; then
    echo "Exported app already carries the Hardened Runtime."
  else
    echo "Exported app lacks the Hardened Runtime; the re-sign below must add it."
  fi

  echo "Re-signing the exported app for Developer ID with the Hardened Runtime…"
  resign_with_hardened_runtime "$app_path"

  echo "Signature after re-sign:"
  codesign -dvvv "$app_path" 2>&1 || true
  if ! runtime_flag_present "$app_path"; then
    echo "ERROR: $app_path is still not signed with the Hardened Runtime after re-sign." >&2
    exit 1
  fi

  # 2. Reconstitute the App Store Connect API key and notarize.
  local key_path="$WORK_DIR/AuthKey.p8"
  printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$key_path"

  local zip_path="$WORK_DIR/$zip_name"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

  echo "Submitting to the Apple notary service (waits for the verdict)…"
  xcrun notarytool submit "$zip_path" \
    --key "$key_path" \
    --key-id "$ASC_API_KEY_ID" \
    --issuer "$ASC_API_ISSUER_ID" \
    --wait

  # 3. Staple the ticket into the .app, then re-zip so the archive carries it and verifies offline.
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

  # 4. Publish the stapled zip + manifest as GitHub Release assets.
  local release_id
  if tag_exists "$tag"; then
    local rel="$WORK_DIR/existing.json"
    curl -sS -o "$rel" "${AUTH_HEADERS[@]}" "$API/releases/tags/$tag"
    release_id=$(json_field "$rel" "id")
    echo "Reusing existing release $tag (id $release_id)."
  else
    release_id=$(create_release "$tag" "$tag" false)
    echo "Created GitHub release $tag (id $release_id)."
  fi

  local archive_url="https://github.com/$REPO/releases/download/$tag/$zip_name"

  # 5. Build the versions.json manifest the app decodes as an array of HelperVersion.
  #
  #    Order doesn't matter — the app selects the highest *supported* entry, not the first. `size`
  #    and `sha256` are hard-required by the app and must describe the FINAL, stapled zip, so they
  #    are computed after stapling. `minimumSystemVersion` comes from the exported app's own OS
  #    floor; `minimumAppVersion` is the helper's marketing version, since app and helper ship
  #    together. Publishing a single-entry array replaces the manifest each release; to keep older
  #    entries, fetch and merge the existing versions.json before writing.
  local release_date archive_size archive_sha min_system_version
  release_date=$(date -u +%Y-%m-%d)
  archive_size=$(stat -f%z "$zip_path")
  archive_sha=$(shasum -a 256 "$zip_path" | awk '{print $1}')
  min_system_version=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
    "$app_path/Contents/Info.plist")

  # Built with python3 rather than a heredoc so a value containing a quote or backslash can't corrupt
  # the JSON, and `size` is emitted as a real number rather than a string.
  local manifest="$WORK_DIR/versions.json"
  /usr/bin/python3 -c '
import json, sys
version, build, release_date, min_system, url, size, sha, out = sys.argv[1:9]
json.dump(
    [
        {
            "version": version,
            "build": build,
            "releaseDate": release_date,
            "minimumSystemVersion": min_system,
            "minimumAppVersion": version,
            "url": url,
            "size": int(size),
            "sha256": sha,
            "notes": "",
        }
    ],
    open(out, "w"),
    indent=2,
)' "$MARKETING_VERSION" "$CI_BUILD_NUMBER" "$release_date" "$min_system_version" \
    "$archive_url" "$archive_size" "$archive_sha" "$manifest"

  upload_asset "$release_id" "$zip_path" "$zip_name" "application/zip"
  upload_asset "$release_id" "$manifest" "versions.json" "application/json"

  echo "Helper $MARKETING_VERSION published."
  echo "  archive:  $archive_url"
  echo "  manifest: https://github.com/$REPO/releases/download/$tag/versions.json"
}
