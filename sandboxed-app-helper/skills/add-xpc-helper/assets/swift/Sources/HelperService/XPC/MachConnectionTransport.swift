import Foundation
import XPC

/// Reaches the helper's launchd Mach service over the C `xpc_connection_*` API, pinning the peer's
/// signature before the connection is ever resumed.
actor MachConnectionTransport: ServiceTransport {

  /// The live XPC connection.
  ///
  /// Boxed rather than stored bare so `deinit` can cancel it without being an `isolated deinit`,
  /// which would raise this package's deployment floor to macOS 15.4 for no benefit.
  private let connection: UncheckedSendableBox<xpc_connection_t>
  private var pending = PendingReplies()

  /// Connects to the Mach service named `serviceName`, reporting connection errors through `onDrop`.
  init(
    serviceName: String,
    peerRequirement: String = {{SYMBOL_PREFIX}}PeerCodeSigningRequirement,
    onDrop: @escaping @Sendable () -> Void
  ) throws {
    self.connection = UncheckedSendableBox(
      try Self.makeVerifiedConnection(
        name: serviceName,
        peerRequirement: peerRequirement
      ) { event in
        if xpc_get_type(event) == XPC_TYPE_ERROR { onDrop() }
      })
  }

  deinit {
    xpc_connection_cancel(connection.value)
  }

  func send(_ request: ServiceRequest) async throws -> ServiceResponse {
    let connection = self.connection
    let message = UncheckedSendableBox(try makeMessage(request))
    let id = UUID()
    return try await withTimeout(serviceRequestTimeout) {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          await self.register(id, continuation)
          xpc_connection_send_message_with_reply(connection.value, message.value, nil) { reply in
            let result = Self.decode(reply)
            Task { await self.complete(id, with: result) }
          }
        }
      }
    }
  }

  func cancel(reason: String) {
    xpc_connection_cancel(connection.value)
    pending.failAll(ServiceRemoteError(message: reason))
  }

  /// Creates and resumes a connection that pins `peerRequirement` on its peer.
  ///
  /// The requirement has to be set **before** `xpc_connection_resume`: afterwards the connection is
  /// already accepting messages and the check no longer protects anything.
  private static func makeVerifiedConnection(
    name: String,
    peerRequirement: String,
    eventHandler: @escaping @Sendable (xpc_object_t) -> Void
  ) throws -> xpc_connection_t {
    let connection = name.withCString { xpc_connection_create_mach_service($0, nil, 0) }

    let status = peerRequirement.withCString {
      xpc_connection_set_peer_code_signing_requirement(connection, $0)
    }
    guard status == 0 else {
      xpc_connection_cancel(connection)
      throw ServiceRemoteError(
        message: "Failed to set the peer code-signing requirement (status \(status))")
    }

    xpc_connection_set_event_handler(connection, eventHandler)
    xpc_connection_resume(connection)
    return connection
  }

  /// Decodes a reply message, or reports the connection error it carries instead.
  private static func decode(_ reply: xpc_object_t) -> Result<ServiceResponse, any Error> {
    guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
      return .failure(ServiceRemoteError(message: "XPC Mach connection error: \(reply)"))
    }
    return Result { try decodePayload(ServiceResponse.self, from: reply) }
  }

  private func register(
    _ id: UUID,
    _ continuation: CheckedContinuation<ServiceResponse, any Error>
  ) {
    pending.register(id, continuation)
  }

  private func complete(_ id: UUID, with result: Result<ServiceResponse, any Error>) {
    pending.complete(id, with: result)
  }
}
