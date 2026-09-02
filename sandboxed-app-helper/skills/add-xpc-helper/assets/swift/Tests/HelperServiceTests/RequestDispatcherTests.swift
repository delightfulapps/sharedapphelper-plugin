import Foundation
import Testing

@testable import {{PACKAGE_NAME}}

@Suite("Request dispatch")
struct RequestDispatcherTests {

  /// Records what it was asked, and can be told to fail.
  private struct RecordingHandler: HelperRequestHandling {
    var error: (any Error)?

    func respond(to request: ServiceRequest) async throws -> ServiceResponse {
      if let error { throw error }
      guard case .echo(let message) = request else {
        return .failure(.unsupportedRequest(String(describing: request)))
      }
      return .echo(message: message)
    }
  }

  @Test("Ping is answered by the package, not the app's handler")
  func pingIsHandledInternally() async {
    let dispatcher = RequestDispatcher(handler: RecordingHandler(error: ServiceError.message("x")))
    #expect(await dispatcher.response(for: .ping) == .ok)
  }

  @Test("Helper info reports this process's bundle version")
  func helperInfoUsesTheBundle() async {
    let dispatcher = RequestDispatcher(handler: RecordingHandler())
    guard case .helperInfo = await dispatcher.response(for: .helperInfo) else {
      Issue.record("expected a helperInfo response")
      return
    }
  }

  @Test("Other requests reach the app's handler")
  func requestsReachTheHandler() async {
    let dispatcher = RequestDispatcher(handler: RecordingHandler())
    #expect(await dispatcher.response(for: .echo(message: "hi")) == .echo(message: "hi"))
  }

  @Test("A thrown error becomes a failure reply rather than no reply at all")
  func thrownErrorsBecomeFailures() async {
    let dispatcher = RequestDispatcher(
      handler: RecordingHandler(error: ServiceError.message("boom")))
    #expect(await dispatcher.response(for: .echo(message: "hi")) == .failure(.message("boom")))
  }
}
