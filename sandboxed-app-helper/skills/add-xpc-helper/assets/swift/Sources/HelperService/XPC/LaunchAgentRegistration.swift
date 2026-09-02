import Foundation
import OSLog
import ServiceManagement

/// Registers the helper as a launchd `LaunchAgent` that owns the ``{{SYMBOL_PREFIX}}Name`` Mach
/// service.
///
/// The **helper** does this, not the app: a sandboxed process gets `Operation not permitted` from
/// `SMAppService.agent().register()`, and registering synchronously from an app's `init` blocks
/// launch. A plain app also can't self-advertise a *global* Mach name — launchd has to own it — so
/// the resident, service-owning instance is always the launchd-launched one.
public enum LaunchAgentRegistration {

  private static let logger = Logger(
    subsystem: "{{HELPER_BUNDLE_ID}}",
    category: "LaunchAgentRegistration"
  )

  /// `UserDefaults` key under which the last successfully registered build identifier is persisted.
  private static let lastRegisteredBuildKey = "LaunchAgentRegistration.lastRegisteredBuild"

  /// Registers the launch agent, refreshing it whenever the running build differs from the one it was
  /// last registered for.
  ///
  /// `status == .enabled` only means *a* registration exists — not that it points at this build's
  /// executable. A registration records the agent's program path at registration time, so after an
  /// update the recorded job still points at the previous build. launchd can no longer bootstrap it,
  /// and the Mach service ends up advertised but **unbacked**: `launchctl print gui/<uid>` lists it
  /// enabled, yet looking the service itself up fails, and the app's handshake dies with
  /// "Connection invalid". Recording the build and re-registering on any change bumps the job
  /// generation and self-heals a machine already stuck that way.
  public static func registerAgentIfNeeded() {
    guard HostProcessProbe.isSandboxed == false else {
      logger.debug("Skipping launch-agent registration: this process is sandboxed.")
      return
    }
    let service = SMAppService.agent(plistName: {{SYMBOL_PREFIX}}LaunchAgentPlistName)
    let currentBuild = currentBuildIdentifier

    if service.status == .enabled, lastRegisteredBuild == currentBuild {
      logger.debug("Launch agent already registered for build \(currentBuild, privacy: .public).")
      return
    }

    if service.status == .enabled {
      do {
        try service.unregister()
        logger.info("Unregistered a stale launch agent before re-registering.")
      } catch {
        logger.error("Failed to unregister the stale launch agent: \(error, privacy: .public)")
      }
    }

    do {
      try service.register()
      lastRegisteredBuild = currentBuild
      logger.info(
        "Registered launch agent (\({{SYMBOL_PREFIX}}LaunchAgentPlistName, privacy: .public)) for build \(currentBuild, privacy: .public)."
      )
    } catch {
      logger.error("Failed to register the launch agent: \(error, privacy: .public)")
    }
  }

  /// A stable identifier for the running helper build.
  private static var currentBuildIdentifier: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// The build identifier the launch agent was last successfully registered for.
  private static var lastRegisteredBuild: String? {
    get { UserDefaults.standard.string(forKey: lastRegisteredBuildKey) }
    set { UserDefaults.standard.set(newValue, forKey: lastRegisteredBuildKey) }
  }
}
