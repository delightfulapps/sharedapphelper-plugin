import Foundation

/// The install status of the separately-distributed helper.
///
/// This is the persistent, service-level status a settings tab shows. Transient phases — checking,
/// downloading, failed — belong in the view model driving that tab, not here.
public enum HelperInstallationStatus: Sendable, Equatable {

  /// No helper is installed, or none can be reached.
  case notInstalled

  /// The helper is installed at `version` and is current — either matching the newest compatible
  /// release or ahead of it (a locally built helper).
  case installed(version: String)

  /// The helper is installed but a newer compatible release has been published.
  case outdated(installedVersion: String, latestVersion: String)

  /// Whether a helper is installed at all, current or not.
  public var isInstalled: Bool {
    switch self {
    case .notInstalled: false
    case .installed, .outdated: true
    }
  }
}

/// A helper archive downloaded into the app's container, awaiting the user's consent to place it.
///
/// A sandboxed app can't unarchive in-process or move an app into `/Applications`, so the last step
/// is always the user's.
public struct DownloadedHelper: Sendable, Equatable {

  /// The downloaded archive's location inside the app's container.
  public let localURL: URL

  /// The version this archive contains.
  public let version: String

  /// A suggested file name to present in the save panel.
  public let suggestedFilename: String

  /// Creates a downloaded-helper value.
  public init(localURL: URL, version: String, suggestedFilename: String) {
    self.localURL = localURL
    self.version = version
    self.suggestedFilename = suggestedFilename
  }
}
