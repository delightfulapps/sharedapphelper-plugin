---
name: add-xpc-helper
description: Add an unsandboxed, Developer ID-signed helper process to a macOS app and talk to it over XPC. Covers the helper app target, the shared Swift package holding both ends of the wire contract, the LaunchAgent that vends a global Mach service, peer code-signing verification, the xcconfig build-settings tree, the on-demand download/install flow with a versions.json manifest, and the notarization and release pipeline. Use this skill whenever the user mentions an XPC helper, a privileged or unsandboxed helper, a helper app or helper target, a launch agent, SMAppService, a Mach service, xpc_connection, mach-lookup, or a login item for a Mac app - and also when they describe the underlying problem without naming any of that.
when_to_use: Use when a macOS app needs to do something the App Sandbox forbids - spawning a subprocess, running a CLI tool, reading files outside its container, driving another app - and especially when the app ships on the Mac App Store so the work has to move into a separate process distributed outside it. Also use for the downstream pieces: hosting and verifying a helper download, detecting which helper version is installed, notarizing and stapling a Developer ID app, or wiring an Xcode Cloud release for a second product.
license: MIT
---

# Sandboxed app + XPC helper

A sandboxed macOS app cannot spawn subprocesses, read another app's temp namespace, or reach most of
the system. Moving that work into a second process solves it, but only one shape of second process
actually ships: every executable inside a Mac App Store bundle must itself be sandboxed, so an
unsandboxed helper **cannot** live inside the app bundle.

This skill builds the shape that works:

```
┌──────────────────────────────┐      Mach XPC       ┌──────────────────────────────┐
│  App                         │  peer code-signing  │  Helper.app                  │
│  • Sandboxed (App Store)     │  requirement, both  │  • Unsandboxed, Developer ID │
│  • client actor              │──── ends ──────────▶│  • notarized, downloaded     │
│  • Helper settings tab       │◀────────────────────│  • self-registers LaunchAgent│
└──────────────────────────────┘  JSON over XPC      └──────────────────────────────┘
```

The helper is a standalone menubar app distributed **outside** the App Store, downloaded on demand by
the app, and placed by the user. On first launch it registers its own `LaunchAgent`, which owns the
global Mach service name; `launchd` starts it at login and hands it the receive right. Both ends pin a
code-signing requirement before activating, so neither can be impersonated.

## Before starting

Confirm these, and say plainly if one is missing rather than building something that cannot ship:

- The app is a macOS app in an `.xcodeproj` (this skill's project edits assume that, not a workspace
  or a Tuist/XcodeGen generator).
- The team has a **Developer ID Application** certificate. Xcode Cloud managed signing does *not*
  provide one — it must be exported as a `.p12` and supplied as a secret. Without it the helper can be
  built but never distributed.
- There is somewhere to serve `versions.json` and the helper archive over HTTPS (GitHub Releases
  behind a custom domain is what the reference pipeline assumes).
- Xcode is **quit** before any `project.pbxproj` edit.

## Inputs

Collect these once, then substitute them everywhere. Derive what you can from the existing project
(`PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM`, `MACOSX_DEPLOYMENT_TARGET` are all in the project or
its xcconfigs already) and ask the user only for the rest.

| Placeholder | Meaning | Example |
|---|---|---|
| `{{APP_NAME}}` | Main app target / product name | `MacOSApp` |
| `{{APP_BUNDLE_ID}}` | Main app bundle identifier | `app.macos.viewer` |
| `{{HELPER_NAME}}` | Helper target / product name | `MacOSAppHelper` |
| `{{HELPER_BUNDLE_ID}}` | Helper bundle identifier | `app.macos.viewer.helper` |
| `{{SERVICE_NAME}}` | Mach service name **and** launchd job label | `app.macos.viewer.MCPService` |
| `{{TEAM_ID}}` | Apple Developer Team ID | `123456789` |
| `{{PACKAGE_NAME}}` | Shared Swift package + module name | `MacOSAppHelperKit` |
| `{{SYMBOL_PREFIX}}` | Prefix for the package's global constants | `helperService` |
| `{{DISTRIBUTION_HOST}}` | Host serving the manifest, **no scheme** | `helper.macos.app` |
| `{{DEPLOYMENT_TARGET}}` | `MACOSX_DEPLOYMENT_TARGET` | `26.0` |

Copy templates with `${CLAUDE_SKILL_DIR}/scripts/apply-template.sh <source> <destination>`, which
takes these as environment variables, substitutes them, and refuses to leave an unresolved
placeholder behind — a missed `{{SERVICE_NAME}}` produces a helper that builds and then never
connects, which is a slow thing to discover by hand.

`{{SERVICE_NAME}}` is load-bearing in four places that must agree exactly: the launchd plist `Label`,
that plist's **file name**, the `MachServices` key, and the app's mach-lookup entitlement. A mismatch
produces a service that is advertised but unreachable, which reads to the user as "helper not
installed".

## Workflow

Work in this order — each step depends on the one before. Read the reference file for the step you are
on; do not read them all up front.

**1. Build settings → xcconfig.** Read `${CLAUDE_SKILL_DIR}/references/xcconfig.md`. Create (or fold
into) a `Config/` tree and move the settings out of `project.pbxproj`. Doing this first means the
helper target you add next has somewhere to point. Templates: `${CLAUDE_SKILL_DIR}/assets/config/`.

**2. Shared package.** Copy `${CLAUDE_SKILL_DIR}/assets/swift/` into the repo as `{{PACKAGE_NAME}}/`
(the `Helper/` subdirectory belongs in the helper target, not the package — move it in step 5). It has
no external dependencies and builds standalone — run `swift build && swift test` in it before touching the Xcode
project, so a later build failure is unambiguously the project's fault, not the package's.
Read `${CLAUDE_SKILL_DIR}/references/architecture.md` for what each file does and where to extend the
contract with the app's own requests.

**3. Helper target and project wiring.** Read `${CLAUDE_SKILL_DIR}/references/pbxproj-edits.md`. Quit
Xcode, take a git checkpoint, then add the helper target, its "Embed Launch Agents" copy phase, the
package product dependency on both targets, and the shared helper scheme.

**4. Launch agent and entitlements.** Read `${CLAUDE_SKILL_DIR}/references/launch-agent.md`. Add
`LaunchAgents/{{SERVICE_NAME}}.plist` and the app's mach-lookup temporary exception.

**5. Wire both ends.** Copy `${CLAUDE_SKILL_DIR}/assets/swift/Helper/HelperApp.swift` in as the
helper's `@main`, and resolve the client actor wherever the app currently does the sandboxed-forbidden
work. Implement the package's `HelperRequestHandling` protocol in the helper with the app's actual
operations.

**6. Download and install.** Read `${CLAUDE_SKILL_DIR}/references/distribution.md`. The installation
service ships in the package (`Sources/…/Installation/`); this step is publishing the manifest and
building the settings UI that drives it.

**7. Signing, notarization, release.** Read `${CLAUDE_SKILL_DIR}/references/signing-and-ci.md`. Copy
`${CLAUDE_SKILL_DIR}/assets/scripts/` for the local path and `${CLAUDE_SKILL_DIR}/assets/ci/` for
Xcode Cloud.

**8. Verify.** Run the checklist below. When something is wrong, go to
`${CLAUDE_SKILL_DIR}/references/troubleshooting.md` rather than guessing — most failures in this
architecture present as the same vague symptom.

## Things that look optional and are not

Each of these was a real, expensive bug. Keep them even when the code around them changes:

- **Set the peer requirement on both ends, before `xpc_connection_resume`.** After resume it is too
  late; the connection is already accepting messages.
- **Keep all three branches of the requirement string.** The team-OU branch alone matches only builds
  signed with the team's own certificates. Mac App Store and TestFlight builds are re-signed by Apple
  and carry no team OU, so they are matched by their leaf-certificate marker OIDs instead. With an
  OU-only requirement the helper silently drops every message from a TestFlight build.
- **The requirement is pinned in both binaries**, so changing it means shipping a new helper too. An
  installed helper carrying the old string keeps rejecting the app no matter what the app does.
- **Re-register the launch agent whenever the helper's build changes.** `SMAppService.status ==
  .enabled` only means *a* registration exists, not that it points at the running build's executable.
- **`ENABLE_APP_SANDBOX = NO` and `ENABLE_HARDENED_RUNTIME = YES` on the helper.** The first is the
  whole point; the second is required for notarization.
- **Verify downloads strictly.** A manifest entry missing `size` or `sha256` is itself an integrity
  failure — the artifact runs unsandboxed on the user's machine.
- **Compare versions numerically**, never lexically: `"2026.10" < "2026.2"` as plain strings, which
  makes a newer release look older and updates stop being detected.
- **The app cannot register the agent.** A sandboxed process gets `Operation not permitted`. The
  helper registers itself.

## Verification checklist

```bash
# 1. Resolved settings are what you expect, per target and configuration.
xcodebuild -project {{APP_NAME}}.xcodeproj -target {{HELPER_NAME}} -configuration Release -showBuildSettings

# 2. Both products build from their schemes (schemes, not -target).
xcodebuild -project {{APP_NAME}}.xcodeproj -scheme {{APP_NAME}}    -configuration Release build
xcodebuild -project {{APP_NAME}}.xcodeproj -scheme {{HELPER_NAME}} -configuration Release build

# 3. The app satisfies the requirement the helper pins on it.
codesign -v -R='<the requirement string from ServiceConstants.swift>' /Applications/{{APP_NAME}}.app

# 4. The agent is registered AND actually backed by a running job.
launchctl print "gui/$(id -u)/{{SERVICE_NAME}}" | grep -E 'state =|pid ='
sfltool dumpbtm | grep -A8 '{{SERVICE_NAME}}'
```

Then end to end: build both, launch the helper once, and confirm the app's handshake succeeds and the
helper's menubar item shows a connected peer. `installedHelperVersion()` returning the helper's
`CFBundleShortVersionString` is the single best signal that the whole chain works.

## Reference files

| File | Read it when |
|---|---|
| `references/architecture.md` | Extending the wire contract, or understanding the client/host split |
| `references/xcconfig.md` | Step 1, or any later build-settings question |
| `references/pbxproj-edits.md` | Step 3 — the exact stanzas to add |
| `references/launch-agent.md` | Step 4, or a registration that will not stick |
| `references/distribution.md` | Step 6 — manifest schema, hosting, install UI |
| `references/signing-and-ci.md` | Step 7 — Developer ID, notarization, Xcode Cloud |
| `references/troubleshooting.md` | Anything is broken |
| `references/previewsmith-example.md` | Wanting a worked example of a real, non-trivial contract |

## Bundled files

| Path | What it is |
|---|---|
| `scripts/apply-template.sh` | Copies a template into the project with placeholders substituted |
| `assets/swift/` | The shared package: contract, both transport ends, installation service, tests |
| `assets/swift/Helper/HelperApp.swift` | The helper target's `@main` — menubar app, registration, listener |
| `assets/config/` | xcconfig tree, LaunchAgent plist, app entitlements, Info.plist fragment |
| `assets/scripts/` | `notarize-helper.sh`, `validate-developer-id-p12.sh`, `unregister-helper.sh` |
| `assets/ci/` | Xcode Cloud hooks, `lib/release-helper.sh`, `lib/github.sh`, export options |
