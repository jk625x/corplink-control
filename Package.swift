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
    .executableTarget(name: "CorplinkControlApp"),
    .executableTarget(name: "CorplinkRootHelper"),
  ],
  swiftLanguageModes: [.v5]
)
