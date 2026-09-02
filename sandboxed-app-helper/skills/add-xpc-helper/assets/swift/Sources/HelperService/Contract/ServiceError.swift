import Foundation

/// A failure that crossed the XPC boundary, carried inside ``ServiceResponse/failure(_:)``.
///
/// It is `Codable` because it travels on the wire, so its case names are part of the frozen wire
/// format — an older helper decoding a case it doesn't know about fails the whole reply.
public enum ServiceError: Error, Codable, Sendable, Equatable {

  /// A failure described only by its message.
  case message(String)

  /// The helper doesn't implement the request — usually an app that is newer than the helper.
  case unsupportedRequest(String)

  /// Wraps any local error for transport, preserving its description.
  public init(_ error: any Error) {
    if let error = error as? ServiceError {
      self = error
    } else {
      self = .message(String(describing: error))
    }
  }

  /// A developer-facing description of the failure.
  public var errorDescription: String {
    switch self {
    case .message(let message): message
    case .unsupportedRequest(let request): "The installed helper doesn't support \(request)."
    }
  }
}

extension ServiceError: LocalizedError {

  public var failureReason: String? { errorDescription }
}
