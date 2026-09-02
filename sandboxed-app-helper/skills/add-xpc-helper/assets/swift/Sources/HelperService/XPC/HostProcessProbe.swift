import Security

/// Facts about the running process that the service code branches on.
enum HostProcessProbe {

  /// Whether the current process carries the App Sandbox entitlement, read from its own code
  /// signature.
  ///
  /// The same package is linked into both the sandboxed app and the unsandboxed helper, so code that
  /// only makes sense on one side — registering the launch agent — asks this rather than assuming.
  static var isSandboxed: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
    return (value as? Bool) ?? false
  }
}
