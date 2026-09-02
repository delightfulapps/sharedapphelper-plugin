/// Runs `operation`, throwing ``ServiceRemoteError`` if it hasn't finished within `duration`.
///
/// An XPC reply block that never fires would otherwise leave the caller suspended forever — there is
/// no built-in deadline on `xpc_connection_send_message_with_reply`.
func withTimeout<Result: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
  try await withThrowingTaskGroup(of: Result.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw ServiceRemoteError(
        message: "The helper request timed out after \(duration.components.seconds)s")
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw ServiceRemoteError(message: "The helper request produced no result")
    }
    return result
  }
}
