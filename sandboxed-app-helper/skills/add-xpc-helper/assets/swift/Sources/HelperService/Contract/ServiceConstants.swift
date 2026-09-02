/// The Mach service name shared by the app-side client and the helper-side host.
///
/// This one string appears in four places that must agree exactly: here, the launchd plist's
/// `Label`, that plist's `MachServices` key, and the app's mach-lookup entitlement. A mismatch
/// produces a service that is advertised but unreachable.
public let {{SYMBOL_PREFIX}}Name = "{{SERVICE_NAME}}"

/// The file name of the bundled `LaunchAgent` property list advertising the Mach service.
///
/// `SMAppService.agent(plistName:)` looks the plist up by file name inside
/// `Contents/Library/LaunchAgents`, and launchd requires the `Label` inside it to match that file's
/// base name.
public let {{SYMBOL_PREFIX}}LaunchAgentPlistName = "{{SERVICE_NAME}}.plist"

/// The Apple Developer Team Identifier that signs both the app and the helper.
public let {{SYMBOL_PREFIX}}TeamIdentifier = "{{TEAM_ID}}"

/// The main app's bundle identifier.
public let {{SYMBOL_PREFIX}}AppBundleIdentifier = "{{APP_BUNDLE_ID}}"

/// The code-signing requirement each side of the transport enforces on its peer, so neither can be
/// impersonated by a process that registers the same Mach name.
///
/// All three branches are load-bearing:
///
/// - The team-OU clause matches binaries signed with the team's own certificates — development and
///   Developer ID — so the helper always matches it, and so does a locally-run app.
/// - Mac App Store and TestFlight builds are **re-signed by Apple**, so their leaf certificate
///   carries no team OU (a TestFlight leaf's `subject.OU` is `TESTFLIGHT`). They are matched instead
///   by their leaf-certificate marker OIDs — Mac App Store `1.2.840.113635.100.6.1.9`, TestFlight
///   `1.2.840.113635.100.6.1.25.1` — pinned to the app's signing identifier. With an OU-only
///   requirement the helper silently drops every message from those channels, which reads to the
///   user as "helper not installed".
///
/// The requirement is compiled into **both** binaries, so changing it means shipping a rebuilt
/// helper as well: an installed helper carrying the old string keeps rejecting the app regardless of
/// what the app does. Check a candidate build with
/// `codesign -v -R='<requirement>' /Applications/{{APP_NAME}}.app`.
///
/// > A requirement *string* is used rather than the object-based peer-requirement APIs
/// > (`xpc_peer_requirement_create_team_identity`, `xpc_*_set_peer_requirement`) because those, and
/// > the C `xpc_session_*` lifecycle, are unavailable in Swift.
public let {{SYMBOL_PREFIX}}PeerCodeSigningRequirement =
  "anchor apple generic and ("
  + "certificate leaf[subject.OU] = \"\({{SYMBOL_PREFIX}}TeamIdentifier)\""
  + " or ((certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
  + " or certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists)"
  + " and identifier \"\({{SYMBOL_PREFIX}}AppBundleIdentifier)\")"
  + ")"
