// swift-tools-version: 6.0
import PackageDescription

// The wire contract and both ends of the XPC transport, shared by the app and the helper so the
// service name, team identifier and peer code-signing requirement are defined exactly once.
//
// Deliberately dependency-free: it uses only Foundation, XPC, Security, ServiceManagement,
// Synchronization and OSLog. Wire it into whatever dependency-injection and logging the adopting
// project already uses rather than pulling those choices in here.
let package = Package(
  name: "{{PACKAGE_NAME}}",
  // Synchronization.Mutex requires macOS 15. Raise this to match the app if it targets higher.
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "{{PACKAGE_NAME}}", targets: ["{{PACKAGE_NAME}}"])
  ],
  targets: [
    // Explicit paths so the template's directory names survive substitution without a rename step;
    // the module is still named {{PACKAGE_NAME}}. Rename the directories if you prefer.
    .target(name: "{{PACKAGE_NAME}}", path: "Sources/HelperService"),
    .testTarget(
      name: "{{PACKAGE_NAME}}Tests",
      dependencies: ["{{PACKAGE_NAME}}"],
      path: "Tests/HelperServiceTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
