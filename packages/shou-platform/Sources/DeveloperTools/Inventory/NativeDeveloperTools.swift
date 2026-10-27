import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeDeveloperTools: DeveloperToolOperating {
    private let home: URL
    private let executable: String?
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { home=homeDirectory; executable=nil }
    /// Generated fixtures remain inside an isolated home; never fall back to a real manager.
    public init(homeDirectory: URL, generatedExecutable: URL) { home=homeDirectory; executable=generatedExecutable.path }

    public static func package(for installation: DeveloperToolInstallation, catalog: DeveloperToolCatalog) -> DeveloperToolPackage? {
        guard installation.source == "Homebrew", let version=installation.version else { return nil }
        return catalog.tools.first(where:{ $0.id == installation.toolID })?.packages.first { package in
            guard package.provider == "homebrew" else { return false }
            return ["/opt/homebrew","/usr/local"].contains { prefix in
                installation.path == prefix + (package.kind == "cask" ? "/Caskroom/" : "/Cellar/") + package.token + "/" + version
            }
        }
    }

    public func inspect(_ package: DeveloperToolPackage) throws -> DeveloperToolInspection {
        #if os(macOS)
        guard package.valid, package.provider == "homebrew" else { throw error("developer_tool_source_unavailable") }
        let (path,identity)=try manager()
        let process=NativeManagedToolProcess(homeDirectory: home)
        let bytes=try process.run(path, arguments: ["info", "--json=v2", "--"+package.kind, package.token], timeout: 60, observeCancellation: false)
        guard bytes.count <= 4 * 1024 * 1024,
              let document=try JSONSerialization.jsonObject(with: bytes) as? [String:Any],
              let rows=document[package.kind == "formula" ? "formulae" : "casks"] as? [[String:Any]], rows.count == 1 else { throw error("package_identity_unverified") }
        let row=rows[0]
        guard row[package.kind == "formula" ? "full_name" : "token"] as? String == package.token,
              (row["tap"] as? String) == (package.kind == "formula" ? "homebrew/core" : "homebrew/cask") else { throw error("package_source_unverified") }
        let installed: [String]
        let available: String?
        let dependencies: [String]
        if package.kind == "formula" {
            guard let entries=row["installed"] as? [[String:Any]], let deps=row["dependencies"] as? [String] else { throw error("package_identity_unverified") }
            installed=try entries.map { try text($0["version"]) }
            let stable=(row["versions"] as? [String:Any])?["stable"] as? String
            let revision=row["revision"] as? Int ?? 0
            available=stable.map { $0 + (revision > 0 ? "_"+String(revision) : "") }
            dependencies=deps
        } else {
            if let version=row["installed"] as? String { installed=[try text(version)] }
            else if row["installed"] == nil || row["installed"] is NSNull { installed=[] }
            else { throw error("package_identity_unverified") }
            available=row["version"] as? String
            let depends=row["depends_on"] as? [String:Any] ?? [:]
            dependencies=((depends["formula"] as? [String] ?? []) + (depends["cask"] as? [String] ?? []))
        }
        guard installed.count <= 64, dependencies.count <= 512, dependencies.allSatisfy({ PackageUpdateCommand.validToken($0, provider: .homebrew) }),
              available.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) ?? true,
              try manager().1 == identity else { throw error("package_identity_unverified") }
        // Bind the actual recipe, archive/checksum metadata, installed receipts,
        // dependency declarations and revisions, excluding presentation-only analytics.
        let keys=["name","full_name","token","tap","versions","version","revision","version_scheme","urls","url","sha256","bottle","dependencies","build_dependencies","depends_on","conflicts_with","artifacts","caveats","service","installed","pinned","disabled","deprecated"]
        let evidence=row.filter { keys.contains($0.key) }
        let digest=Digest.sha256(try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
        let issue: String? = (row["disabled"] as? Bool == true || row["deprecated"] as? Bool == true) ? "package_source_unavailable" : nil
        return .init(package: package, installedVersions: installed.sorted(), availableVersion: available == "latest" ? nil : available, dependencies: dependencies.sorted(), sourceIdentity: identity, packageIdentity: digest, scope: "Homebrew prefix", issue: issue)
        #else
        throw error("unsupported_capability")
        #endif
    }

    public func perform(_ action: DeveloperToolAction, expected: DeveloperToolInspection, expiresAt: Date) throws {
        #if os(macOS)
        let (path,identity)=try manager()
        guard expected.allows(action), expected.sourceIdentity == identity,
              try inspect(expected.package) == expected, expiresAt > Date() else { throw error("developer_tool_changed") }
        if action == .uninstall {
            try NativeDeveloperPackageActivity(prefixes:executable == nil ? ["/opt/homebrew","/usr/local"] : [home.path]).requireInactive(expected.package)
            guard expiresAt > Date() else { throw error("developer_tool_changed") }
        }
        let arguments=[action == .install ? "install" : "uninstall", "--"+expected.package.kind, expected.package.token]
        // No zap, force, autoremove, sudo, shell profile write or manager bootstrap.
        // Once dispatched, wait for the owning manager; stop cannot roll an installer back.
        _ = try NativeManagedToolProcess(homeDirectory: home).run(path, arguments: arguments, timeout: 900, observeCancellation: false)
        #else
        throw error("unsupported_capability")
        #endif
    }

    #if os(macOS)
    func manager() throws -> (String,String) {
        let paths=executable.map { [$0] } ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in paths where FileManager.default.isExecutableFile(atPath: candidate) {
            let path=URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if executable != nil {
                guard path.hasPrefix(home.resolvingSymlinksInPath().path + "/") else { throw error("permission_denied") }
            }
            var info=stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  [0,getuid()].contains(info.st_uid), info.st_mode & 0o022 == 0 else { throw error("permission_denied") }
            return (path,"\(path):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
        }
        throw error("tool_not_installed")
    }
    #endif
    private func text(_ value: Any?) throws -> String {
        guard let value=value as? String, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw error("package_identity_unverified") }
        return value
    }
    private func error(_ code: String) -> ShouError { ShouError(code, "The selected developer tool could not be verified. Inspect it again or use its official guide.") }
}

public extension DeveloperToolService {
    static func native() throws -> DeveloperToolService {
        .init(catalog: try .bundled(), platform: NativeDeveloperTools(), makeStore: { try LocalRecordStore() })
    }
}
