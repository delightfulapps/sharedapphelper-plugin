#!/bin/bash
#
# apply-template.sh — copy a bundled template file or directory into a project, substituting the
# skill's placeholders.
#
# Every template in assets/ uses the same {{PLACEHOLDER}} convention, so doing this by hand for two
# dozen files is slow and easy to get subtly wrong (a missed {{SERVICE_NAME}} produces a helper that
# builds and then never connects).
#
# Usage:
#   scripts/apply-template.sh <source> <destination>
#
# Placeholder values come from the environment. All ten are required; the script refuses to write a
# file containing an unresolved placeholder.
#
#   APP_NAME HELPER_NAME APP_BUNDLE_ID HELPER_BUNDLE_ID SERVICE_NAME
#   TEAM_ID PACKAGE_NAME SYMBOL_PREFIX DISTRIBUTION_HOST DEPLOYMENT_TARGET
#
# Example:
#   APP_NAME=Aperture HELPER_NAME=ApertureHelper \
#   APP_BUNDLE_ID=co.example.aperture HELPER_BUNDLE_ID=co.example.aperture.helper \
#   SERVICE_NAME=co.example.aperture.HelperService TEAM_ID=ABCDE12345 \
#   PACKAGE_NAME=ApertureHelperKit SYMBOL_PREFIX=helperService \
#   DISTRIBUTION_HOST=helper.example.co DEPLOYMENT_TARGET=15.0 \
#   scripts/apply-template.sh assets/swift ../ApertureHelperKit
#
set -euo pipefail

SOURCE="${1:-}"
DEST="${2:-}"
if [[ -z "$SOURCE" || -z "$DEST" ]]; then
  echo "usage: $0 <source> <destination>" >&2
  exit 2
fi
if [[ ! -e "$SOURCE" ]]; then
  echo "error: no such template: $SOURCE" >&2
  exit 2
fi

VARS=(APP_NAME HELPER_NAME APP_BUNDLE_ID HELPER_BUNDLE_ID SERVICE_NAME
      TEAM_ID PACKAGE_NAME SYMBOL_PREFIX DISTRIBUTION_HOST DEPLOYMENT_TARGET)
missing=()
for var in "${VARS[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done
if (( ${#missing[@]} > 0 )); then
  echo "error: these placeholder values are not set: ${missing[*]}" >&2
  exit 2
fi

# Copy first, substitute in place afterwards — this keeps directory structure, permissions and the
# executable bit on scripts without reimplementing `cp`.
if [[ -d "$SOURCE" ]]; then
  mkdir -p "$DEST"
  /usr/bin/ditto "$SOURCE" "$DEST"
  TARGETS=$(find "$DEST" -type f)
else
  mkdir -p "$(dirname "$DEST")"
  cp "$SOURCE" "$DEST"
  TARGETS="$DEST"
fi

for file in $TARGETS; do
  # Skip anything that isn't text, so an asset catalog or icon passes through untouched.
  file "$file" | grep -qi "text\|empty\|json\|xml" || continue
  for var in "${VARS[@]}"; do
    value="${!var}"
    # `|` as the delimiter, since values may contain `/` (they never contain `|`).
    LC_ALL=C sed -i '' "s|{{${var}}}|${value}|g" "$file"
  done
done

# Refuse to leave a half-substituted file behind: an unresolved placeholder compiles in some files
# and silently breaks at runtime in others.
if leftover=$(grep -rl '{{[A-Z_]*}}' "$DEST" 2>/dev/null); then
  echo "error: unresolved placeholders remain in:" >&2
  echo "$leftover" >&2
  echo "       Add the missing variable to this script and re-run." >&2
  exit 1
fi

echo "Wrote $DEST"
