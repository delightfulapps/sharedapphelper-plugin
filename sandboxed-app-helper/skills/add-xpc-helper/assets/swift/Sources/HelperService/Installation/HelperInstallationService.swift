import CryptoKit
import Foundation
import OSLog

/// Reports the status of, and downloads, the separately-distributed helper.
///
/// The final *placement* of the download is user-consented and belongs in the UI layer (a save
/// panel), because a sandboxed app can't move an app into `/Applications` itself.
public protocol HelperInstallationService: Sendable {

  /// The current install status of the helper.
  func status() async -> HelperInstallationStatus

  /// The newest release compatible with this app and OS, or `nil` when the manifest can't be read or
  /// nothing compatible exists. Best-effort and never throws, so a settings tab can still show the
  /// latest release's size and notes when the install is missing or stale.
  func latestVersion() async -> HelperVersion?

  /// Fetches the manifest and downloads the newest compatible archive into the app's container.
  func downloadLatest() async throws -> DownloadedHelper
}

/// A failure while checking for or downloading the helper.
public enum HelperInstallationError: Error, Sendable, Equatable {

  /// The release manifest couldn't be fetched or decoded.
  case manifest(String)

  /// The archive download failed.
  case download(String)

  /// The downloaded archive didn't match the manifest's published size or checksum.
  case integrity(String)

  /// A developer-facing description, for the log. Show the user something friendlier.
  public var message: String {
    switch self {
    case .manifest(let reason): "Couldn't check for the helper: \(reason)"
    case .download(let reason): "Download failed: \(reason)"
    case .integrity(let reason): "The download didn't match its published checksum: \(reason)"
    }
  }
}

/// The production ``HelperInstallationService``.
///
/// Its two collaborators are injected as closures rather than protocols so the package stays
/// dependency-free: pass the app's own HTTP layer and helper-version probe if it has them, or accept
/// the defaults (`URLSession.shared`, and a fresh ``HelperServiceClient`` probe).
public struct LiveHelperInstallationService: HelperInstallationService {

  private static let logger = Logger(
    subsystem: "{{APP_BUNDLE_ID}}",
    category: "HelperInstallation"
  )

  /// The host serving `versions.json` and the archives.
  ///
  /// Build-configuration driven: see the xcconfig reference. The app reads a scheme-less host from
  /// its `Info.plist` and prepends `https://`, because `//` starts a comment in an xcconfig.
  private let baseURL: URL

  /// The running app and OS versions used to filter the manifest.
  private let appVersion: AppVersion

  /// Performs an HTTP request. Injected so tests never touch the network.
  private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  /// Reports the installed helper's version, or `nil` if none is reachable.
  ///
  /// Injected so the version-comparison logic is testable without a live Mach service.
  private let installedVersion: @Sendable () async -> String?

  /// Creates a live service targeting `baseURL` for `appVersion`.
  public init(
    baseURL: URL,
    appVersion: AppVersion = .current,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    },
    installedVersion: (@Sendable () async -> String?)? = nil
  ) {
    self.baseURL = baseURL
    self.appVersion = appVersion
    self.transport = transport
    self.installedVersion =
      installedVersion ?? { await HelperServiceClient().installedHelperVersion() }
  }

  /// Whether a helper is installed and, if so, whether a newer compatible release exists.
  ///
  /// Degrades to local presence alone when the manifest can't be reached, so an offline launch still
  /// reports an installed helper rather than none.
  public func status() async -> HelperInstallationStatus {
    let installed = await installedVersion()
    guard let release = try? await latestCompatibleVersion() else {
      return installed.map(HelperInstallationStatus.installed) ?? .notInstalled
    }
    guard let installed else { return .notInstalled }
    // Only a *strictly newer* release is an update: a locally built helper running ahead of the
    // manifest is up to date, not perpetually out of date.
    return VersionOrdering.isNewer(release.version, than: installed)
      ? .outdated(installedVersion: installed, latestVersion: release.version)
      : .installed(version: installed)
  }

  /// The newest compatible release, or `nil` when there is none or the manifest can't be read.
  public func latestVersion() async -> HelperVersion? {
    try? await latestCompatibleVersion()
  }

  /// Downloads the newest compatible release, validates it, and writes it into the app's container.
  public func downloadLatest() async throws -> DownloadedHelper {
    let release = try await latestCompatibleVersion()
    Self.logger.info(
      "Downloading helper \(release.version, privacy: .public) from \(release.url.absoluteString, privacy: .public)"
    )

    let (data, response) = try await transport(URLRequest(url: release.url))
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw HelperInstallationError.download(
        "unexpected response (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
    }

    // The helper runs unsandboxed on the user's machine, so refuse any archive that doesn't match
    // the manifest exactly before it ever touches disk.
    try verifyIntegrity(of: data, against: release)

    let filename =
      release.url.lastPathComponent.isEmpty ? "{{HELPER_NAME}}.zip" : release.url.lastPathComponent
    let destination: URL
    do {
      // A fresh per-download directory plus an atomic write, so a retry racing a prior run can never
      // interleave with, or truncate, this one.
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "helper-download-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      destination = directory.appending(path: filename)
      try data.write(to: destination, options: .atomic)
    } catch {
      throw HelperInstallationError.download(
        "couldn't write the download: \(error.localizedDescription)")
    }
    return DownloadedHelper(
      localURL: destination, version: release.version, suggestedFilename: filename)
  }

  /// Fetches `versions.json` and returns the newest build compatible with ``appVersion``.
  func latestCompatibleVersion() async throws -> HelperVersion {
    let url = baseURL.appending(path: "versions.json")
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await transport(URLRequest(url: url))
    } catch {
      throw HelperInstallationError.manifest(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw HelperInstallationError.manifest(
        "unexpected response (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
    }
    let versions: [HelperVersion]
    do {
      versions = try JSONDecoder().decode([HelperVersion].self, from: data)
    } catch {
      throw HelperInstallationError.manifest("malformed manifest")
    }
    // Manifest order isn't trusted — a host may publish entries in any order — so take the highest
    // supported version rather than the first. Trusting a newest-first ordering makes an oldest-first
    // manifest report its *oldest* release as the latest, and updates are never detected.
    guard let compatible = versions.filter(appVersion.supports).max(by: { $1.isNewer(than: $0) })
    else {
      throw HelperInstallationError.manifest("no compatible helper version")
    }
    return compatible
  }

  /// Verifies `data` against the manifest's published `size` and `sha256`.
  ///
  /// Strict on purpose: an entry that omits either field is itself an integrity failure. The
  /// alternative — trusting an unverified archive — hands an unsandboxed binary to the user.
  private func verifyIntegrity(of data: Data, against release: HelperVersion) throws {
    guard let size = release.size else {
      throw fail("the manifest didn't publish a size for \(release.version)")
    }
    guard data.count == size else {
      throw fail("expected \(size) bytes but got \(data.count)")
    }
    guard let expectedDigest = release.sha256 else {
      throw fail("the manifest didn't publish a checksum for \(release.version)")
    }
    let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
      throw fail("expected SHA-256 \(expectedDigest) but got \(actualDigest)")
    }
  }

  /// Logs and returns an integrity failure.
  private func fail(_ reason: String) -> HelperInstallationError {
    Self.logger.error("Helper download failed its integrity check: \(reason, privacy: .public)")
    return .integrity(reason)
  }
}

/// A configurable ``HelperInstallationService`` for tests and previews.
public struct StubHelperInstallationService: HelperInstallationService {

  private let statusResult: HelperInstallationStatus
  private let latestVersionResult: HelperVersion?
  private let downloadError: HelperInstallationError?
  private let downloadResult: DownloadedHelper

  /// Creates a stub reporting `status`, offering `latestVersion`, and returning `downloadResult`
  /// from ``downloadLatest()`` unless `downloadError` is set.
  public init(
    status: HelperInstallationStatus = .notInstalled,
    latestVersion: HelperVersion? = nil,
    downloadError: HelperInstallationError? = nil,
    downloadResult: DownloadedHelper = DownloadedHelper(
      localURL: URL(filePath: NSTemporaryDirectory()).appending(path: "{{HELPER_NAME}}.zip"),
      version: "1.0",
      suggestedFilename: "{{HELPER_NAME}}.zip"
    )
  ) {
    self.statusResult = status
    self.latestVersionResult = latestVersion
    self.downloadError = downloadError
    self.downloadResult = downloadResult
  }

  public func status() async -> HelperInstallationStatus { statusResult }

  public func latestVersion() async -> HelperVersion? { latestVersionResult }

  public func downloadLatest() async throws -> DownloadedHelper {
    if let downloadError { throw downloadError }
    return downloadResult
  }
}
