import Foundation

public enum PackageUpdateProvider: String, CaseIterable, Codable, Sendable { case homebrew, mise }

public struct PackageUpdateItem: Identifiable, Equatable, Codable, Sendable {
    public let provider: PackageUpdateProvider
    public let token: String
    public let name: String
    public let kind: String
    public let installedVersions: [String]
    public let availableVersion: String?
    public let summary: String?
    public let isPinned: Bool
    public let requestedVersion: String?
    public let configurationPath: String?
    /// Presentation hints only. These paths never grant installation ownership or mutation authority.
    public var iconApplicationPaths: [String]? = nil
    public var id: String { provider.rawValue + ":" + kind + ":" + token }
    public var installedVersion: String { installedVersions.joined(separator: " · ") }
    public var canUpgrade: Bool { !isPinned && availableVersion.map { $0 != "latest" && $0 != "unknown" && !installedVersions.contains($0) } == true }
}

public struct PackageUpdateInventory: Identifiable, Sendable {
    public let id: String
    public let provider: PackageUpdateProvider
    public let items: [PackageUpdateItem]
    public let observedAt: Date
    public let executableIdentity: String
    public let issue: String?
}
public struct PackageUpdatePlan: Identifiable, Sendable {
    public let id: String
    public let provider: PackageUpdateProvider
    public let items: [PackageUpdateItem]
    public let expiresAt: Date
}
public struct PackageUpdateProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentName: String
}
public struct PackageUpdateResult: Sendable {
    public let item: PackageUpdateItem
    public let state: String
    public let issue: String?
}

// This command set cannot express a shell, all-package upgrade or project edit.
public enum PackageUpdateCommand: Equatable, Sendable {
    case installed(PackageUpdateProvider), outdated(PackageUpdateProvider)
    case upgrade(PackageUpdateProvider, kind: String, token: String)
    public var provider: PackageUpdateProvider {
        switch self { case .installed(let p), .outdated(let p), .upgrade(let p, _, _): p }
    }
    public var mutating: Bool { if case .upgrade = self { true } else { false } }
    public var arguments: [String] {
        switch self {
        case .installed(.homebrew): ["info", "--json=v2", "--installed"]
        case .outdated(.homebrew): ["outdated", "--json=v2"]
        case .installed(.mise): ["ls", "--global", "--installed", "--json"]
        case .outdated(.mise): ["outdated", "--global", "--json"]
        case .upgrade(.homebrew, let kind, let token): ["upgrade", kind == "cask" ? "--cask" : "--formula", token]
        case .upgrade(.mise, _, let token): ["upgrade", "--global", "--no-prune", token]
        }
    }
    public var valid: Bool {
        guard case .upgrade(let provider, let kind, let token) = self else { return true }
        return Self.validToken(token, provider: provider) && (provider == .homebrew ? ["formula", "dependency", "cask"].contains(kind) : kind == "tool")
    }
    public static func validToken(_ value: String, provider: PackageUpdateProvider) -> Bool {
        let pattern = provider == .homebrew ? "\\A[a-z0-9][a-z0-9+_.@/-]{0,199}\\z" : "\\A[A-Za-z0-9][A-Za-z0-9+_.@:/-]{0,199}\\z"
        return !value.contains("..") && !value.contains("//") && !value.contains("://") && value.range(of: pattern, options: .regularExpression) != nil
    }
}
public struct PackageUpdateOutput: Sendable {
    public let data: Data
    public let executableIdentity: String
    public init(data: Data, executableIdentity: String) { self.data=data; self.executableIdentity=executableIdentity }
}
public protocol PackageUpdateRunning: Sendable {
    var miseGlobalConfigurationPaths: Set<String> { get }
    func run(_ command: PackageUpdateCommand, timeoutSeconds: Double, expectedExecutableIdentity: String?) throws -> PackageUpdateOutput
}

/// Owns short-lived observations and single-use selections independently of cleanup.
public actor PackageUpdateService {
    private let runner: any PackageUpdateRunning
    private let now: @Sendable () -> Date
    private var inventories=[String:PackageUpdateInventory]()
    private var plans=[String:(PackageUpdatePlan, String)]()
    public init(runner: any PackageUpdateRunning, now: @escaping @Sendable () -> Date = { Date() }) { self.runner=runner; self.now=now }

    public func inventory(_ provider: PackageUpdateProvider) throws -> PackageUpdateInventory {
        try Task.checkCancellation()
        let installed=try runner.run(.installed(provider), timeoutSeconds: 60, expectedExecutableIdentity: nil)
        let outdated: PackageUpdateOutput
        var issue: String?
        do { outdated=try runner.run(.outdated(provider), timeoutSeconds: 90, expectedExecutableIdentity: installed.executableIdentity) }
        catch {
            try Task.checkCancellation()
            if (error as? ShouError)?.code == "tool_changed" { throw error }
            issue="package_update_check_failed"
            let empty=provider == .homebrew ? "{\"formulae\":[],\"casks\":[]}" : "{}"
            outdated = .init(data: Data(empty.utf8), executableIdentity: installed.executableIdentity)
        }
        try Task.checkCancellation()
        guard installed.executableIdentity == outdated.executableIdentity else { throw Self.error("tool_changed") }
        let items=try Self.parse(provider, installed: installed.data, outdated: outdated.data, globalPaths: runner.miseGlobalConfigurationPaths)
        let value=PackageUpdateInventory(id: UUID().uuidString, provider: provider, items: items, observedAt: now(), executableIdentity: installed.executableIdentity, issue: issue)
        inventories=inventories.filter { $0.value.provider != provider && now().timeIntervalSince($0.value.observedAt) < 600 }
        inventories[value.id]=value
        return value
    }

    public func prepare(_ observation: PackageUpdateInventory, selectedIDs: Set<String>) throws -> PackageUpdatePlan {
        guard let stored=inventories[observation.id], stored.issue == nil, stored.provider == observation.provider, stored.items == observation.items,
              stored.executableIdentity == observation.executableIdentity, now().timeIntervalSince(stored.observedAt) >= 0,
              now().timeIntervalSince(stored.observedAt) < 600, !selectedIDs.isEmpty, selectedIDs.count <= 256 else { throw Self.error("plan_stale") }
        let selected=stored.items.filter { selectedIDs.contains($0.id) }
        guard selected.count == selectedIDs.count, selected.allSatisfy(\.canUpgrade) else { throw Self.error("package_update_unavailable") }
        let plan=PackageUpdatePlan(id: UUID().uuidString, provider: stored.provider, items: selected, expiresAt: now().addingTimeInterval(120))
        plans=plans.filter { $0.value.0.expiresAt > now() }
        plans[plan.id]=(plan, stored.executableIdentity)
        return plan
    }

    public func execute(_ plan: PackageUpdatePlan, progress: @Sendable (PackageUpdateProgress) -> Void = { _ in }) throws -> [PackageUpdateResult] {
        guard let (stored, identity)=plans.removeValue(forKey: plan.id), stored.provider == plan.provider,
              stored.items == plan.items, stored.expiresAt == plan.expiresAt, plan.expiresAt > now() else { throw Self.error("confirmation_required") }
        // Validate the entire frozen batch before the first mutation.
        let current=try inventory(plan.provider)
        guard current.executableIdentity == identity, plan.items.allSatisfy({ current.items.contains($0) }) else { throw Self.error("plan_stale") }
        var results=[PackageUpdateResult]()
        for (index,item) in plan.items.enumerated() {
            if Task.isCancelled {
                results += plan.items.dropFirst(index).map { .init(item: $0, state: "skipped", issue: "cancelled") }
                break
            }
            progress(.init(completed: index, total: plan.items.count, currentName: item.name))
            var dispatched=false
            do {
                let fresh=try inventory(plan.provider)
                guard fresh.executableIdentity == identity else { throw Self.error("plan_stale") }
                // An earlier selected package may have installed this exact target
                // as a dependency. Verify it without dispatching another upgrade.
                if let target=item.availableVersion, let actual=fresh.items.first(where: { $0.id == item.id }),
                   actual.installedVersions.contains(target) {
                    results.append(.init(item: item, state: "succeeded", issue: nil))
                    progress(.init(completed: index+1, total: plan.items.count, currentName: item.name))
                    continue
                }
                guard fresh.items.contains(item) else { throw Self.error("plan_stale") }
                try Task.checkCancellation()
                guard now() < plan.expiresAt else { throw Self.error("plan_stale") }
                dispatched=true
                _ = try runner.run(.upgrade(plan.provider, kind: item.kind, token: item.token), timeoutSeconds: 300, expectedExecutableIdentity: identity)
                let after=try inventory(plan.provider)
                guard after.executableIdentity == identity, let actual=after.items.first(where: { $0.id == item.id }),
                      let target=item.availableVersion, actual.installedVersions.contains(target) else { throw Self.error("package_update_unverified") }
                results.append(.init(item: item, state: "succeeded", issue: nil))
            } catch {
                let code=(error as? ShouError)?.code ?? (Task.isCancelled ? "cancelled" : "package_update_unavailable")
                results.append(.init(item: item, state: dispatched ? "unknown" : "failed", issue: code))
                // A dependency or partial install may invalidate all later observations.
                results += plan.items.dropFirst(index+1).map { .init(item: $0, state: "skipped", issue: "package_update_recheck_required") }
                break
            }
            progress(.init(completed: index+1, total: plan.items.count, currentName: item.name))
        }
        return results
    }

    private static func error(_ code: String) -> ShouError { ShouError(code, "Package information or update authority could not be verified. Check again.") }
    private static func object(_ data: Data) throws -> [String:Any] {
        guard data.count <= 4 * 1024 * 1024, let value=try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw error("unsupported_schema") }
        return value
    }
    private static func text(_ value: Any?) -> String? {
        guard let value=value as? String, !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return value
    }
    private static func parse(_ provider: PackageUpdateProvider, installed: Data, outdated: Data, globalPaths: Set<String>) throws -> [PackageUpdateItem] {
        let local=try object(installed), remote=try object(outdated)
        var items=[PackageUpdateItem]()
        if provider == .homebrew {
            guard let formulae=local["formulae"] as? [[String:Any]], let casks=local["casks"] as? [[String:Any]],
                  let oldFormulae=remote["formulae"] as? [[String:Any]], let oldCasks=remote["casks"] as? [[String:Any]],
                  formulae.count+casks.count <= 10_000 else { throw error("unsupported_schema") }
            for (rows,oldRows,cask) in [(formulae,oldFormulae,false),(casks,oldCasks,true)] {
                var outdatedByName=[String:String]()
                for row in oldRows {
                    guard let name=text(row["name"]), PackageUpdateCommand.validToken(name, provider: provider),
                          let version=text(row["current_version"]), outdatedByName[name] == nil else { throw error("unsupported_schema") }
                    outdatedByName[name]=version
                }
                for row in rows {
                    guard let name=text(row[cask ? "token" : "name"]),
                          let token=text(row[cask ? "full_token" : "full_name"]) ?? Optional(name),
                          PackageUpdateCommand.validToken(token, provider: provider) else { throw error("unsupported_schema") }
                    let receipts=cask ? [] : (row["installed"] as? [[String:Any]] ?? [])
                    let versions: [String]
                    if cask {
                        if let values=row["installed"] as? [String] { versions=values.compactMap { text($0) } }
                        else if let version=text(row["installed"]) { versions=[version] }
                        else { versions=[] }
                    } else { versions=receipts.compactMap { text($0["version"]) } }
                    guard !versions.isEmpty else { throw error("unsupported_schema") }
                    let pinned=(row["pinned"] as? Bool ?? false)
                    let kind=cask ? "cask" : receipts.contains(where: { $0["installed_on_request"] as? Bool == true }) ? "formula" : "dependency"
                    let displayName=cask ? (row["name"] as? [String])?.first.flatMap { text($0) } ?? name : name
                    var item=PackageUpdateItem(provider: provider, token: token, name: displayName, kind: kind, installedVersions: versions.sorted(), availableVersion: outdatedByName[token], summary: text(row["desc"]), isPinned: pinned, requestedVersion: nil, configurationPath: nil)
                    if cask, let artifacts=row["artifacts"] as? [[String:Any]] {
                        item.iconApplicationPaths=artifacts.prefix(64).compactMap { artifact in
                            guard artifact["app"] != nil, let path=text(artifact["target"]), path.hasPrefix("/"), path.hasSuffix(".app"),
                                  path.utf8.count <= 4096, !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
                            return path
                        }
                    }
                    items.append(item)
                }
            }
        } else {
            guard local.count <= 10_000 else { throw error("unsupported_schema") }
            for (token,value) in local {
                guard PackageUpdateCommand.validToken(token, provider: provider), let rows=value as? [[String:Any]] else { throw error("unsupported_schema") }
                let active=rows.filter { $0["active"] as? Bool == true && $0["installed"] as? Bool != false }
                let visible=active.isEmpty ? rows.filter { $0["installed"] as? Bool != false } : active
                let versions=visible.compactMap { text($0["version"]) }.sorted()
                guard let row=visible.first, !versions.isEmpty else { continue }
                let old=remote[token] as? [String:Any]
                let source=(old?["source"] as? [String:Any]) ?? (row["source"] as? [String:Any])
                let path=text(source?["path"])
                let request=text(old?["requested"]) ?? text(row["requested_version"])
                // Keep inactive/multi-version tools visible, without granting them
                // global mutation authority or changing configured ranges.
                let pinned=active.count != 1 || request != "latest" || path.map { !globalPaths.contains($0) } != false
                let available=(active.count == 1 && text(old?["current"]) == versions.first) ? text(old?["latest"]) : nil
                items.append(.init(provider: provider, token: token, name: text(old?["name"]) ?? token, kind: "tool", installedVersions: versions, availableVersion: available, summary: nil, isPinned: pinned, requestedVersion: request, configurationPath: path))
            }
        }
        guard Set(items.map(\.id)).count == items.count else { throw error("unsupported_schema") }
        return items.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
    }
}
