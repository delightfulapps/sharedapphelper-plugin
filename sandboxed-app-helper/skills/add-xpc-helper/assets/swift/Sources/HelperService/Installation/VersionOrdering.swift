import Foundation

/// Compares dotted version strings (`2026.4`, `26.0.1`) by their **numeric** components.
///
/// Lexical comparison gets these wrong — `"2026.10" < "2026.2"` as plain strings — which makes a
/// newer release look older, so updates are never detected. Every version comparison in this feature
/// routes through here so there is exactly one rule.
public enum VersionOrdering {

  /// Whether `version` is greater than or equal to `minimum`.
  public static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
    version.compare(minimum, options: .numeric) != .orderedAscending
  }

  /// Whether `version` is strictly greater than `other`.
  public static func isNewer(_ version: String, than other: String) -> Bool {
    version.compare(other, options: .numeric) == .orderedDescending
  }
}
