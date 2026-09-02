/// Unwrapping helpers that turn an unexpected response — including an explicit `.failure` — into a
/// thrown error, so callers can write straight-line code instead of switching over every reply.
extension ServiceResponse {

  /// Succeeds for `.ok`, throwing the carried error otherwise.
  public func ok() throws {
    switch self {
    case .ok: return
    case .failure(let error): throw error
    default: throw unexpected("ok")
    }
  }

  /// The helper's version, or the carried error.
  public func helperVersion() throws -> String {
    switch self {
    case .helperInfo(let version): return version
    case .failure(let error): throw error
    default: throw unexpected("helperInfo")
    }
  }

  /// The echoed message, or the carried error.
  public func echoedMessage() throws -> String {
    switch self {
    case .echo(let message): return message
    case .failure(let error): throw error
    default: throw unexpected("echo")
    }
  }

  private func unexpected(_ expected: String) -> ServiceError {
    .message("Expected a \(expected) response but received \(self)")
  }
}
