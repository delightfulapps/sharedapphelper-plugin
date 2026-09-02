import Foundation

/// The request/reply exchanges a transport has in flight, keyed by request.
///
/// Tracking them is what lets a dropped connection fail every waiting caller instead of leaving
/// continuations suspended forever.
struct PendingReplies {

  private var continuations: [UUID: CheckedContinuation<ServiceResponse, any Error>] = [:]

  /// Registers `continuation` under `id` so a teardown can fail it.
  mutating func register(
    _ id: UUID,
    _ continuation: CheckedContinuation<ServiceResponse, any Error>
  ) {
    continuations[id] = continuation
  }

  /// Completes the reply for `id`, unless a teardown already failed it.
  mutating func complete(_ id: UUID, with result: Result<ServiceResponse, any Error>) {
    continuations.removeValue(forKey: id)?.resume(with: result)
  }

  /// Fails every reply still in flight with `error`.
  mutating func failAll(_ error: any Error) {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending.values {
      continuation.resume(throwing: error)
    }
  }
}
