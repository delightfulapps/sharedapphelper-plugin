import Foundation

/// A single helper release as published in the distribution host's `versions.json` manifest.
///
/// The manifest is an array of these in **no guaranteed order**. Each entry carries the compatibility
/// floors that let the app pick the newest build it can actually run.
public struct HelperVersion: Sendable, Equatable, Codable {

  /// The helper release version — this is what is compared against the installed helper's
  /// `CFBundleShortVersionString`.
  public let version: String

  /// The monotonic build number, used to break ties between two entries at the same version.
  public let build: String

  /// The release date, formatted `YYYY-MM-DD`.
  public let releaseDate: String

  /// The minimum macOS version required to run this helper build.
  public let minimumSystemVersion: String

  /// The minimum app version that supports this helper build.
  public let minimumAppVersion: String

  /// The download URL for the release archive. Absolute, and ideally immutable per version.
  public let url: URL

  /// The size of the release archive in bytes. Optional in the type, **required** in practice:
  /// a missing value is treated as an integrity failure.
  public let size: Int?

  /// The SHA-256 hex digest of the release archive. Same rule as ``size``.
  public let sha256: String?

  /// Human-readable release notes.
  public let notes: String

  /// Creates a helper release value.
  public init(
    version: String,
    build: String,
    releaseDate: String,
    minimumSystemVersion: String,
    minimumAppVersion: String,
    url: URL,
    size: Int?,
    sha256: String?,
    notes: String
  ) {
    self.version = version
    self.build = build
    self.releaseDate = releaseDate
    self.minimumSystemVersion = minimumSystemVersion
    self.minimumAppVersion = minimumAppVersion
    self.url = url
    self.size = size
    self.sha256 = sha256
    self.notes = notes
  }

  /// Whether this release is newer than `other`, comparing ``version`` then ``build`` numerically.
  ///
  /// Deliberately not a `Comparable` conformance: ``Equatable`` here covers every field, so `<` and
  /// `==` would disagree for two entries that share a version and build but differ elsewhere.
  public func isNewer(than other: HelperVersion) -> Bool {
    if version != other.version {
      return VersionOrdering.isNewer(version, than: other.version)
    }
    return VersionOrdering.isNewer(build, than: other.build)
  }
}
