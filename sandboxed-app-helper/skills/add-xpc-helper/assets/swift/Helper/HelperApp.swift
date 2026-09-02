import AppKit
import Observation
import SwiftUI
import {{PACKAGE_NAME}}

/// The helper's `@main`. Copy this into the helper target and replace ``LiveRequestHandler`` with the
/// work the app actually needs done out of the sandbox.
///
/// It is a menubar (`LSUIElement`) app with a real `NSApplication` lifecycle rather than a bare
/// command-line tool, so the user can see it is running and quit it — a background process with no
/// visible surface is one users can't reason about.
@main
struct {{HELPER_NAME}}App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = HelperServiceModel.shared

  var body: some Scene {
    MenuBarExtra {
      Text("{{HELPER_NAME}} \(Self.versionString)")
      Divider()
      Text(model.isConnected ? "Connected (\(model.activeConnections))" : "Idle")
      Divider()
      Button("Quit {{HELPER_NAME}}") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      Image(systemName: model.isConnected ? "bolt.fill" : "bolt")
    }
  }

  /// The helper's marketing and build version, e.g. "2026.4 (1)".
  private static var versionString: String {
    let info = Bundle.main.infoDictionary
    let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(marketing) (\(build))"
  }
}

/// Observable state backing the menu's live connected/idle indicator.
@MainActor
@Observable
final class HelperServiceModel {
  static let shared = HelperServiceModel()

  /// The number of app peers currently connected.
  var activeConnections = 0

  /// Whether at least one peer is connected.
  var isConnected: Bool { activeConnections > 0 }

  private init() {}
}

/// The app's real work, done outside the sandbox. Replace the placeholder case.
struct LiveRequestHandler: HelperRequestHandling {

  func respond(to request: ServiceRequest) async throws -> ServiceResponse {
    switch request {
    case .echo(let message):
      return .echo(message: message)
    default:
      // `ping` and `helperInfo` never reach here — the package answers those itself.
      return .failure(.unsupportedRequest(String(describing: request)))
    }
  }
}

/// Owns the helper's process lifecycle: agent registration, single-instance enforcement, and the
/// Mach service listener.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

  /// Retains the running listener; dropping it cancels the service.
  private var listenerHandle: ServiceListenerHandle?

  /// Mirrors the listener's peer count onto ``HelperServiceModel``.
  private var connectionCountTask: Task<Void, Never>?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard shouldKeepRunning() else {
      NSApplication.shared.terminate(nil)
      return
    }

    LaunchAgentRegistration.registerAgentIfNeeded()

    let handle = ServiceHost.startMachServiceListener(handler: LiveRequestHandler())
    listenerHandle = handle
    connectionCountTask = Task {
      for await count in handle.activeConnectionCounts() {
        HelperServiceModel.shared.activeConnections = count
      }
    }
  }

  /// Keeps a single resident instance, preferring the launchd-managed one.
  ///
  /// Only launchd can own a *global* Mach name, so the instance that actually vends the service is
  /// always the one launchd started. A direct (Finder) launch registers the agent and then yields:
  /// without this, a double-launched helper has one instance holding the name and another that looks
  /// alive but serves nobody.
  private func shouldKeepRunning() -> Bool {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    let myPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != myPID }
    guard others.isEmpty == false else { return true }

    if isManagedByLaunchd {
      others.forEach { $0.terminate() }
      return true
    }
    return false
  }

  /// Whether launchd launched this process for its agent job.
  private var isManagedByLaunchd: Bool {
    guard let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return false }
    return name != "0" && name.isEmpty == false
  }
}
