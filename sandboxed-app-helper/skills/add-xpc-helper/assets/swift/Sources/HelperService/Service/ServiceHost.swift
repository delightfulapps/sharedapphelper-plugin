/// The helper's entry point: it vends the launchd Mach service the app connects to.
public enum ServiceHost {

  /// Creates and resumes the Mach service listener, returning a handle that keeps it alive.
  ///
  /// **Retain the returned handle** for as long as the helper should serve — releasing it cancels
  /// the listener and the app's connections start failing with "Connection invalid".
  @discardableResult
  public static func startMachServiceListener(
    handler: any HelperRequestHandling,
    peerRequirement: String = {{SYMBOL_PREFIX}}PeerCodeSigningRequirement
  ) -> ServiceListenerHandle {
    MachServiceListener.start(handler: handler, peerRequirement: peerRequirement)
  }
}
