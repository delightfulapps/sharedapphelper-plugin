#!/bin/bash
#
# Xcode Cloud post-build hook (entry point). Runs after every `xcodebuild` action; acts only on
# post-merge *archive* builds of the default branch, then dispatches on which product was archived.
#
# Two products come out of one project, so the hook has to tell them apart — it reads the archived
# bundle identifier rather than the scheme name, which is the only thing guaranteed to be accurate.
#
#   {{HELPER_BUNDLE_ID}}  -> lib/release-helper.sh (export, notarize, staple, publish)
#   {{APP_BUNDLE_ID}}     -> add your app's own release path here, if it has one
#
# PR builds, non-archive actions, other branches, and any other product are skipped cleanly.
#
# Required env vars (set by Xcode Cloud unless noted):
#   GITHUB_ACCESS_TOKEN        — (secret) fine-grained PAT, Contents: Read & write
#   CI_XCODEBUILD_ACTION       — must be "archive"
#   CI_BRANCH                  — must be "main"
#   CI_PULL_REQUEST_NUMBER     — must be unset (post-merge, not a PR build)
#   CI_BUILD_NUMBER            — Xcode Cloud build counter
#   CI_COMMIT                  — commit SHA being built
#   CI_ARCHIVE_PATH            — path to the produced .xcarchive
#   CI_PRIMARY_REPOSITORY_PATH — checkout root
#
# The helper path additionally requires the secrets documented in lib/release-helper.sh.

set -euo pipefail

# --- Guards: skip cleanly when this isn't a post-merge archive of main. -----

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
  echo "Skipping: CI_XCODEBUILD_ACTION='${CI_XCODEBUILD_ACTION:-unset}', not 'archive'."
  exit 0
fi

if [[ "${CI_BRANCH:-}" != "main" ]]; then
  echo "Skipping: CI_BRANCH='${CI_BRANCH:-unset}', not 'main'."
  exit 0
fi

if [[ -n "${CI_PULL_REQUEST_NUMBER:-}" ]]; then
  echo "Skipping: PR build (#${CI_PULL_REQUEST_NUMBER}), not post-merge."
  exit 0
fi

# --- Required state past the guards. ----------------------------------------

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required env var '$name' is not set." >&2
    exit 1
  fi
}

require_var GITHUB_ACCESS_TOKEN
require_var CI_BUILD_NUMBER
require_var CI_COMMIT
require_var CI_ARCHIVE_PATH
require_var CI_PRIMARY_REPOSITORY_PATH

ARCHIVE_INFO="$CI_ARCHIVE_PATH/Info.plist"
if [[ ! -f "$ARCHIVE_INFO" ]]; then
  echo "ERROR: archive Info.plist not found at $ARCHIVE_INFO" >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :ApplicationProperties:$1" "$ARCHIVE_INFO"
}

BUNDLE_ID=$(plist_value "CFBundleIdentifier")
MARKETING_VERSION=$(plist_value "CFBundleShortVersionString")

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Load shared helpers and set up the GitHub API context. -----------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/github.sh
source "$SCRIPT_DIR/lib/github.sh"
github_init

# --- Dispatch on the archived product. --------------------------------------

case "$BUNDLE_ID" in
  {{HELPER_BUNDLE_ID}})
    # shellcheck source=lib/release-helper.sh
    source "$SCRIPT_DIR/lib/release-helper.sh"
    publish_helper_release
    ;;
  *)
    echo "Skipping: archived product '$BUNDLE_ID' has no release handler."
    exit 0
    ;;
esac
