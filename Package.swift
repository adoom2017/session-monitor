// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SessionMonitor",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "SMCore", targets: ["SMCore"]),
    // Shared with the iOS app (ios/): wire format and client only, no macOS-only APIs.
    .library(name: "SMProtocol", targets: ["SMProtocol"]),
    .executable(name: "SessionMonitor", targets: ["SessionMonitorApp"]),
    .executable(name: "sm-hook", targets: ["sm-hook"]),
    .executable(name: "sm-remote", targets: ["sm-remote"]),
  ],
  targets: [
    .target(name: "SMProtocol"),
    .target(name: "SMCore", dependencies: ["SMProtocol"]),
    .executableTarget(name: "SessionMonitorApp", dependencies: ["SMCore"]),
    .executableTarget(name: "sm-hook", dependencies: ["SMCore"]),
    .executableTarget(name: "sm-remote", dependencies: ["SMProtocol"]),
    .testTarget(name: "SMCoreTests", dependencies: ["SMCore", "SMProtocol"]),
  ],
  swiftLanguageModes: [.v6]
)
