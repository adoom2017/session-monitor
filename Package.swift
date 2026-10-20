// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SessionMonitor",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SMCore", targets: ["SMCore"]),
    .executable(name: "SessionMonitor", targets: ["SessionMonitorApp"]),
    .executable(name: "sm-hook", targets: ["sm-hook"]),
  ],
  targets: [
    .target(name: "SMCore"),
    .executableTarget(name: "SessionMonitorApp", dependencies: ["SMCore"]),
    .executableTarget(name: "sm-hook", dependencies: ["SMCore"]),
    .testTarget(name: "SMCoreTests", dependencies: ["SMCore"]),
  ],
  swiftLanguageModes: [.v6]
)
