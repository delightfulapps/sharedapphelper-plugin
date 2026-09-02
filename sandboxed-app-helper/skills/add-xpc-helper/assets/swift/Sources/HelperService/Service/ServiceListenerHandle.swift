import Synchronization
import XPC

/// Keeps a running Mach service listener alive and reports how many peers are connected.
///
/// Dropping the handle cancels the listener, so the helper must retain it for as long as it means to
/// serve — storing it in a local variable is a silent way to stop answering.
public final class ServiceListenerHandle: @unchecked Sendable {

  private let listener: xpc_connection_t
  private let activeConnections = Mutex(0)
  private let counts = EventBroadcaster<Int>(replaysLatest: true)

  init(listener: xpc_connection_t) {
    self.listener = listener
  }

  deinit {
    xpc_connection_cancel(listener)
  }

  /// A stream of the number of peers connected, opening with the count at subscription time.
  ///
  /// Useful for a menubar indicator: it tells the user the helper is doing something, which is most
  /// of what they want from a background process.
  public func activeConnectionCounts() -> AsyncStream<Int> {
    counts.subscribe()
  }

  /// Records a newly accepted peer.
  func connectionOpened() {
    counts.broadcast(
      activeConnections.withLock { count in
        count += 1
        return count
      })
  }

  /// Records a peer that went away.
  func connectionClosed() {
    counts.broadcast(
      activeConnections.withLock { count in
        count = max(0, count - 1)
        return count
      })
  }
}
