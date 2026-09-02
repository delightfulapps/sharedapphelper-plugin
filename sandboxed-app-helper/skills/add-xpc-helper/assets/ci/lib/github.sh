#!/bin/bash
#
# github.sh — shared GitHub REST helpers for the release paths. Sourced by ci_post_xcodebuild.sh;
# not executed directly.
#
# Expects (from the entry script's environment): require_var, WORK_DIR, CI_COMMIT,
# CI_PRIMARY_REPOSITORY_PATH, GITHUB_ACCESS_TOKEN. Call `github_init` once before the other helpers.

# github_init: resolve REPO from the origin remote and build the API base URL and auth headers.
github_init() {
  local remote_url
  remote_url=$(git -C "$CI_PRIMARY_REPOSITORY_PATH" config --get remote.origin.url)
  REPO=$(printf '%s' "$remote_url" \
    | sed -E -e 's#^git@github\.com:##' -e 's#^https://github\.com/##' -e 's#\.git$##')

  if [[ -z "$REPO" || "$REPO" == "$remote_url" ]]; then
    echo "ERROR: could not parse owner/repo from remote URL '$remote_url'." >&2
    exit 1
  fi

  API="https://api.github.com/repos/$REPO"
  AUTH_HEADERS=(
    -H "Authorization: Bearer $GITHUB_ACCESS_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
}

# json_field <file> <key>: print a top-level field from a JSON response. Uses python3 (present on
# Xcode Cloud runners) to avoid a jq dependency.
json_field() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}

# tag_exists <tag>: 0 if the git tag ref already exists on the remote.
tag_exists() {
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    "${AUTH_HEADERS[@]}" "$API/git/ref/tags/$1")
  [[ "$code" == "200" ]]
}

# create_release <tag> <name> <generate_notes:true|false>: create a release at CI_COMMIT, echo its id.
create_release() {
  local tag="$1" name="$2" gen_notes="$3"
  local body="$WORK_DIR/release.json" payload="$WORK_DIR/release-request.json" code
  # Built with python3 rather than string interpolation so a tag or name containing a quote or
  # backslash can't corrupt or inject into the JSON.
  /usr/bin/python3 -c '
import json, sys
tag, commit, name, gen, out = sys.argv[1:6]
json.dump(
    {
        "tag_name": tag,
        "target_commitish": commit,
        "name": name,
        "generate_release_notes": gen == "true",
    },
    open(out, "w"),
)' "$tag" "$CI_COMMIT" "$name" "$gen_notes" "$payload"
  code=$(curl -sS -o "$body" -w "%{http_code}" -X POST "${AUTH_HEADERS[@]}" \
    --data-binary @"$payload" \
    "$API/releases")
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    echo "ERROR: GitHub release creation failed for '$tag' (HTTP $code)." >&2
    cat "$body" >&2
    exit 1
  fi
  json_field "$body" "id"
}

# upload_asset <release_id> <file> <name> <content_type>: (re)upload an asset, deleting any existing
# asset of the same name first so re-runs refresh it rather than failing.
upload_asset() {
  local release_id="$1" file="$2" name="$3" content_type="$4"
  local assets="$WORK_DIR/assets.json"

  curl -sS -o "$assets" "${AUTH_HEADERS[@]}" "$API/releases/$release_id/assets"
  local existing_id
  existing_id=$(/usr/bin/python3 -c '
import json,sys
data=json.load(open(sys.argv[1]))
name=sys.argv[2]
print(next((str(a["id"]) for a in data if a.get("name")==name), ""))' "$assets" "$name")
  if [[ -n "$existing_id" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH_HEADERS[@]}" \
      "$API/releases/assets/$existing_id"
  fi

  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTH_HEADERS[@]}" \
    -H "Content-Type: $content_type" \
    --data-binary @"$file" \
    "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=$name")
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    echo "ERROR: uploading asset '$name' failed (HTTP $code)." >&2
    exit 1
  fi
  echo "Uploaded asset '$name' to release $release_id."
}
