import Foundation

/// A local transport failure — the connection dropped, a reply timed out, a message wouldn't decode.
///
/// Distinct from ``ServiceError``, which is a failure the *peer* reported and which therefore has to
/// be `Codable`. This one never crosses the wire.
public struct ServiceRemoteError: Error, Equatable, Sendable, LocalizedError {

  /// What went wrong.
  public let message: String

  /// Creates a transport failure described by `message`.
  public init(message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}
