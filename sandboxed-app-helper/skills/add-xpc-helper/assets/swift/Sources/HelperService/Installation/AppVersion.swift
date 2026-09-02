import Foundation

/// The running app and OS versions, used to select a compatible ``HelperVersion``.
public struct AppVersion: Sendable, Equatable, Hashable {

  /// The app's marketing version (`CFBundleShortVersionString`).
  public let marketingVersion: String

  /// The running macOS version, compared against a helper's `minimumSystemVersion`.
  public let systemVersion: String

  /// Creates an app version value.
  public init(marketingVersion: String, systemVersion: String) {
    self.marketingVersion = marketingVersion
    self.systemVersion = systemVersion
  }

  /// Whether this app and OS can run `helper` — both floors must be met.
  public func supports(_ helper: HelperVersion) -> Bool {
    VersionOrdering.isAtLeast(marketingVersion, helper.minimumAppVersion)
      && VersionOrdering.isAtLeast(systemVersion, helper.minimumSystemVersion)
  }

  /// The current app version, read from the main bundle and the running OS.
  public static var current: AppVersion {
    let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return AppVersion(
      marketingVersion: marketing ?? "0",
      systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    )
  }
}
