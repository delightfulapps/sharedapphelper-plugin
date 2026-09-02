import Foundation

/// Serves each ``ServiceRequest``, answering the universal ones itself and passing the rest to the
/// app's ``HelperRequestHandling``.
struct RequestDispatcher: Sendable {

  private let handler: any HelperRequestHandling

  init(handler: any HelperRequestHandling) {
    self.handler = handler
  }

  /// Serves one request, reporting a thrown error as a `.failure` reply rather than dropping it.
  ///
  /// A peer that gets no reply waits until its timeout, which turns a clear error into a slow,
  /// mysterious one.
  func response(for request: ServiceRequest) async -> ServiceResponse {
    do {
      return try await perform(request)
    } catch {
      return .failure(ServiceError(error))
    }
  }

  /// Releases whatever the departing peer's work was holding.
  func peerDisconnected() async {
    await handler.peerDisconnected()
  }

  private func perform(_ request: ServiceRequest) async throws -> ServiceResponse {
    switch request {
    case .ping:
      return .ok
    case .helperInfo:
      // Answered here, from this process's own bundle, because the whole point of the probe is to
      // learn which helper build is installed.
      return .helperInfo(version: Self.helperBundleVersion())
    default:
      return try await handler.respond(to: request)
    }
  }

  /// The helper's own marketing version, or an empty string if it can't be read.
  private static func helperBundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }
}
