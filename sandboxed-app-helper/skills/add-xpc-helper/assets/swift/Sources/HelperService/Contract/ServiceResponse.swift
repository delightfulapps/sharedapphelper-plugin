/// A reply the helper sends back to the app.
///
/// Same frozen-wire-format rule as ``ServiceRequest``: add cases, never repurpose one.
public enum ServiceResponse: Codable, Sendable, Equatable {

  /// The request succeeded and carries no value.
  case ok

  /// The helper's own `CFBundleShortVersionString`.
  case helperInfo(version: String)

  /// The echoed message from ``ServiceRequest/echo(message:)``.
  case echo(message: String)

  /// The request failed; the reason crossed the wire in `error`.
  case failure(ServiceError)
}
