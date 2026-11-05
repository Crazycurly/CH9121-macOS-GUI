// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CH9121Config",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CH9121Config", targets: ["CH9121Config"]),
        .library(name: "CH9121Core", targets: ["CH9121Core"])
    ],
    targets: [
        .target(name: "CNet", publicHeadersPath: "include"),
        .target(name: "CH9121Core", dependencies: ["CNet"]),
        .executableTarget(name: "CH9121Config", dependencies: ["CH9121Core"]),
        .testTarget(name: "CH9121CoreTests", dependencies: ["CH9121Core", "CNet"])
    ],
    swiftLanguageVersions: [.v5]
)
