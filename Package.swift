// swift-tools-version: 6.0
import PackageDescription

var dependencies: [Package.Dependency] = []
#if os(Windows)
let sqlitePath = "packages/sqlite-windows"
#else
let sqlitePath = "packages/sqlite"
#endif
var products: [Product] = [
    .library(name: "ShouCore", targets: ["ShouCore"]),
    .library(name: "ShouPlatform", targets: ["ShouPlatform"]),
    .executable(name: "shou", targets: ["ShouCLI"]),
    .executable(name: "shou-tests", targets: ["ShouSelfTests"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", path: sqlitePath, pkgConfig: "sqlite3"),
    .target(name: "ShouContracts", path: "packages/shou-contracts", exclude: ["README.md", "README.zh-CN.md"], resources: [.copy("rule.schema.json")]),
    .target(name: "ShouAgentSupport", path: "skills", resources: [.copy("shou-rule-authoring")]),
    .target(name: "ShouCore", dependencies: ["ShouContracts", "CSQLite"], path: "packages/shou-core/Sources", resources: [.process("Resources")]),
    .target(name: "CShouWindows", path: "packages/windows-native", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("shell32"), .linkedLibrary("advapi32"), .linkedLibrary("uuid")]),
    .target(name: "ShouPlatform", dependencies: ["ShouCore", "ShouAgentSupport", .target(name: "CShouWindows", condition: .when(platforms: [.windows]))], path: "packages/shou-platform/Sources"),
    .executableTarget(name: "ShouCLI", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport"], path: "apps/cli/Sources"),
    .executableTarget(name: "ShouSelfTests", dependencies: ["ShouCore", "ShouPlatform", "CSQLite"], path: "tests/core")
]
#if os(Windows)
products.removeAll { $0.name == "shou-tests" }
targets.removeAll { $0.name == "ShouSelfTests" }
products.append(.executable(name: "shou-windows-tests", targets: ["ShouWindowsTests"]))
targets.append(.executableTarget(name: "ShouWindowsTests", dependencies: ["ShouCore", "ShouPlatform", "CShouWindows"], path: "tests/windows"))
#endif
#if os(macOS)
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
products.append(.executable(name: "ShouDesktop", targets: ["ShouMac"]))
targets.append(.executableTarget(name: "ShouMac", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport", .product(name: "Sparkle", package: "Sparkle")], path: "apps/macos/Sources", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]))
#endif

let package = Package(name: "Shou", defaultLocalization: "en", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets, cxxLanguageStandard: .cxx17)
