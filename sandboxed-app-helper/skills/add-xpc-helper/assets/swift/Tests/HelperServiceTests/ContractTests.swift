import Foundation
import Testing

@testable import {{PACKAGE_NAME}}

/// The app and the helper ship separately, so an older helper may decode a newer app's message. These
/// tests pin the encoded shape: if one fails, the change is a wire-format break and needs a new case
/// rather than an edit to an existing one.
@Suite("Wire contract")
struct ContractTests {

  @Test("Requests round-trip through JSON")
  func requestCoding() throws {
    for request in [ServiceRequest.ping, .helperInfo, .echo(message: "hi")] {
      let data = try JSONEncoder().encode(request)
      #expect(try JSONDecoder().decode(ServiceRequest.self, from: data) == request)
    }
  }

  @Test("Request case names are stable on the wire")
  func requestKeysAreStable() throws {
    let json = String(decoding: try JSONEncoder().encode(ServiceRequest.helperInfo), as: UTF8.self)
    #expect(json.contains("helperInfo"))
  }

  @Test("A failure response carries its error across the wire")
  func failureCoding() throws {
    let response = ServiceResponse.failure(.unsupportedRequest("render"))
    let data = try JSONEncoder().encode(response)
    #expect(try JSONDecoder().decode(ServiceResponse.self, from: data) == response)
  }

  @Test("Unwrapping a failure rethrows the carried error")
  func unwrappingRethrows() {
    #expect(throws: ServiceError.message("boom")) {
      try ServiceResponse.failure(.message("boom")).ok()
    }
  }

  @Test("Unwrapping the wrong case reports what was expected")
  func unwrappingMismatch() {
    #expect(throws: ServiceError.self) {
      try ServiceResponse.ok.helperVersion()
    }
  }

  @Test("The peer requirement pins the team and both Apple re-signing channels")
  func peerRequirementBranches() {
    let requirement = {{SYMBOL_PREFIX}}PeerCodeSigningRequirement
    #expect(requirement.contains({{SYMBOL_PREFIX}}TeamIdentifier))
    // Mac App Store and TestFlight leaf-certificate marker OIDs. Without these, Apple-re-signed
    // builds carry no team OU and every message from them is silently dropped.
    #expect(requirement.contains("1.2.840.113635.100.6.1.9"))
    #expect(requirement.contains("1.2.840.113635.100.6.1.25.1"))
    #expect(requirement.contains({{SYMBOL_PREFIX}}AppBundleIdentifier))
  }

  @Test("The launch agent plist file name matches the service name")
  func launchAgentPlistNameMatchesLabel() {
    // launchd requires the plist's base name to equal its Label, and SMAppService looks it up by
    // file name. Drift here produces a service that is advertised but unreachable.
    #expect({{SYMBOL_PREFIX}}LaunchAgentPlistName == "\({{SYMBOL_PREFIX}}Name).plist")
  }
}
