import Foundation
import OSLog

/// The app's end of the transport: an actor that forwards every request to the out-of-process helper
/// over its launchd Mach service.
///
/// It connects lazily on first use and reconnects on the next request after a drop, so callers never
/// manage the connection themselves. Hold one instance for the app's lifetime.
public actor HelperServiceClient {

  private static let logger = Logger(
    subsystem: "{{APP_BUNDLE_ID}}",
    category: "HelperServiceClient"
  )

  /// A live transport and the token its drop handler reports under.
  ///
  /// The token is what lets a drop from an already-discarded connection be ignored, instead of
  /// tearing down the replacement.
  private struct Connection {
    let id: UUID
    let transport: any ServiceTransport
  }

  private let serviceName: String
  private var connection: Connection?
  private let connectionLoss = EventBroadcaster<Void>()

  /// Creates a client that reaches the helper's Mach service under `serviceName`.
  public init(serviceName: String = {{SYMBOL_PREFIX}}Name) {
    self.serviceName = serviceName
  }

  /// Sends `request` to the helper, connecting first if necessary.
  @discardableResult
  public func send(_ request: ServiceRequest) async throws -> ServiceResponse {
    try await activeTransport().send(request)
  }

  /// Checks that the helper is reachable, throwing if it isn't.
  public func ping() async throws {
    try await send(.ping).ok()
  }

  /// Disconnects, cancelling the transport and clearing cached state.
  public func disconnect() async {
    await discardConnection(reason: "Client disconnected")
  }

  /// Probes the installed helper for its bundle version, or `nil` if no helper is reachable.
  ///
  /// This deliberately opens a **throwaway** connection with its own no-op drop handler rather than
  /// reusing the live one: cancelling a shared transport would fire the drop logic and tear down the
  /// app's real connection as a side effect of a version check. It is also the only reliable way for
  /// a sandboxed app to detect a user-placed Developer ID app — it can't go looking on disk.
  public func installedHelperVersion() async -> String? {
    do {
      let probe = try MachConnectionTransport(serviceName: serviceName, onDrop: {})
      let version = try await probe.send(.helperInfo).helperVersion()
      await probe.cancel(reason: "Helper probe finished")
      return version
    } catch {
      Self.logger.info("Helper probe failed: \(error, privacy: .public)")
      return nil
    }
  }

  /// A stream that emits whenever the transport drops unexpectedly, so the UI can react.
  public func connectionLostEvents() -> AsyncStream<Void> {
    connectionLoss.subscribe()
  }

  // MARK: - Transport

  /// The live transport, connected on first use.
  private func activeTransport() throws -> any ServiceTransport {
    if let connection { return connection.transport }

    let id = UUID()
    let transport = try MachConnectionTransport(serviceName: serviceName) { [weak self] in
      Task { await self?.handleDrop(id: id) }
    }
    connection = Connection(id: id, transport: transport)
    return transport
  }

  /// Cancels and forgets the live transport without notifying loss subscribers.
  private func discardConnection(reason: String) async {
    guard let connection else { return }
    self.connection = nil
    await connection.transport.cancel(reason: reason)
  }

  /// Reacts to a transport dropping unexpectedly, ignoring drops from a discarded connection.
  private func handleDrop(id: UUID) {
    guard let connection, connection.id == id else { return }
    Self.logger.info("Helper transport dropped (service: \(self.serviceName, privacy: .public))")
    self.connection = nil
    connectionLoss.broadcast(())
  }
}
