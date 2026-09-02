# Build configuration with xcconfig

Keep **all** build settings in `.xcconfig` files under `Config/`, with every `buildSettings` dict in
`project.pbxproj` left empty and a `baseConfigurationReference` pointing at the matching file. Settings
then live in plain text: reviewable in a diff, and free of the merge conflicts inline pbxproj settings
cause.

This matters more than usual here, because the helper's settings are the security boundary. `Sandbox
= NO` and `Hardened Runtime = YES` buried in a binary-ish project file are settings nobody reviews.

## Layout

```
Config/
  Base.xcconfig       # project-wide, identical in Debug and Release
  Debug.xcconfig      # #include "Base.xcconfig" + Debug-only project settings
  Release.xcconfig    # #include "Base.xcconfig" + Release-only project settings
  Version.xcconfig    # MARKETING_VERSION + CURRENT_PROJECT_VERSION
  {{APP_NAME}}.xcconfig
  {{HELPER_NAME}}.xcconfig
```

Two levels, mapping 1:1 onto Xcode's two configuration levels:

| Xcode build configuration | Attached xcconfig |
|---|---|
| Project **Debug** | `Debug.xcconfig` |
| Project **Release** | `Release.xcconfig` |
| `{{APP_NAME}}` target, Debug **and** Release | `{{APP_NAME}}.xcconfig` |
| `{{HELPER_NAME}}` target, Debug **and** Release | `{{HELPER_NAME}}.xcconfig` |

Attach one target file to both of that target's configurations unless the target genuinely varies by
configuration; the real Debug↔Release deltas (optimization, `DEBUG=1`, dSYM, assertions) belong in the
project-level files.

## Where a setting belongs

- Every target, never differs by configuration → `Base.xcconfig`.
- Every target, differs Debug vs Release → `Debug.xcconfig` / `Release.xcconfig`.
- One target → that target's file (bundle id, entitlements, sandbox and runtime flags, `SWIFT_VERSION`).
- Version numbers → `Version.xcconfig`, `#include`d by both target files.

**Do not have a per-target file `#include` `Debug.xcconfig` or `Release.xcconfig`.** Settings that use
`$(inherited)` — `GCC_PREPROCESSOR_DEFINITIONS`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`,
`LD_RUNPATH_SEARCH_PATHS` — would be applied twice and accumulate duplicates. Including a
settings-only file such as `Version.xcconfig`, which defines no `$(inherited)` lists, is fine.

## Version numbers move together

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live only in `Version.xcconfig`, which both target
files `#include`. The app and the helper have to ship the same version: the app compares its own
version against the installed helper's to decide whether an update is due, and CI derives the release
tag and the manifest's `minimumAppVersion` from the built product's version.

A per-target `MARKETING_VERSION` would silently override the include for that one product — which
looks like nothing at all until the app decides it needs an update it already has.

## Three rules that bite

1. **An inline pbxproj value overrides the xcconfig.** A setting only takes effect from the xcconfig
   if it is *absent* from the target's `buildSettings` dict. When a setting appears not to apply, look
   there first.
2. **`//` starts a comment.** A value containing `//` — a full URL — is silently truncated. Store the
   host alone and reconstruct the URL in code (see below), or the app ends up requesting `https:`.
3. **Editing `project.pbxproj` requires Xcode to be quit.** Attaching a new
   `baseConfigurationReference` is a pbxproj edit. Editing the *contents* of an existing `.xcconfig`
   is a plain text edit and is safe with Xcode open.

## Config-driven values

`HELPER_DISTRIBUTION_HOST` is the pattern for any value that differs between development and
production:

1. Defined in `Base.xcconfig` (production) and overridden in `Debug.xcconfig` (staging). Host only, no
   scheme — see rule 2 above.
2. Surfaced through the app target's `Info.plist` as `HelperDistributionHost` with the value
   `$(HELPER_DISTRIBUTION_HOST)`; Xcode expands build-setting references at build time.
3. Read at launch and used to construct the installation service's base URL, prepending `https://`.

```swift
let host = Bundle.main.object(forInfoDictionaryKey: "HelperDistributionHost") as? String
let baseURL = host.flatMap { URL(string: "https://\($0)") }
```

**SwiftPM packages do not see these settings** — they build with their own. Any value a package needs
has to be bridged through the app target's `Info.plist` and injected, which is exactly why
`LiveHelperInstallationService` takes a `baseURL` rather than reading `Bundle.main` itself.

## Proving a settings refactor changed nothing

When moving settings between files, capture the resolved settings before and after and diff them:

```bash
for T in {{APP_NAME}} {{HELPER_NAME}}; do
  for C in Debug Release; do
    xcodebuild -project {{APP_NAME}}.xcodeproj -target "$T" -configuration "$C" \
      -showBuildSettings 2>/dev/null | sed 's/^ *//' | sort > "after-$T-$C.txt"
  done
done
# diff each against a before-*.txt captured prior to the edit; expect an empty diff
```

Then build via **schemes**, not `-target`.
