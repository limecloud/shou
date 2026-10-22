import Foundation

public enum CargoSourceIntegrity: String, Sendable {
    case verified
    case modified
}

/// Read-only platform facts. Rule documents cannot provide these capabilities.
public protocol ArtifactEvidenceChecking: Sendable {
    func hasGitTrackedFiles(at path: String) throws -> Bool
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String>
    func runningBuildProcesses(in names: Set<String>, affecting projectPath: String) throws -> Set<String>
}

extension ArtifactEvidenceChecking {
    public func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        throw ShouError("artifact_evidence_unavailable", "Build process activity could not be checked.")
    }
    public func runningBuildProcesses(in names: Set<String>, affecting projectPath: String) throws -> Set<String> {
        try runningBuildProcesses(in: names)
    }
}

public struct UnavailableArtifactEvidence: ArtifactEvidenceChecking {
    public init() {}
    public func hasGitTrackedFiles(at path: String) throws -> Bool {
        throw ShouError("artifact_evidence_unavailable", "Artifact ownership could not be checked.")
    }
    public func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity {
        throw ShouError("artifact_evidence_unavailable", "Cargo source integrity could not be checked.")
    }
}

enum ArtifactSafety {
    struct SourcePolicy {
        var allowedPaths=Set<String>()
        var reasons: [String]=[]
    }

    static func sourcePolicy(path: String, manifest: [FileEntry], entries: [String: FileEntry], workspace: Workspace,
                             rules: [CleanupRule], homeDirectory: URL, evidence: any ArtifactEvidenceChecking) -> SourcePolicy {
        let sources=manifest.filter { sourceLike($0) }
        let trusted=(try? BuiltinCatalog.trustedTemplates(matching: rules)) ?? []
        let cargo=trusted.contains { $0.id == "shou.builtin.cargo-extracted-sources" }
        let swift=trusted.contains { $0.id == "shou.builtin.swift-build" }
        let rust=trusted.contains { $0.id == "shou.builtin.rust-target" }
        let browser=trusted.contains { $0.id == "shou.builtin.browser-automation-caches" }
        let projects=trusted.filter { $0.location == "projects" }
        guard cargo || browser || !projects.isEmpty else { return SourcePolicy() }
        var policy=SourcePolicy()
        let processes: Set<String>
        if cargo || rust { processes=["cargo", "rustc", "rust-analyzer", "clippy-driver", "cargo-clippy", "cargo-nextest"] }
        else if browser { processes=["node", "playwright", "Cypress"] }
        else { processes=projects.reduce(into:Set<String>()) { $0.formUnion(buildProcesses(ruleId:$1.id)) } }
        let fullPath=workspace.path + "/" + path
        let projectPath: String
        if rust {
            projectPath=URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
        } else if swift, let buildIndex=path.split(separator: "/").lastIndex(of: ".build") {
            let project=path.split(separator: "/")[..<buildIndex].joined(separator: "/")
            projectPath=project.isEmpty ? workspace.path : workspace.path + "/" + project
        } else if cargo { projectPath=workspace.path }
        else {
            var parent=StorageIndex.parent(path)
            if projects.contains(where:{ $0.id == "shou.builtin.python-bytecode" }) {
                while parent != "." {
                    if ["pyproject.toml","setup.py","setup.cfg","requirements.txt","Pipfile"].contains(where:{ entries[parent + "/" + $0]?.kind == "file" }) { break }
                    parent=StorageIndex.parent(parent)
                }
            }
            projectPath=parent == "." ? workspace.path : workspace.path + "/" + parent
        }
        do {
            let running=try (cargo || browser ? evidence.runningBuildProcesses(in: processes) : evidence.runningBuildProcesses(in: processes, affecting: projectPath))
            if !running.isEmpty {
                policy.reasons.append("build_process_running"); return policy
            }
            if try evidence.hasGitTrackedFiles(at: fullPath) {
                policy.reasons.append("tracked_artifact_content"); return policy
            }
        } catch {
            policy.reasons.append("artifact_evidence_unavailable"); return policy
        }

        if cargo {
            let parts=path.split(separator: "/").map(String.init)
            guard workspace.path == homeDirectory.appendingPathComponent(".cargo", isDirectory: true).path,
                  parts.count == 4, parts[0] == "registry", parts[1] == "src",
                  parts[2].range(of: "^[A-Za-z0-9._-]+-[0-9a-fA-F]{8,}$", options: .regularExpression) != nil,
                  manifest.contains(where: { $0.path == "Cargo.toml" && $0.kind == "file" }),
                  manifest.contains(where: { $0.path == ".cargo-checksum.json" && $0.kind == "file" }) else {
                policy.reasons.append("artifact_layout_unverified"); return policy
            }
            do {
                switch try evidence.cargoSourceIntegrity(at: fullPath, expected: manifest) {
                case .verified: policy.allowedPaths=Set(sources.map(\.path))
                case .modified: policy.reasons.append("cargo_source_modified")
                }
            } catch let error as ShouError {
                policy.reasons.append(error.code == "artifact_restore_unavailable" ? "artifact_restore_unavailable" : "artifact_evidence_unavailable")
            } catch { policy.reasons.append("artifact_evidence_unavailable") }
            return policy
        }

        if rust {
            // Ordinary binary-only targets retain the existing layout contract,
            // while process and Git ownership checks always apply.
            guard !sources.isEmpty else { return policy }
            let parent=StorageIndex.parent(path)
            let marker=parent == "." ? "Cargo.toml" : parent + "/Cargo.toml"
            guard path.split(separator: "/").last == "target", entries[marker]?.kind == "file",
                  entries[path + "/CACHEDIR.TAG"]?.kind == "file", entries[path + "/.rustc_info.json"]?.kind == "file" else {
                policy.reasons.append("artifact_layout_unverified"); return policy
            }
            for source in sources where generatedRustSource(source.path) {
                let parts=source.path.split(separator: "/").map(String.init)
                let profile=parts.first == "debug" || parts.first == "release" ? parts[0] : parts[0] + "/" + parts[1]
                if entries[path + "/" + profile + "/.fingerprint"]?.kind == "directory" { policy.allowedPaths.insert(source.path) }
            }
            return policy
        }

        if !swift {
            let parent=StorageIndex.parent(path)
            let hasMarker: (String) -> Bool = { entries[parent == "." ? $0 : parent + "/" + $0]?.kind == "file" }
            for source in sources where !projectManifest(source.path) {
                if projects.contains(where:{ generatedProjectSource(source.path, candidate:path, ruleId:$0.id, hasMarker:hasMarker, entries:entries) }) {
                    policy.allowedPaths.insert(source.path)
                }
            }
            return policy
        }

        let parts=path.split(separator: "/").map(String.init)
        guard let buildIndex=parts.lastIndex(of: ".build"), (1...2).contains(parts.count - buildIndex - 1),
              ["debug", "release"].contains(parts.last ?? "") else {
            policy.reasons.append("artifact_layout_unverified"); return policy
        }
        let project=parts[..<buildIndex].joined(separator: "/")
        let build=parts[...buildIndex].joined(separator: "/")
        guard entries[project.isEmpty ? "Package.swift" : project + "/Package.swift"]?.kind == "file",
              entries[build + "/workspace-state.json"]?.kind == "file", entries[path + "/description.json"]?.kind == "file" else {
            policy.reasons.append("artifact_layout_unverified"); return policy
        }
        for source in sources where generatedSwiftSource(source.path) { policy.allowedPaths.insert(source.path) }
        return policy
    }

    static func sourceLike(_ entry: FileEntry) -> Bool {
        guard entry.kind == "file" else { return false }
        let name=(entry.path as NSString).lastPathComponent
        return projectManifest(name)
            || ["swift", "rs", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "py", "tsx", "jsx", "ts", "js", "mjs", "cjs", "java", "kt", "kts", "dart", "go", "cs", "fs", "vb", "rb", "php", "scala", "vue", "svelte"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func projectManifest(_ path: String) -> Bool {
        let name=(path as NSString).lastPathComponent.lowercased()
        return ["cargo.toml", "cargo.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "package.swift", "pyproject.toml", "setup.cfg", "requirements.txt", "pipfile", "poetry.lock", "uv.lock", "pubspec.yaml", "pubspec.lock", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties", "local.properties", "pom.xml", "cmakelists.txt"].contains(name)
            || ["csproj", "fsproj", "vbproj", "vcxproj", "sln"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func buildProcesses(ruleId: String) -> Set<String> {
        if ruleId.contains("swift") { return ["swift", "swift-build", "swift-test", "swiftc", "swift-frontend", "sourcekit-lsp"] }
        if ruleId.contains("node") { return ["node","npm","npx","pnpm","yarn","bun","deno","esbuild","vite","webpack","next","nuxt","turbo","parcel"] }
        if ruleId.contains("python") || ruleId.contains("pytest") {
            return Set(["python","python2","python3","pytest","mypy","ruff","uv","poetry","pip","pip3","tox","nox"] + (8...15).map { "python3.\($0)" })
        }
        if ruleId.contains("gradle") { return ["gradle","gradlew","java","javac","kotlin","kotlinc","kapt"] }
        if ruleId.contains("flutter") { return ["flutter","dart","dartaotruntime","frontend_server","gen_snapshot","java","gradle","xcodebuild"] }
        if ruleId.contains("maven") { return ["mvn","mvnw","java","javac","kotlin","kotlinc"] }
        if ruleId.contains("cmake") { return ["cmake","ctest","cpack","ninja","make","gmake","clang","clang++","gcc","g++","cc","c++","ld","ld.lld","lld"] }
        return []
    }

    private static func generatedProjectSource(_ source: String, candidate: String, ruleId: String, hasMarker: (String) -> Bool, entries: [String:FileEntry]) -> Bool {
        let target=(candidate as NSString).lastPathComponent
        if ruleId.contains("gradle"), target == "build", (hasMarker("build.gradle") || hasMarker("build.gradle.kts")),
           entries[candidate + "/tmp"]?.kind == "directory",
           ["classes", "intermediates", "outputs"].contains(where: { entries[candidate + "/" + $0]?.kind == "directory" }) {
            return ["generated/sources/annotationProcessor/", "generated/source/kapt/", "generated/source/kaptKotlin/", "generated/ksp/", "generated/data_binding_base_class_source_out/"].contains { source.hasPrefix($0) }
        }
        if ruleId.contains("maven"), target == "target", hasMarker("pom.xml"), entries[candidate + "/maven-status"]?.kind == "directory" {
            return source.hasPrefix("generated-sources/") || source.hasPrefix("generated-test-sources/")
        }
        if ruleId.contains("flutter"), hasMarker("pubspec.yaml") {
            if target == ".dart_tool", entries[candidate + "/package_config.json"]?.kind == "file" {
                return source.range(of:"^flutter_build/([a-fA-F0-9]{8,64}/)?dart_plugin_registrant[.]dart$", options:.regularExpression) != nil
            }
            if target == "build" {
                if entries[candidate + "/app/intermediates"]?.kind == "directory",
                   ["app/generated/source/flutter/", "app/generated/source/buildConfig/"].contains(where: { source.hasPrefix($0) }) { return true }
                return entries[candidate + "/web/version.json"]?.kind == "file" && ["web/main.dart.js","web/flutter.js","web/flutter_bootstrap.js"].contains(source)
            }
        }
        if ruleId.contains("cmake"), hasMarker("CMakeLists.txt"), entries[candidate + "/CMakeCache.txt"]?.kind == "file", entries[candidate + "/CMakeFiles"]?.kind == "directory" {
            let parts=source.split(separator:"/")
            return parts.count == 4 && parts[0] == "CMakeFiles"
                && parts[1].range(of:"^[0-9]+([.][0-9]+){1,3}$",options:.regularExpression) != nil
                && ["CompilerIdC", "CompilerIdCXX"].contains(String(parts[2]))
                && ["CMakeCCompilerId.c","CMakeCXXCompilerId.cpp"].contains(String(parts[3]))
        }
        if ruleId == "shou.builtin.node-build-cache", hasMarker("package.json") {
            if target == ".next", entries[candidate + "/build-manifest.json"]?.kind == "file", entries[candidate + "/server"]?.kind == "directory" {
                return source.hasPrefix("server/") || source.hasPrefix("static/") || source.hasPrefix("types/")
            }
            if target == ".nuxt", entries[candidate + "/tsconfig.json"]?.kind == "file", entries[candidate + "/nuxt.d.ts"]?.kind == "file" {
                return ["nuxt.d.ts", "imports.d.ts", "components.d.ts"].contains(source) || source.hasPrefix("types/") || source.hasPrefix("dist/")
            }
        }
        if ruleId == "shou.builtin.node-build-outputs", hasMarker("package.json") {
            return source.range(of:"^(assets/[^/]+-[A-Za-z0-9_-]{8,}|static/js/[^/]+[.][a-fA-F0-9]{8,})[.]js$",options:.regularExpression) != nil
        }
        return false
    }

    private static func generatedRustSource(_ path: String) -> Bool {
        let parts=path.split(separator: "/").map(String.init)
        let offset=parts.first == "debug" || parts.first == "release" ? 0 : 1
        guard parts.count > offset + 4, ["debug", "release"].contains(parts[offset]), parts[offset+1] == "build",
              parts[offset+2].range(of: "^[A-Za-z0-9_-]+-[0-9a-fA-F]{8,}$", options: .regularExpression) != nil,
              parts[offset+3] == "out" else { return false }
        // Generated source is confined to build-script OUT_DIR, never a copied project tree.
        return !projectManifest(path)
    }

    private static func generatedSwiftSource(_ path: String) -> Bool {
        let parts=path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !projectManifest(path) else { return false }
        if parts[0].hasSuffix(".build") && parts.count >= 3 && parts[1] == "DerivedSources" { return true }
        return parts[0].hasSuffix("PackageDiscoveredTests.derived") || parts[0].hasSuffix("PackageTests.derived")
    }
}
