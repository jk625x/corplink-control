// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CorplinkControl",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "CorplinkControlApp", targets: ["CorplinkControlApp"]),
    .executable(name: "CorplinkRootHelper", targets: ["CorplinkRootHelper"]),
  ],
  targets: [
    .target(name: "CorplinkControlCore"),
    .executableTarget(
      name: "CorplinkControlApp", dependencies: ["CorplinkControlCore"]),
    .executableTarget(
      name: "CorplinkRootHelper", dependencies: ["CorplinkControlCore"]),
    .testTarget(
      name: "CorplinkControlCoreTests", dependencies: ["CorplinkControlCore"]),
  ],
  swiftLanguageModes: [.v5]
)
