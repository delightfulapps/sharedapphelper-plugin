# The launch agent

How the helper comes to own a global Mach service, and what to do when the registration goes stale.

## The plist

`LaunchAgents/{{SERVICE_NAME}}.plist` in the repo, copied into
`{{HELPER_NAME}}.app/Contents/Library/LaunchAgents/` by the "Embed Launch Agents" build phase. The
template is `assets/config/LaunchAgent.plist`; four things in it matter:

- **`Label` must equal the file's base name.** `SMAppService.agent(plistName:)` looks the plist up by
  file name and launchd rejects a mismatch. Save it as `{{SERVICE_NAME}}.plist`.
- **`BundleProgram`** is a path *relative to the registering bundle*, so
  `Contents/MacOS/{{HELPER_NAME}}` — not an absolute path, which would break the moment the user moved
  the app.
- **`MachServices`** names the service launchd will own and hand the receive right to.
- **`RunAtLoad`, and deliberately no `KeepAlive`.** The helper starts at login so it is ready, but the
  menu's Quit item actually quits until the next login. A background process the user cannot stop is a
  bug, not a feature.

`AssociatedBundleIdentifiers` is what makes the entry in System Settings ▸ Login Items say the app's
name instead of a bundle identifier. Worth setting: this is the one place users go looking.

## The helper registers itself

The **app cannot** do this. `SMAppService.agent().register()` from a sandboxed process fails with
`Operation not permitted`, and calling it synchronously from an app's `init` blocks launch. So the
unsandboxed helper calls `LaunchAgentRegistration.registerAgentIfNeeded()` on its own launch.

A plain app also can't self-advertise a *global* Mach name — launchd has to own it. That is why the
resident, service-owning instance is always the launchd-launched one, and why the helper template has
a single-instance guard that prefers it: a Finder launch registers the agent and then yields.

## Re-registering on update

`SMAppService.status == .enabled` means *a* registration exists. It does not mean that registration
points at the running build's executable — a registration records the program path at registration
time, so after an update the recorded job still points at the previous build. launchd can no longer
bootstrap it, and the Mach service is advertised but **unbacked**:

```bash
launchctl print "gui/$(id -u)"                    # lists the service as enabled
launchctl print "gui/$(id -u)/{{SERVICE_NAME}}"   # "Could not find service"
```

...while the app's handshake fails with `Connection invalid`, which the UI reports as "helper not
installed" — an unhelpfully wrong message for a helper that is very much installed.

`registerAgentIfNeeded()` therefore records the build it last registered for
(`CFBundleShortVersionString (CFBundleVersion)` in `UserDefaults`) and, whenever the running build
differs, unregisters the stale job before registering the current plist. That bumps the launchd job
generation. A machine already stuck this way has no recorded build, so it self-heals on the next
launch of a helper carrying this logic.

## Recovering a machine stuck on an old registration

For a helper that predates the fix above:

```bash
# 1. Is the name advertised but unbacked?
launchctl print "gui/$(id -u)/{{SERVICE_NAME}}"     # "Could not find service" == broken
sfltool dumpbtm | grep -A8 '{{SERVICE_NAME}}'       # Executable Path points at the old build
```

```bash
# 2. Quit the helper.
osascript -e 'tell application "{{HELPER_NAME}}" to quit'
```

3. Remove the stale login-item registration. `SMAppService` is the **only** supported unregister:
   `launchctl bootstrap`/`bootout` fail with `Input/output error (5)` because the plist is managed by
   Background Task Management. Use System Settings ▸ General ▸ Login Items & Extensions and remove
   `{{HELPER_NAME}}`.

```bash
# 4. Relaunch; it registers the current plist afresh.
open -a {{HELPER_NAME}}
```

```bash
# 5. Verify the job now bootstraps and vends the service.
launchctl print "gui/$(id -u)/{{SERVICE_NAME}}" | grep -E 'state =|pid ='
sfltool dumpbtm | grep -A8 '{{SERVICE_NAME}}'
```

`scripts/unregister-helper.sh` automates steps 2 and 4 for a development machine, and prints the
manual step it cannot do.

## The app's sandbox exception

Looking up a *global* Mach name from inside the sandbox needs a temporary exception in the app's
entitlements:

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
	<string>{{SERVICE_NAME}}</string>
</array>
```

App Review permits this with justification. The justification that works is the true one: the app
connects only to the same-team, notarized helper the user installs, enforced by a code-signing
requirement pinned on both ends of the connection.
