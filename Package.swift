// swift-tools-version: 6.0
import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/teunlao/swift-ai-sdk", exact: "0.20.0")
]
var platformDependencies: [Target.Dependency] = ["ShouCore", "ShouAgentSupport"]
#if os(Windows)
let sqlitePath = "packages/sqlite-windows"
let sqlitePackageConfig: String? = nil
platformDependencies.append("CShouWindows")
#else
let sqlitePath = "packages/sqlite"
let sqlitePackageConfig: String? = "sqlite3"
#endif
var products: [Product] = [
    .library(name: "ShouCore", targets: ["ShouCore"]),
    .library(name: "ShouPlatform", targets: ["ShouPlatform"]),
    .library(name: "ShouAI", targets: ["ShouAI"]),
    .executable(name: "shou", targets: ["ShouCLI"]),
    .executable(name: "shou-tests", targets: ["ShouSelfTests"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", path: sqlitePath, pkgConfig: sqlitePackageConfig),
    .target(name: "ShouContracts", path: "packages/shou-contracts", exclude: ["README.md", "README.zh-CN.md"], resources: [.copy("rule.schema.json")]),
    .target(name: "ShouAgentSupport", path: "skills", resources: [.copy("shou-rule-authoring")]),
    .target(name: "ShouCore", dependencies: ["ShouContracts", "CSQLite"], path: "packages/shou-core/Sources", resources: [.process("Resources")]),
    .target(name: "ShouPlatform", dependencies: platformDependencies, path: "packages/shou-platform/Sources"),
    .target(name: "ShouAI", dependencies: ["ShouCore", .product(name: "SwiftAISDK", package: "swift-ai-sdk", condition: .when(platforms: [.macOS])), .product(name: "OpenAIProvider", package: "swift-ai-sdk", condition: .when(platforms: [.macOS])), .product(name: "AnthropicProvider", package: "swift-ai-sdk", condition: .when(platforms: [.macOS]))], path: "packages/shou-ai/Sources"),
    .executableTarget(name: "ShouCLI", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport", "ShouAI"], path: "apps/cli/Sources"),
    .executableTarget(name: "ShouSelfTests", dependencies: ["ShouCore", "ShouPlatform", "ShouAI", "CSQLite"], path: "tests/core")
]
#if os(Windows)
targets.append(.target(name: "CShouWindows", path: "packages/windows-native", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("shell32"), .linkedLibrary("advapi32"), .linkedLibrary("bcrypt"), .linkedLibrary("uuid")]))
products.removeAll { $0.name == "shou-tests" }
targets.removeAll { $0.name == "ShouSelfTests" }
products.append(.executable(name: "shou-windows-tests", targets: ["ShouWindowsTests"]))
targets.append(.executableTarget(name: "ShouWindowsTests", dependencies: ["ShouCore", "ShouPlatform", "CShouWindows"], path: "tests/windows"))
#endif
#if os(macOS)
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
products.append(.executable(name: "ShouDesktop", targets: ["ShouMac"]))
targets.append(.executableTarget(name: "ShouMac", dependencies: ["ShouCore", "ShouPlatform", "ShouAgentSupport", "ShouAI", .product(name: "Sparkle", package: "Sparkle")], path: "apps/macos/Sources", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]))
#endif

let package = Package(name: "Shou", defaultLocalization: "en", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets, cxxLanguageStandard: .cxx17)
