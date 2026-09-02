/// A request the app sends to the helper.
///
/// This is the extension point: add the operations the app actually needs the helper to perform.
/// Both processes are built from this one definition, but they are **separately distributed** — a
/// user can be running last month's helper against today's app — so treat the encoded form as a
/// frozen wire format. Add cases; don't rename or reorder the existing ones, and don't change an
/// associated value's label, or an older helper will fail to decode the message.
public enum ServiceRequest: Codable, Sendable, Equatable {

  /// A liveness check. The helper replies `.ok`.
  case ping

  /// Asks the helper for its own bundle version, used to detect what is installed.
  case helperInfo

  /// A placeholder round-trip, useful while wiring the connection up for the first time.
  /// Replace it with the app's real operations.
  case echo(message: String)
}
