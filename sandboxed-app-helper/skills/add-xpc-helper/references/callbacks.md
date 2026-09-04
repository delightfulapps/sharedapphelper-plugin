# Callbacks: the helper sending requests to the app

The templates carry one direction — the app asks, the helper answers. This file is for the projects
that need the other one too: the helper originating a request that only the app can serve, because
the app holds the user's session, the window, or the data the helper never sees.

## Contents

- [Why this isn't in the templates](#why-this-isnt-in-the-templates)
- [The rule everything else rests on: a connection opens when a message travels](#the-rule-everything-else-rests-on-a-connection-opens-when-a-message-travels)
- [The app announces itself](#the-app-announces-itself)
- [Why "the most recently accepted peer" is wrong](#why-the-most-recently-accepted-peer-is-wrong)
- [The peer registry and the reverse client](#the-peer-registry-and-the-reverse-client)
- [Reconnecting from the app side](#reconnecting-from-the-app-side)
- [What to test](#what-to-test)

## Why this isn't in the templates

Most helpers only answer. Adding the reverse direction costs a second contract pair
(`AppRequest`/`AppResponse`), a registry of which peers can serve it, a second client actor, and a
generic `PendingReplies` — real weight for a project that never calls back. So the package ships the
one direction and this file describes the other, rather than making every adopter carry both.

Everything below is generalised from a project that added it, and from the bugs it hit doing so.

## The rule everything else rests on: a connection opens when a message travels

`xpc_connection_create_mach_service` followed by `xpc_connection_resume` reaches **nothing**. The
connection is lazy: `launchd` doesn't demand-start the helper and the helper's listener event handler
is not called with a peer until the app actually sends something. Until then, from the helper's side,
the app does not exist.

Three consequences, all of which read as unrelated bugs until you know this one:

- A `connect()` that only constructs the transport establishes no connection. It returns successfully
  and nothing happened. This is why ``HelperServiceClient/connect()`` sends a `ping` rather than just
  building a `MachConnectionTransport`.
- The helper's menubar shows "Idle" while an app that believes it is connected sits there.
- A callback has no peer to travel down, so the helper reports the app as unavailable while the app is
  plainly running.

The fix in all three cases is the same: send something.

## The app announces itself

Since the helper only learns of a peer when a message arrives, make the *first* message the one that
says what this peer is for. Four pieces:

**1. A transport-level request.** Add a case to ``ServiceRequest``:

```swift
/// Announces that this connection can serve ``AppRequest``s.
case registerApp
```

Adding a case is wire-safe; renaming or reordering one is not. See
[architecture.md](architecture.md#extending-the-contract).

**2. Answer it in the package, not the app's handler.** In `RequestDispatcher.perform`, put it
alongside `ping` — it means the same thing in every project, and the helper's
``HelperRequestHandling`` should never see it:

```swift
case .ping, .registerApp:
  .ok
```

**3. Mint a per-peer identity on accept, but register on announcement.** In
`MachServiceListener.accept`, create a `UUID` for the peer and close over it in the event handler.
Do **not** add the peer to the registry here — being accepted isn't the same as being the app:

```swift
let peerID = UUID()
xpc_connection_set_event_handler(peer) { [weak handle] event in
  handlePeerEvent(event, dispatcher: dispatcher, handle: handle, peerID: peerID)
}
```

Then, in `handlePeerEvent`, once the request has decoded:

```swift
if case .registerApp = request, let peer = xpc_dictionary_get_remote_connection(event) {
  handle?.peers.register(peerID, peer)
}
```

`xpc_dictionary_get_remote_connection(event)` is the same call `sendReply` already uses to route a
reply — it hands back the connection the message arrived on, which is exactly the one to keep.

**4. Remove on invalidation.** The `XPC_ERROR_CONNECTION_INVALID` branch of `handlePeerEvent` already
runs when a peer goes away; have it call `handle?.peers.remove(peerID)` there, next to
`connectionClosed()`.

Keying on the peer's own `UUID` rather than a token handed back by `register` is what makes the
announcement idempotent: an app that reconnects, or announces twice on one connection, replaces its
entry instead of leaving a stale duplicate behind that a later `remove` doesn't clear.

On the app side, `connect()` becomes the announcement:

```swift
public func connect() async throws {
  try await send(.registerApp).ok()
}
```

It now throws `ServiceRemoteError` when no helper is reachable, and `ServiceError` when the *installed*
helper is too old to know `registerApp` — two different problems the caller can tell apart.

## Why "the most recently accepted peer" is wrong

The tempting shortcut is to skip the announcement and treat the newest accepted connection as the app.
It fails on this package's own code.

``HelperServiceClient/installedHelperVersion()`` deliberately opens a **throwaway** connection with its
own no-op drop handler, sends `.helperInfo`, and cancels it — so that a version check can't tear down
the app's real connection as a side effect. That probe is a genuine, accepted peer. Under an inferred
rule it becomes "the app" the moment it connects, and the helper's callbacks start going down a
connection that is about to be cancelled. Every settings-screen version check would break the callback
path for a few hundred milliseconds, which is exactly the kind of bug that reproduces once a week and
never under a debugger.

Announcing is one extra case on the wire and removes the whole class.

## The peer registry and the reverse client

**The registry** hangs off ``ServiceListenerHandle``, which already owns per-peer lifecycle. A
`Mutex`-guarded array, newest last:

```swift
final class ConnectedAppPeers: Sendable {
  private struct Peer {
    let id: UUID
    let connection: UncheckedSendableBox<xpc_connection_t>
  }
  private let peers = Mutex<[Peer]>([])

  /// Records `peer` under `id`. Announcing more than once replaces the earlier entry rather than
  /// recording the same peer twice.
  func register(_ id: UUID, _ peer: xpc_connection_t) {
    peers.withLock { peers in
      peers.removeAll { $0.id == id }
      peers.append(Peer(id: id, connection: UncheckedSendableBox(peer)))
    }
  }

  func remove(_ id: UUID) { peers.withLock { $0.removeAll { $0.id == id } } }

  /// The most recently registered connection, or `nil` when no app has announced itself.
  var mostRecent: xpc_connection_t? { peers.withLock { $0.last?.connection.value } }
}
```

An array rather than a single slot because two builds of the app can be running at once — a debug
build launched from Xcode over the installed one. Newest wins, and the older one is still there to fall
back to when the newest quits.

**The client** mirrors `MachConnectionTransport` in the other direction: an actor that looks up
`peers.mostRecent`, sends with `xpc_connection_send_message_with_reply`, and parks the continuation in
`PendingReplies` under a `UUID`. It is constructed by `ServiceListenerHandle` (which owns the registry)
and exposed as a `public let` on it, so the helper reaches the app through the same handle it already
retains to serve.

Two supporting changes fall out of this:

- **`PendingReplies` becomes generic** over the response type — `PendingReplies<AppResponse>` as well as
  `PendingReplies<ServiceResponse>`. It is a mechanical change; the type is already a plain
  `[UUID: CheckedContinuation]`.
- **`ServiceError` gains a case** for "no app is connected", e.g. `appUnavailable(String)`. An added
  case, so wire-safe — but it is the answer the helper gives whenever `mostRecent` is `nil`, and the
  message wants to name the app so the user reads "MyApp isn't running" rather than a transport error.

Both directions can share `serviceRequestTimeout`, but the app end is usually the fast one — a callback
that waits 60s for an app that isn't answering is a hang. Give the reverse client its own, shorter
value if the app's work is bounded.

## Reconnecting from the app side

The app must hold its connection open for as long as it should answer callbacks, which means
reconnecting when it drops. Subscribe to ``HelperServiceClient/connectionLostEvents()`` and retry —
but **back off**.

The naive loop uses one fixed delay, and on the majority of machines, where no helper is installed and
none ever will be, it retries at that rate forever. Treat a failed connect as "no helper installed",
not as an error worth surfacing, and double the delay to a ceiling:

```swift
private static let initialReconnectDelay = Duration.seconds(5)
private static let maximumReconnectDelay = Duration.seconds(300)
```

5s so a helper the user just launched is picked up promptly; 300s so an idle Mac isn't spinning.
Reset to the initial delay on a successful connect, so the *next* drop is handled promptly again. Note
this is a loop over both connect attempts and loss events — a `for await` over the loss stream alone
never retries a connect that failed in the first place, because a connection that never opened never
drops.

## What to test

The registry is the part of this that unit tests can reach — the listener and the transports around it
need a real Mach service, a real `launchd`, and a real code signature, which is why they are on the
list in [architecture.md](architecture.md#what-is-deliberately-not-tested). Four cases cover it:

| Test | What it pins |
|---|---|
| Nothing registered → `mostRecent` is `nil` | Accepting a connection is not the same as being the app |
| Two announcements → the later one is used | Newest build wins |
| Removing the newest → the earlier one answers again | A quitting app falls back rather than going dark |
| Announcing twice on one id, then removing once → nothing left | The dedup in `register` actually replaces |

Build the peers with `xpc_connection_create(nil, nil)`, resumed with an empty event handler, and cancel
them in the test helper's `deinit` — no Mach service is needed to hold an `xpc_connection_t` in a
registry.
