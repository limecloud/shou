import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

/// Discovery never executes a discovered binary or grants package mutation authority.
public struct NativeDeveloperToolInventory: DeveloperToolDiscovering {
    private let home: URL
    private let pathDirectories: [String]?
    private let includeManagers: Bool
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { home=homeDirectory; pathDirectories=nil; includeManagers=true }
    public init(homeDirectory: URL, generatedSearchDirectories: [String]) { home=homeDirectory; pathDirectories=generatedSearchDirectories; includeManagers=false }

    public func scan(_ catalog: DeveloperToolCatalog) throws -> DeveloperToolInventory { try scan(catalog, progress: nil) }
    public func scan(_ catalog: DeveloperToolCatalog, progress: (@Sendable (DeveloperToolInventory) -> Void)?) throws -> DeveloperToolInventory {
        #if os(macOS)
        var rows=[DeveloperToolInstallation](), issues=[String]()
        try Task.checkCancellation()
        var directories=pathDirectories ?? Array((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").prefix(64)).map(String.init)
        if pathDirectories == nil {
            rows += applications(catalog)
            directories += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/usr/sbin"]
            directories += [".local/bin", ".cargo/bin", ".bun/bin", ".deno/bin", ".volta/bin", ".npm-global/bin", "go/bin"].map { home.appendingPathComponent($0).path }
            for root in [".nvm/versions/node", ".pyenv/versions"] {
                let url=home.appendingPathComponent(root)
                let children=try boundedChildren(url, limit: 64, issues: &issues)
                directories += children.map { $0.appendingPathComponent("bin").path }
            }
        }
        let commandMap=Dictionary(grouping: catalog.tools.flatMap { tool in tool.commands.map { ($0,tool) } }, by: { $0.0 })
        for directory in Set(directories.filter { $0.hasPrefix("/") }).sorted().prefix(256) {
            try Task.checkCancellation()
            for (command,tools) in commandMap {
                let path=URL(fileURLWithPath: directory).appendingPathComponent(command)
                for (_,tool) in tools {
                    if let row=observe(path, tool: tool, source: "Executable path") { rows.append(row) }
                }
            }
        }
        if pathDirectories == nil {
            let roots=NativeDeveloperStorageRoots.referenceData(home:home).map { $0.appendingPathComponent("app") }
            var budget=8192
            for root in roots {
                guard let walker=FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _,_ in false }) else { continue }
                while let item=walker.nextObject() as? URL {
                    try Task.checkCancellation()
                    budget -= 1
                    if budget < 0 { issues.append("The developer tool search reached its directory budget."); break }
                    if walker.level > 5 { walker.skipDescendants(); continue }
                    if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants() }
                    for (_,tool) in commandMap[item.lastPathComponent] ?? [] {
                        if let row=observe(item, tool: tool, source: "FlyEnv storage") { rows.append(row) }
                    }
                }
            }
        }
        // Local metadata is available before starting slower manager processes.
        progress?(inventory(rows: rows, issues: issues))
        if includeManagers {
            do { rows += try homebrew(catalog) } catch { if (error as? ShouError)?.code != "tool_not_installed" { issues.append("Homebrew inventory could not be read.") } }
            try Task.checkCancellation()
            progress?(inventory(rows: rows, issues: issues))
            do { rows += try mise(catalog) } catch { if (error as? ShouError)?.code != "tool_not_installed" { issues.append("mise inventory could not be read.") } }
        }
        try Task.checkCancellation()
        return inventory(rows: rows, issues: issues)
        #else
        throw ShouError("unsupported_capability", "Native developer tool discovery requires macOS.")
        #endif
    }
    #if os(macOS)
    private func inventory(rows: [DeveloperToolInstallation], issues: [String]) -> DeveloperToolInventory {
        // Preserve different versions/locations. Suppress a PATH alias only when it
        // resolves inside a matching package location already reported by its manager.
        var unique=[String:DeveloperToolInstallation]()
        for row in rows.sorted(by: { $0.source < $1.source }) {
            let owner=rows.first { $0.toolID == row.toolID && ["Homebrew","mise"].contains($0.source) && (row.path == $0.path || row.path.hasPrefix($0.path + "/")) } ?? row
            let key=owner.toolID + "\0" + owner.path
            let aliases=Set((unique[key]?.launchPaths ?? owner.launchPaths) + row.launchPaths).sorted()
            unique[key] = .init(toolID: owner.toolID, source: owner.source, version: owner.version, path: owner.path, evidence: owner.evidence, status: owner.status, launchPaths: aliases)
        }
        return .init(installations: unique.values.sorted { ($0.toolID,$0.path) < ($1.toolID,$1.path) }, issues: Array(Set(issues)).sorted())
    }
    private func applications(_ catalog: DeveloperToolCatalog) -> [DeveloperToolInstallation] {
        // Fixed bundle identities avoid treating an arbitrary similarly named directory as an application.
        let known=[("claude-desktop", "Claude.app", "com.anthropic.claudefordesktop"), ("ollama", "Ollama.app", "com.electron.ollama")]
        var rows=[DeveloperToolInstallation]()
        for (id,name,identity) in known where catalog.tools.contains(where: { $0.id == id }) {
            for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
                let bundle=root.appendingPathComponent(name), info=bundle.appendingPathComponent("Contents/Info.plist")
                guard let handle=try? FileHandle(forReadingFrom: info) else { continue }
                defer { try? handle.close() }
                guard let data=try? handle.read(upToCount: 256 * 1024 + 1), data.count <= 256 * 1024,
                      let object=try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String:Any], object["CFBundleIdentifier"] as? String == identity else { continue }
                let version=(object["CFBundleShortVersionString"] as? String).flatMap { safeVersion($0) ? $0 : nil }
                rows.append(.init(toolID: id, source: "Application bundle", version: version, path: bundle.path, evidence: identity, status: version == nil ? "detected" : "registered"))
            }
        }
        return rows
    }
    private func homebrew(_ catalog: DeveloperToolCatalog) throws -> [DeveloperToolInstallation] {
        let output=try NativePackageUpdates(homeDirectory: home).run(.installed(.homebrew), timeoutSeconds: 60, expectedExecutableIdentity: nil)
        guard let object=try JSONSerialization.jsonObject(with: output.data) as? [String:Any],
              let formulae=object["formulae"] as? [[String:Any]], let casks=object["casks"] as? [[String:Any]], formulae.count+casks.count <= 10_000 else { throw invalid() }
        let prefix=output.executableIdentity.hasPrefix("/opt/homebrew/") ? "/opt/homebrew" : "/usr/local"
        var rows=[DeveloperToolInstallation]()
        for tool in catalog.tools {
            for package in tool.packages where package.provider == "homebrew" {
                // A previously installed formula may now be distributed as a cask.
                // Keep the old registration without granting the new source its authority.
                do {
                    for row in formulae where row["full_name"] as? String == package.token {
                        for entry in row["installed"] as? [[String:Any]] ?? [] {
                            guard let version=entry["version"] as? String, safeVersion(version) else { continue }
                            rows.append(.init(toolID: tool.id, source: "Homebrew", version: version, path: prefix+"/Cellar/"+package.token+"/"+version, evidence: output.executableIdentity, status: "registered"))
                        }
                    }
                }
                do {
                    for row in casks where row["token"] as? String == package.token {
                        guard let version=row["installed"] as? String, safeVersion(version) else { continue }
                        rows.append(.init(toolID: tool.id, source: "Homebrew", version: version, path: prefix+"/Caskroom/"+package.token+"/"+version, evidence: output.executableIdentity, status: "registered"))
                    }
                }
            }
        }
        return rows
    }
    private func mise(_ catalog: DeveloperToolCatalog) throws -> [DeveloperToolInstallation] {
        let output=try NativePackageUpdates(homeDirectory: home).run(.installed(.mise), timeoutSeconds: 60, expectedExecutableIdentity: nil)
        guard let object=try JSONSerialization.jsonObject(with: output.data) as? [String:Any], object.count <= 256 else { throw invalid() }
        var rows=[DeveloperToolInstallation]()
        for tool in catalog.tools {
            for row in object[tool.id] as? [[String:Any]] ?? [] {
                guard row["installed"] as? Bool == true, let version=row["version"] as? String, safeVersion(version),
                      let path=row["install_path"] as? String, path.hasPrefix("/"), path.utf8.count <= 4096 else { continue }
                rows.append(.init(toolID: tool.id, source: "mise", version: version, path: path, evidence: output.executableIdentity, status: "registered"))
            }
        }
        return rows
    }
    private func observe(_ url: URL, tool: DeveloperToolDefinition, source: String) -> DeveloperToolInstallation? {
        let resolved=url.resolvingSymlinksInPath()
        var file=stat()
        guard stat(resolved.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        var version: String?, origin=source
        var ancestor=resolved.deletingLastPathComponent()
        for _ in 0..<8 {
            if let object=try? json(ancestor.appendingPathComponent("package.json")), let name=object["name"] as? String,
               tool.npmPackages.contains(name), let observed=object["version"] as? String, safeVersion(observed) {
                version=observed
                if source == "Executable path" {
                    let roots=[(".bun/install/global", "Bun storage"), (".nvm/versions/node", "nvm storage"), (".npm-global", "npm storage")]
                    origin=roots.first { resolved.path.hasPrefix(home.appendingPathComponent($0.0).resolvingSymlinksInPath().path + "/") }?.1 ?? "Node package"
                }
                break
            }
            let parent=ancestor.deletingLastPathComponent(); if parent == ancestor { break }; ancestor=parent
        }
        return .init(toolID: tool.id, source: origin, version: version, path: resolved.path,
                     evidence: "\(file.st_dev):\(file.st_ino):\(file.st_size):\(file.st_mtimespec.tv_sec)", status: version == nil ? "detected" : "registered", launchPaths: [url.path])
    }
    private func boundedChildren(_ root: URL, limit: Int, issues: inout [String]) throws -> [URL] {
        guard let directory=opendir(root.path) else {
            if errno != ENOENT { issues.append("Some developer tool locations could not be read.") }; return []
        }
        defer { closedir(directory) }
        var result=[URL](), visited=0
        while let entry=readdir(directory) {
            visited += 1
            guard visited <= limit + 2 else { issues.append("The developer tool search reached its directory budget."); break }
            let name=withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(root.appendingPathComponent(name)) }
        }
        return result
    }
    private func json(_ url: URL) throws -> [String:Any] {
        let handle=try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data=try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
        guard data.count <= 256 * 1024, let object=try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw invalid() }; return object
    }
    private func safeVersion(_ version: String) -> Bool { !version.isEmpty && version.utf8.count <= 256 && !version.contains("/") && !version.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private func invalid() -> ShouError { ShouError("unsupported_schema", "Installed tool metadata is not supported.") }
    #endif
}
