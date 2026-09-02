# Architecture

What the shared package contains, why it is split the way it is, and where to extend it.

## Contents

- [The two processes](#the-two-processes)
- [Transport and wire format](#transport-and-wire-format)
- [Peer verification](#peer-verification)
- [File map](#file-map)
- [Extending the contract](#extending-the-contract)
- [Wiring the app side](#wiring-the-app-side)
- [What is deliberately not tested](#what-is-deliberately-not-tested)

## The two processes

The app is sandboxed; the helper is not. That is the entire reason the helper exists, and it dictates
everything else:

- An unsandboxed executable **cannot** ship inside a Mac App Store bundle — every executable in the
  bundle must itself be sandboxed. So the helper lives outside the app bundle.
- Living outside the bundle means it is distributed outside the App Store: Developer ID, notarized,
  downloaded on demand, placed by the user.
- Being a separate download means the two can be at different versions on the same machine, which is
  why the wire format is frozen and why the app probes for the installed helper's version.

Both link one Swift package, so the service name, team identifier and peer requirement are written
once and cannot drift between the two binaries.

## Transport and wire format

One transport: a launchd Mach service reached through the C `xpc_connection_*` API. There is no
fallback — if no helper is installed and running, the handshake fails and the app says so, which is
better than silently degrading to something that half works.

The message is a single XPC dictionary with one `payload` key holding the JSON-encoded
``ServiceRequest`` / ``ServiceResponse`` (`XPC/PayloadCoding.swift`). One key holding JSON rather
than a dictionary of typed XPC values means the wire format is described entirely by the two
`Codable` enums — there is no second, hand-rolled encoding to keep in step.

The Swift `xpc_session_*` API and the object-based peer-requirement APIs
(`xpc_peer_requirement_create_team_identity`, `xpc_*_set_peer_requirement`) are unavailable in Swift,
which is why this uses `xpc_connection_*` and the requirement *string* setters.

## Peer verification

Both ends call `xpc_connection_set_peer_code_signing_requirement` **before**
`xpc_connection_resume`. The OS then drops messages from a peer that fails the requirement, so an
impostor that registers the same Mach name cannot impersonate either side.

The requirement string and the reasoning behind its three branches are documented in full in
`Contract/ServiceConstants.swift` — read that comment before changing it. The short version: the
team-OU branch matches the team's own signatures; the two OID branches match Mac App Store and
TestFlight builds, which Apple re-signs and which therefore carry no team OU.

## File map

| Concern | File |
|---|---|
| Names, team, peer requirement | `Contract/ServiceConstants.swift` |
| Request / response enums | `Contract/ServiceRequest.swift`, `ServiceResponse.swift` |
| Turning a reply into a value or a throw | `Contract/ServiceResponse+Unwrapping.swift` |
| Errors that cross the wire / stay local | `Contract/ServiceError.swift`, `ServiceRemoteError.swift` |
| App-side client actor | `XPC/HelperServiceClient.swift` |
| Mach connection, peer pinning, timeouts | `XPC/MachConnectionTransport.swift`, `ServiceTransport.swift` |
| Message encoding | `XPC/PayloadCoding.swift` |
| In-flight replies | `XPC/PendingReplies.swift` |
| Launch-agent registration | `XPC/LaunchAgentRegistration.swift` |
| Am-I-sandboxed probe | `XPC/HostProcessProbe.swift` |
| Helper-side entry point | `Service/ServiceHost.swift` |
| Listener and per-peer handling | `Service/MachServiceListener.swift` |
| Universal request handling | `Service/RequestDispatcher.swift` |
| The app's own work | `Service/HelperRequestHandling.swift` (protocol; you implement it) |
| Listener lifetime + peer count | `Service/ServiceListenerHandle.swift` |
| Manifest, versions, download | `Installation/` |

## Extending the contract

This is the part every adopting project changes. To add an operation:

1. Add a case to ``ServiceRequest`` and, if it returns something new, to ``ServiceResponse``.
2. Add an unwrapping helper in `ServiceResponse+Unwrapping.swift` so callers get a value or a throw
   rather than a switch.
3. Handle it in the helper's `HelperRequestHandling` implementation.
4. Add a round-trip test to `ContractTests`.

Two rules, both because the app and helper ship separately and a user can run last month's helper
against today's app:

- **Add cases; never rename, reorder, or repurpose one.** An older helper decoding a renamed case
  fails the whole message.
- **A request the installed helper doesn't know should produce
  `ServiceError.unsupportedRequest`,** not a crash or a hang — that string is what tells the user to
  update the helper.

If some requests are far slower than others, replace the single `serviceRequestTimeout` with a
`timeout` property on `ServiceRequest` that switches on the case. One generous timeout for everything
makes fast failures slow.

## Wiring the app side

Hold one ``HelperServiceClient`` for the app's lifetime. It connects lazily and reconnects after a
drop, so callers just send:

```swift
let version = try await client.send(.helperInfo).helperVersion()
```

Subscribe to `connectionLostEvents()` where the UI needs to react — the helper quitting or being
updated mid-session shows up there and nowhere else.

If the project uses a dependency-injection container, register the client and
``HelperInstallationService`` in it; the package deliberately takes no opinion, which is why
`LiveHelperInstallationService` takes its HTTP transport and version probe as injected closures.

## What is deliberately not tested

`MachConnectionTransport`, `MachServiceListener`, `LaunchAgentRegistration` and `HostProcessProbe`
have no unit tests, in this package or the project it was extracted from: they need a real Mach
service, a real launchd, and a real code signature. Coverage stops at the codec, the contract, the
dispatcher and the installation logic — which is where the bugs that unit tests can catch actually
live. The transport is verified end to end instead, by the checklist in SKILL.md.
