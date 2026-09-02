import Foundation
import Testing

@testable import {{PACKAGE_NAME}}

@Suite("Helper installation")
struct HelperInstallationServiceTests {

  private static let host = URL(string: "https://example.test")!

  private static func release(
    version: String,
    build: String = "1",
    minimumAppVersion: String = "1.0",
    minimumSystemVersion: String = "15.0",
    size: Int? = 4,
    sha256: String? = nil
  ) -> HelperVersion {
    HelperVersion(
      version: version,
      build: build,
      releaseDate: "2026-01-01",
      minimumSystemVersion: minimumSystemVersion,
      minimumAppVersion: minimumAppVersion,
      url: host.appending(path: "downloads/helper-\(version).zip"),
      size: size,
      sha256: sha256 ?? Self.digestOfPayload,
      notes: ""
    )
  }

  /// The bytes every stub download returns, and their digest.
  private static let payload = Data("zip!".utf8)
  private static let digestOfPayload =
    "4cd9b57e1660bd4d4082f5fdef9ca0f9a157fa96a7ebca2dd1f1faa1b6cc5af3"

  /// Serves `manifest` at `versions.json` and `body` for anything else.
  private static func transport(
    manifest: [HelperVersion],
    body: Data = payload,
    status: Int = 200
  ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
      let url = request.url!
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
      if url.lastPathComponent == "versions.json" {
        return (try JSONEncoder().encode(manifest), response)
      }
      return (body, response)
    }
  }

  private static func service(
    manifest: [HelperVersion],
    body: Data = payload,
    status: Int = 200,
    appVersion: AppVersion = AppVersion(marketingVersion: "2026.4", systemVersion: "26.0"),
    installed: String? = nil
  ) -> LiveHelperInstallationService {
    LiveHelperInstallationService(
      baseURL: host,
      appVersion: appVersion,
      transport: transport(manifest: manifest, body: body, status: status),
      installedVersion: { installed }
    )
  }

  @Test("The newest compatible release wins regardless of manifest order")
  func manifestOrderIsNotTrusted() async throws {
    let service = Self.service(manifest: [Self.release(version: "2026.2"), Self.release(version: "2026.10")])
    #expect(try await service.latestCompatibleVersion().version == "2026.10")
  }

  @Test("Versions compare numerically, not lexically")
  func numericVersionOrdering() {
    #expect(VersionOrdering.isNewer("2026.10", than: "2026.2"))
    #expect(VersionOrdering.isAtLeast("26.0.1", "26.0"))
  }

  @Test("Builds break a tie at the same version")
  func buildBreaksTies() async throws {
    let service = Self.service(manifest: [
      Self.release(version: "2026.4", build: "9"),
      Self.release(version: "2026.4", build: "12"),
    ])
    #expect(try await service.latestCompatibleVersion().build == "12")
  }

  @Test("Releases the app is too old for are filtered out")
  func incompatibleReleasesAreSkipped() async {
    let service = Self.service(
      manifest: [Self.release(version: "2027.1", minimumAppVersion: "2027.0")])
    await #expect(throws: HelperInstallationError.self) {
      try await service.latestCompatibleVersion()
    }
  }

  @Test("No helper reachable reads as not installed")
  func notInstalled() async {
    let service = Self.service(manifest: [Self.release(version: "2026.4")], installed: nil)
    #expect(await service.status() == .notInstalled)
  }

  @Test("A newer published release reads as outdated")
  func outdated() async {
    let service = Self.service(manifest: [Self.release(version: "2026.5")], installed: "2026.4")
    #expect(
      await service.status() == .outdated(installedVersion: "2026.4", latestVersion: "2026.5"))
  }

  @Test("A helper ahead of the manifest reads as up to date, not outdated")
  func locallyBuiltHelperIsUpToDate() async {
    let service = Self.service(manifest: [Self.release(version: "2026.4")], installed: "2026.9")
    #expect(await service.status() == .installed(version: "2026.9"))
  }

  @Test("A checksum mismatch discards the download")
  func checksumMismatchFails() async {
    let service = Self.service(
      manifest: [Self.release(version: "2026.4", sha256: String(repeating: "a", count: 64))])
    await #expect(throws: HelperInstallationError.self) { try await service.downloadLatest() }
  }

  @Test("A size mismatch discards the download")
  func sizeMismatchFails() async {
    let service = Self.service(manifest: [Self.release(version: "2026.4", size: 99)])
    await #expect(throws: HelperInstallationError.self) { try await service.downloadLatest() }
  }

  @Test("A manifest that omits size or checksum is itself an integrity failure")
  func missingIntegrityFieldsFail() async {
    let noSize = Self.service(manifest: [Self.release(version: "2026.4", size: nil)])
    await #expect(throws: HelperInstallationError.self) { try await noSize.downloadLatest() }

    let noDigest = Self.service(manifest: [Self.release(version: "2026.4", sha256: "")])
    await #expect(throws: HelperInstallationError.self) { try await noDigest.downloadLatest() }
  }

  @Test("A verified download lands on disk")
  func verifiedDownloadSucceeds() async throws {
    let service = Self.service(manifest: [Self.release(version: "2026.4")])
    let downloaded = try await service.downloadLatest()
    #expect(downloaded.version == "2026.4")
    #expect(FileManager.default.fileExists(atPath: downloaded.localURL.path))
    try? FileManager.default.removeItem(at: downloaded.localURL.deletingLastPathComponent())
  }
}
