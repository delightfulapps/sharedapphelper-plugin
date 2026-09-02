# Worked example: PreviewSmith

The skill's templates carry a deliberately minimal contract — `ping`, `helperInfo`, `echo` — so the
shape is visible. This is what the same architecture looks like carrying real traffic, in the app it
was extracted from.

## The problem

PreviewSmith renders SwiftUI previews by driving Xcode's `mcpbridge` subprocess and reading the PNGs
Xcode writes into its temp `ActionArtifacts` namespace. Neither is possible from the App Sandbox:
spawning `mcpbridge` needs an unsandboxed process, and Xcode's temp namespace is outside the app's
container. The app ships on the Mac App Store, so the work moved into a downloaded Developer ID helper.

## The contract

Six requests rather than three, and responses carrying real payloads:

```swift
public enum MCPServiceRequest: Codable, Sendable {
  case connect
  case disconnect
  case listTools
  case callTool(name: String, arguments: [String: MCPArgument])
  case renderPreview(arguments: [String: MCPArgument])
  case helperInfo
}

public enum MCPServiceResponse: Codable, Sendable {
  case serverInfo(MCPServerInfo)
  case tools([MCPToolDescriptor])
  case toolResult(MCPToolResult)
  case snapshot(MCPImageContent)      // PNG bytes read from Xcode's temp namespace
  case ok
  case helperInfo(version: String)
  case failure(MCPServiceError)
}
```

The helper's `HelperRequestHandling` equivalent owns a live MCP client speaking JSON-RPC over stdio to
`/usr/bin/xcrun mcpbridge`, so the app's `.callTool` becomes a subprocess round trip it could never
make itself.

## Four things that generalize

**Per-request timeouts.** A build compiles the whole project and outlasts everything else, so the
timeout switches on the request rather than being one generous constant:

```swift
var timeout: Duration {
  guard case .callTool(let name, _) = self else { return .seconds(180) }
  return name == MCPToolName.build ? .seconds(900) : .seconds(180)
}
```

The skill's `serviceRequestTimeout` is the single-value version of this; add the property when the
spread appears.

**`.connect` could not be reused as the version probe.** Over the helper's service, `.connect` returns
the *downstream bridge's* server info — the wrong version — and requires Xcode to be running, so it
reports false negatives when it isn't. Hence the dedicated `.helperInfo` request, which the dispatcher
answers from the helper's own bundle. This is why the skill's contract has `helperInfo` even in its
minimal form.

**A capability probe for the peer's own age.** The bridge PreviewSmith drives changed its targeting
argument between Xcode versions, so the client probes `listTools` once and caches which model the
connected bridge speaks. Any helper that wraps a moving external tool ends up needing something
similar — and it belongs on the client, not in the wire contract, so an older helper doesn't have to
know about it.

**Wire-format freeze, in practice.** The project's follow-ups file records `MCPServiceError`
case names as frozen: a rename would break an installed helper decoding a newer app's message. The
skill's `ContractTests` pin the same property with an explicit assertion, so the break shows up as a
failing test rather than a support ticket.

## What was left behind

The extraction dropped PreviewSmith's `swift-dependencies` registration, `swift-log` bootstrap, design
system icons, and string catalog. Those are all real and all worth having — they are just the app's
choices, not the architecture's, which is why the package takes its collaborators as injected closures
and the settings UI is a sketch rather than a template.
