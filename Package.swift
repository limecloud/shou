// swift-tools-version: 6.0
import PackageDescription

var dependencies: [Package.Dependency] = []
var products: [Product] = [
    .library(name: "ShouCore", targets: ["ShouCore"]),
    .library(name: "ShouPlatform", targets: ["ShouPlatform"]),
    .executable(name: "shou", targets: ["ShouCLI"]),
    .executable(name: "shou-tests", targets: ["ShouSelfTests"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", path: "packages/sqlite", pkgConfig: "sqlite3"),
    .target(name: "ShouContracts", path: "packages/shou-contracts", exclude: ["README.md", "README.zh-CN.md"], resources: [.copy("rule.schema.json")]),
    .target(name: "ShouAgentSupport", path: "skills", resources: [.copy("shou-rule-authoring")]),
    .target(name: "ShouCore", dependencies: ["ShouContracts", "CSQLite"], path: "packages/shou-core/Sources", resources: [.process("Resources")]),
    .target(name: "ShouPlatform", dependencies: ["ShouCore", "ShouAgentSupport"], path: "packages/shou-platform/Sources"),
    .executableTarget(name: "ShouCLI", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport"], path: "apps/cli/Sources"),
    .executableTarget(name: "ShouSelfTests", dependencies: ["ShouCore", "ShouPlatform", "CSQLite"], path: "tests/core")
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
products.append(.executable(name: "ShouDesktop", targets: ["ShouMac"]))
targets.append(.executableTarget(name: "ShouMac", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport", .product(name: "Sparkle", package: "Sparkle")], path: "apps/macos/Sources", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]))
#endif

let package = Package(name: "Shou", defaultLocalization: "en", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets)
