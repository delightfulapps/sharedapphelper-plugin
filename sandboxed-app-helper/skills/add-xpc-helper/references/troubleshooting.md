# Troubleshooting

Almost every failure in this architecture surfaces the same way — the app says the helper isn't there
— so start by narrowing *which* link is broken rather than guessing.

## Narrow it down first

```bash
# 1. Is the launchd job registered AND backed by a real executable?
launchctl print "gui/$(id -u)/{{SERVICE_NAME}}" | grep -E 'state =|pid ='
# 2. What does Background Task Management think it points at?
sfltool dumpbtm | grep -A8 '{{SERVICE_NAME}}'
# 3. Does the app satisfy the requirement the helper pins on it?
codesign -v -R='<requirement string from ServiceConstants.swift>' /Applications/{{APP_NAME}}.app
# 4. What is each side logging?
log stream --predicate 'subsystem BEGINSWITH "{{APP_BUNDLE_ID}}"' --level info
```

Step 1 failing means launchd; step 3 failing means signing; both passing means the code.

## Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection invalid` immediately, on every request | The launch agent is registered but points at an old build's executable | See [launch-agent.md](launch-agent.md#recovering-a-machine-stuck-on-an-old-registration). A helper with the re-registration logic self-heals on relaunch |
| App reports "helper not installed", helper is visibly running | The peer requirement rejects the app — usually a TestFlight or App Store build against a helper whose requirement has only the team-OU branch | Ship a helper carrying all three branches. The requirement is compiled into **both** binaries, so the app alone cannot fix it |
| Works from Xcode, fails from a TestFlight build | Same as above. Apple re-signs those builds, so their leaf carries no team OU | Check with `codesign -v -R='…'` against the *TestFlight* build, not the local one |
| `Failed to set the peer code-signing requirement (status …)` | Malformed requirement string | Test it standalone: `codesign -v -R='<string>' /Applications/{{APP_NAME}}.app` |
| Helper launches, menubar appears, app still can't connect | Two instances running; the one holding the Mach name isn't the one you're looking at, or neither is the launchd instance | The single-instance guard in the helper template handles this. Confirm with `pgrep -l {{HELPER_NAME}}` |
| `Operation not permitted` when registering the agent | The registering process is sandboxed — i.e. the *app* is trying to register | Only the helper registers. `HostProcessProbe.isSandboxed` guards this |
| Requests hang until the timeout, then fail | The helper's handler never returns, or a reply is being dropped | Every path through `RequestDispatcher` replies, including thrown errors. Check custom handler code for a path that returns without replying |
| Helper's menubar says "Idle" although the app connected | An XPC Mach connection is lazy: creating and resuming one reaches nothing, and the listener is handed no peer until a message travels | Call `client.connect()` at launch — it sends a `ping` so the connection becomes real. A `connect` that only builds the transport establishes nothing and still returns successfully |
| A helper→app callback reaches the wrong connection, or breaks whenever the settings screen checks the version | The helper is inferring which peer is the app instead of taking an announcement. `installedHelperVersion()` opens a real, throwaway probe connection by design | Have the app announce itself with an explicit request the dispatcher answers, and key the registry on the peer's own id — see [callbacks.md](callbacks.md) |
| The app retries a helper that will never be there, forever | A reconnect loop with one fixed delay; most machines have no helper installed | Back off to a ceiling (5s doubling to 300s), resetting on a successful connect — see [callbacks.md](callbacks.md#reconnecting-from-the-app-side) |
| Notarization rejects the upload: "not signed with a valid Developer ID" or hardened-runtime errors | `-exportArchive` with manual signing didn't apply the runtime flag | The re-sign step in `release-helper.sh` exists for this. Verify with `codesign -dvvv` and bit-test `flags=` against `0x10000` |
| `No signing certificate "Developer ID Application" found` in CI | Xcode Cloud managed signing provides no such certificate | Import a `.p12` from a secret — see [signing-and-ci.md](signing-and-ci.md) |
| `security import` succeeds but signing fails | The `.p12` has the certificate but not its private key | Re-export from Keychain Access selecting the **private key**. Check first with `scripts/validate-developer-id-p12.sh` |
| Identity present but "not valid" in CI | The Developer ID CA chain is missing from a fresh keychain | `release-helper.sh` installs Apple's intermediates and re-checks |
| Gatekeeper warns on a downloaded helper | The archive was zipped before stapling | Re-zip **after** `stapler staple` |
| App never notices a new release | Manifest order was trusted, or versions compared lexically | Both are handled in `latestCompatibleVersion()` and `VersionOrdering` — check nothing bypasses them |
| Download always fails an integrity check | The manifest's `size`/`sha256` describe the pre-staple archive | Compute both from the final, stapled zip |
| A build setting seems to be ignored | An inline value in `project.pbxproj` overrides the xcconfig | Empty the target's `buildSettings` dict |
| A URL setting arrives truncated at runtime | `//` starts a comment in an xcconfig | Store the host alone; prepend the scheme in code |
| The launch agent plist isn't in the built app | The copy phase is missing, or its destination is wrong | It must land in `Contents/Library/LaunchAgents`. See [pbxproj-edits.md](pbxproj-edits.md#4-launch-agent-file-reference-and-copy-phase) |
| Xcode Cloud never runs the helper release | The helper's scheme isn't shared, or Archive isn't set to Release | Product ▸ Scheme ▸ Manage Schemes ▸ tick *Shared* |

## When changing the peer requirement

Remember it is pinned in **both** binaries. An installed helper carrying the old string keeps
rejecting the app no matter what the app does, so a requirement change means shipping a new helper and
waiting for users to install it. Plan it as a migration, not an edit.
