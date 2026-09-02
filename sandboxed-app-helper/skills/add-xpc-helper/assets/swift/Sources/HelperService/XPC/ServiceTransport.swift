/// How long to wait for a reply before giving up.
///
/// One value covers most services. If some requests are far slower than others — a build, a large
/// render — give ``ServiceRequest`` a `timeout` property that switches on the case, and use it in
/// ``MachConnectionTransport/send(_:)`` instead of this constant. A single generous timeout is worse
/// than a per-request one: it makes the fast failures slow.
let serviceRequestTimeout: Duration = .seconds(60)

/// A live connection to the out-of-process helper.
///
/// A protocol rather than a concrete type so tests can drive the client without a real Mach service.
protocol ServiceTransport: Sendable {

  /// Sends `request` to the helper and awaits its reply.
  func send(_ request: ServiceRequest) async throws -> ServiceResponse

  /// Tears the connection down, failing every request still in flight.
  func cancel(reason: String) async
}
