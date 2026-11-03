// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "FastProxy",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "FastProxyCore", targets: ["FastProxyCore"]),
    .executable(name: "FastProxy", targets: ["FastProxyApp"]),
    .executable(name: "fastproxy-cli", targets: ["FastProxyCLI"]),
  ],
  targets: [
    .target(
      name: "CGSS",
      linkerSettings: [
        .linkedFramework("GSS")
      ]
    ),
    .target(
      name: "FastProxyCore",
      dependencies: ["CGSS"]
    ),
    .executableTarget(
      name: "FastProxyApp",
      dependencies: ["FastProxyCore"]
    ),
    .executableTarget(
      name: "FastProxyCLI",
      dependencies: ["FastProxyCore"]
    ),
    .testTarget(
      name: "FastProxyCoreTests",
      dependencies: ["FastProxyCore"]
    ),
  ]
)
