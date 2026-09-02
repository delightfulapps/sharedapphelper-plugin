import Foundation
import Testing
import XPC

@testable import {{PACKAGE_NAME}}

/// Round-trips through a real `xpc_object_t` dictionary, because the payload key and the JSON
/// encoding are the one place the two processes have to agree byte for byte.
@Suite("XPC payload coding")
struct PayloadCodingTests {

  @Test("A request survives a round trip through an XPC message")
  func requestRoundTrip() throws {
    let request = ServiceRequest.echo(message: "hello")
    let message = try makeMessage(request)
    #expect(try decodePayload(ServiceRequest.self, from: message) == request)
  }

  @Test("A response survives a round trip through an XPC message")
  func responseRoundTrip() throws {
    let response = ServiceResponse.helperInfo(version: "2026.4")
    let message = try makeMessage(response)
    #expect(try decodePayload(ServiceResponse.self, from: message) == response)
  }

  @Test("A message without a payload reports a decoding failure rather than crashing")
  func missingPayload() {
    let empty = xpc_dictionary_create_empty()
    #expect(throws: ServiceRemoteError.self) {
      try decodePayload(ServiceRequest.self, from: empty)
    }
  }
}
