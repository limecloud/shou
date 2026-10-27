import Foundation

public struct DeveloperToolPackage: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let kind: String
    public let token: String
    public init(provider: String, kind: String, token: String) { self.provider=provider; self.kind=kind; self.token=token }
    public var id: String { provider + ":" + kind + ":" + token }
    public var valid: Bool {
        switch provider {
        case "homebrew": ["formula", "cask"].contains(kind) && PackageUpdateCommand.validToken(token, provider: .homebrew) && !token.contains("/")
        case "winget": kind == "package" && token.range(of: "\\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\\z", options: .regularExpression) != nil && token.contains(".") && !token.contains("..")
        default: false
        }
    }
}
public struct DeveloperToolDefinition: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let homepage: String
    public let packages: [DeveloperToolPackage]
    public let commands: [String]
    public let npmPackages: [String]
    public var isAI: Bool { ["ai", "ai-coding"].contains(category) }
}
public struct DeveloperToolCategory: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
}
public struct DeveloperToolCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let categories: [DeveloperToolCategory]
    public let tools: [DeveloperToolDefinition]
    public static func bundled() throws -> Self {
        guard let url=CoreResources.bundle.url(forResource: "developer-tools", withExtension: "json") else { throw ShouError("resource_unavailable", "Developer tool catalog is missing.") }
        return try decode(Data(contentsOf: url))
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw invalid() }
        let value: Self
        do {
            guard let root=try JSONSerialization.jsonObject(with: data) as? [String:Any], Set(root.keys) == ["schemaVersion","categories","tools"],
                  let groups=root["categories"] as? [[String:Any]], groups.allSatisfy({ Set($0.keys) == ["id","title"] }),
                  let tools=root["tools"] as? [[String:Any]], tools.allSatisfy({ tool in
                      Set(tool.keys) == ["id","name","category","homepage","packages","commands","npmPackages"] &&
                      (tool["packages"] as? [[String:Any]])?.allSatisfy { Set($0.keys) == ["provider","kind","token"] } == true
                  }) else { throw invalid() }
            value=try JSONDecoder().decode(Self.self, from: data)
        } catch { throw invalid() }
        let categories=Set(value.categories.map(\.id))
        guard value.schemaVersion == 1, (1...32).contains(value.categories.count), categories.count == value.categories.count,
              (1...256).contains(value.tools.count), Set(value.tools.map(\.id)).count == value.tools.count,
              value.categories.allSatisfy({ validID($0.id) && validText($0.title) }),
              value.tools.allSatisfy({ tool in
                  validID(tool.id) && validText(tool.name) && categories.contains(tool.category) && tool.packages.count <= 16 &&
                  Set(tool.packages).count == tool.packages.count && tool.packages.allSatisfy(\.valid) &&
                  tool.commands.count <= 8 && tool.commands.allSatisfy({ $0.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\\z", options: .regularExpression) != nil }) &&
                  tool.npmPackages.count <= 8 && tool.npmPackages.allSatisfy({ $0.range(of: "\\A@?[a-z0-9][a-z0-9._/-]{0,199}\\z", options: .regularExpression) != nil && !$0.contains("..") }) &&
                  URLComponents(string: tool.homepage).map { $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil } == true
              }) else { throw invalid() }
        return value
    }
    private static func validID(_ text: String) -> Bool { text.range(of: "\\A[a-z][a-z0-9-]{0,63}\\z", options: .regularExpression) != nil }
    private static func validText(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 256 && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private static func invalid() -> ShouError { ShouError("unsupported_schema", "The developer tool catalog is invalid.") }
}

public struct DeveloperToolInstallation: Codable, Identifiable, Equatable, Sendable {
    public let toolID: String
    public let source: String
    public let version: String?
    public let path: String
    public let evidence: String
    public let status: String
    public let launchPaths: [String]
    public var id: String { Digest.sha256(Data((toolID + "\0" + source + "\0" + path + "\0" + (version ?? "")).utf8)) }
    public init(toolID: String, source: String, version: String?, path: String, evidence: String, status: String, launchPaths: [String] = []) {
        self.toolID=toolID; self.source=source; self.version=version; self.path=path; self.evidence=evidence; self.status=status
        self.launchPaths=launchPaths
    }
}
public struct DeveloperToolInventory: Sendable {
    public let installations: [DeveloperToolInstallation]
    public let observedAt: Date
    public let issues: [String]
    public init(installations: [DeveloperToolInstallation], observedAt: Date = Date(), issues: [String]) {
        self.installations=installations; self.observedAt=observedAt; self.issues=issues
    }
}
public protocol DeveloperToolDiscovering: Sendable {
    func scan(_ catalog: DeveloperToolCatalog) throws -> DeveloperToolInventory
}

public enum DeveloperToolAction: String, Codable, Sendable { case install, uninstall }
public struct DeveloperToolInspection: Codable, Equatable, Sendable {
    public let package: DeveloperToolPackage
    public let installedVersions: [String]
    public let availableVersion: String?
    public let dependencies: [String]
    public let sourceIdentity: String
    public let packageIdentity: String
    public let scope: String
    public let issue: String?
    public init(package: DeveloperToolPackage, installedVersions: [String], availableVersion: String?, dependencies: [String], sourceIdentity: String, packageIdentity: String, scope: String, issue: String?) {
        self.package=package; self.installedVersions=installedVersions; self.availableVersion=availableVersion; self.dependencies=dependencies
        self.sourceIdentity=sourceIdentity; self.packageIdentity=packageIdentity; self.scope=scope; self.issue=issue
    }
    public var installed: Bool { !installedVersions.isEmpty }
    public func allows(_ action: DeveloperToolAction) -> Bool {
        action == .install ? issue == nil && !installed && availableVersion != nil : installed && (issue == nil || issue == "package_source_unavailable")
    }
}
public struct DeveloperToolPlan: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let toolID: String
    public let action: DeveloperToolAction
    public let inspection: DeveloperToolInspection
    public let expiresAt: Date
}
public struct DeveloperToolResult: Codable, Sendable {
    public let plan: DeveloperToolPlan
    public let state: String
    public let issue: String?
    public let observedVersions: [String]
}
public protocol DeveloperToolOperating: Sendable {
    func inspect(_ package: DeveloperToolPackage) throws -> DeveloperToolInspection
    func perform(_ action: DeveloperToolAction, expected: DeveloperToolInspection, expiresAt: Date) throws
}

/// Package installation is independent of cleanup. Only a catalog-owned, rechecked,
/// single-use plan can cross this boundary; personal-data deletion is not expressible.
public actor DeveloperToolService {
    private let catalog: DeveloperToolCatalog
    private let platform: any DeveloperToolOperating
    private let makeStore: @Sendable () throws -> any RecordStore
    private let now: @Sendable () -> Date
    private var current: DeveloperToolPlan?
    public init(catalog: DeveloperToolCatalog, platform: any DeveloperToolOperating, makeStore: @escaping @Sendable () throws -> any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog=catalog; self.platform=platform; self.makeStore=makeStore; self.now=now
    }
    public func inspect(toolID: String, package: DeveloperToolPackage) throws -> DeveloperToolInspection {
        try require(toolID, package)
        try Task.checkCancellation()
        let result=try platform.inspect(package)
        guard result.package == package, !result.sourceIdentity.isEmpty, !result.packageIdentity.isEmpty,
              result.installedVersions.count <= 64, result.dependencies.count <= 1024 else { throw failure("package_identity_unverified") }
        return result
    }
    public func prepare(toolID: String, action: DeveloperToolAction, expected: DeveloperToolInspection) throws -> DeveloperToolPlan {
        current=nil
        let fresh=try inspect(toolID: toolID, package: expected.package)
        guard fresh == expected, fresh.allows(action) else { throw failure("developer_tool_changed") }
        let plan=DeveloperToolPlan(id: UUID().uuidString, toolID: toolID, action: action, inspection: fresh, expiresAt: now().addingTimeInterval(120))
        current=plan
        return plan
    }
    public func execute(_ plan: DeveloperToolPlan, confirmedID: String) throws -> DeveloperToolResult {
        let saved=current; current=nil
        guard saved == plan, confirmedID == plan.id, now() < plan.expiresAt else { throw failure("confirmation_required") }
        let store=try makeStore(), lease=try store.lock()
        defer { lease.release() }
        let fresh=try inspect(toolID: plan.toolID, package: plan.inspection.package)
        guard fresh == plan.inspection, fresh.allows(plan.action), now() < plan.expiresAt else { throw failure("developer_tool_changed") }
        try store.write("developer-tool-intents", id: plan.id, data: Codec.encode(plan))
        var dispatched=false
        let result: DeveloperToolResult
        do {
            try Task.checkCancellation()
            dispatched=true
            try platform.perform(plan.action, expected: fresh, expiresAt: plan.expiresAt)
            // Verification survives a stop request: the manager may already have changed files.
            let after=try platform.inspect(fresh.package)
            let verified=after.issue == nil && after.sourceIdentity == fresh.sourceIdentity &&
                (plan.action == .install ? after.installedVersions.contains(fresh.availableVersion ?? "") : !after.installed)
            result = .init(plan: plan, state: verified ? "succeeded" : "unknown", issue: verified ? nil : "developer_tool_unverified", observedVersions: after.installedVersions)
        } catch {
            result = .init(plan: plan, state: dispatched ? "unknown" : "not_started", issue: (error as? ShouError)?.code ?? "developer_tool_failed", observedVersions: [])
        }
        try store.write("developer-tool-results", id: plan.id, data: Codec.encode(result))
        return result
    }
    private func require(_ toolID: String, _ package: DeveloperToolPackage) throws {
        guard package.valid, catalog.tools.first(where: { $0.id == toolID })?.packages.contains(package) == true else { throw failure("developer_tool_source_unavailable") }
    }
    private func failure(_ code: String) -> ShouError { ShouError(code, "Inspect the exact developer tool source and review the operation again.") }
}
