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

    /// Only an exact bundled definition may use an exception. An ID prefix,
    /// user-declared risk, or familiar directory name is insufficient.
    private static func trustedRule(_ id: String, in rules: [CleanupRule]) -> Bool {
        guard let rule=rules.first(where: { $0.id == id }), let template=(try? BuiltinCatalog.templates())?.first(where: { $0.id == id }),
              let canonical=try? template.rule(rootRef: rule.scope.rootRef) else { return false }
        return rule == canonical
    }

    static func sourcePolicy(path: String, manifest: [FileEntry], entries: [String: FileEntry], workspace: Workspace,
                             rules: [CleanupRule], homeDirectory: URL, evidence: any ArtifactEvidenceChecking) -> SourcePolicy {
        let sources=manifest.filter { sourceLike($0) }
        let cargo=trustedRule("shou.builtin.cargo-extracted-sources", in: rules)
        let swift=trustedRule("shou.builtin.swift-build", in: rules)
        let rust=trustedRule("shou.builtin.rust-target", in: rules)
        guard cargo || swift || rust else { return SourcePolicy() }
        var policy=SourcePolicy()
        let processes: Set<String>
        if cargo || rust { processes=["cargo", "rustc", "rust-analyzer", "clippy-driver", "cargo-clippy", "cargo-nextest"] }
        else { processes=["swift", "swift-build", "swift-test", "swiftc", "swift-frontend", "sourcekit-lsp"] }
        let fullPath=workspace.path + "/" + path
        let projectPath: String
        if rust {
            projectPath=URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
        } else if swift, let buildIndex=path.split(separator: "/").lastIndex(of: ".build") {
            let project=path.split(separator: "/")[..<buildIndex].joined(separator: "/")
            projectPath=project.isEmpty ? workspace.path : workspace.path + "/" + project
        } else { projectPath=workspace.path }
        do {
            let running=try (cargo ? evidence.runningBuildProcesses(in: processes) : evidence.runningBuildProcesses(in: processes, affecting: projectPath))
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
        return ["Cargo.toml", "Cargo.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Package.swift"].contains(name)
            || ["swift", "rs", "c", "cpp", "h", "py", "tsx", "jsx"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func generatedRustSource(_ path: String) -> Bool {
        let parts=path.split(separator: "/").map(String.init)
        let offset=parts.first == "debug" || parts.first == "release" ? 0 : 1
        guard parts.count > offset + 4, ["debug", "release"].contains(parts[offset]), parts[offset+1] == "build",
              parts[offset+2].range(of: "^[A-Za-z0-9_-]+-[0-9a-fA-F]{8,}$", options: .regularExpression) != nil,
              parts[offset+3] == "out" else { return false }
        // Generated source is confined to build-script OUT_DIR, never a copied project tree.
        return !["Cargo.toml", "Cargo.lock", "Package.swift", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"].contains(parts.last ?? "")
    }

    private static func generatedSwiftSource(_ path: String) -> Bool {
        let parts=path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !["Cargo.toml", "Cargo.lock", "Package.swift", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"].contains(parts.last ?? "") else { return false }
        if parts[0].hasSuffix(".build") && parts.count >= 3 && parts[1] == "DerivedSources" { return true }
        return parts[0].hasSuffix("PackageDiscoveredTests.derived") || parts[0].hasSuffix("PackageTests.derived")
    }
}
