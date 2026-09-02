/// What the helper actually does, for the requests only it can serve.
///
/// The package handles the plumbing — the listener, peer verification, decoding, replies — and
/// handles ``ServiceRequest/ping`` and ``ServiceRequest/helperInfo`` itself, because those mean the
/// same thing in every project. Everything else is the adopting app's business, so implement this in
/// the helper target with the real work: spawning the tool, reading the file, driving the other app.
///
/// Implementations run off the main actor and may serve several peers at once, so keep them
/// `Sendable` and don't assume a single caller.
public protocol HelperRequestHandling: Sendable {

  /// Serves one request. Throwing is fine — the dispatcher converts it into a
  /// ``ServiceResponse/failure(_:)`` reply, so the peer always gets an answer.
  func respond(to request: ServiceRequest) async throws -> ServiceResponse

  /// Called when a peer goes away, for releasing whatever that peer's work was holding.
  func peerDisconnected() async
}

extension HelperRequestHandling {

  /// Most helpers hold nothing per-peer, so this defaults to doing nothing.
  public func peerDisconnected() async {}
}
