import Foundation

/// Closed capabilities. Imported rules never supply executables or arguments.
public enum CleanupToolCommand: Sendable, Equatable {
    case dockerContext, dockerPreview, dockerPrune
    case brewPreview, brewPrune, condaPreview, condaPrune
    case rustList, rustOverrides, rustDefault, rustRemove(String)
    public var tool: String {
        switch self {
        case .dockerContext, .dockerPreview, .dockerPrune: "docker"
        case .brewPreview, .brewPrune: "brew"
        case .condaPreview, .condaPrune: "conda"
        default: "rustup"
        }
    }
    public var arguments: [String] {
        switch self {
        case .dockerContext: ["context","inspect","default","--format","{{json .Endpoints.docker.Host}}"]
        case .dockerPreview: ["--context","default","system","df","--format","{{json .}}"]
        case .dockerPrune: ["--context","default","builder","prune","--all","--force"]
        case .brewPreview: ["cleanup","--prune=30","--dry-run"]
        case .brewPrune: ["cleanup","--prune=30"]
        case .condaPreview: ["clean","--all","--dry-run","--json"]
        case .condaPrune: ["clean","--all","--yes","--json"]
        case .rustList: ["toolchain","list","--verbose"]
        case .rustOverrides: ["override","list"]
        case .rustDefault: ["show","active-toolchain"]
        case .rustRemove(let name): ["toolchain","uninstall",name]
        }
    }
    public var mutating: Bool {
        switch self { case .dockerPrune,.brewPrune,.condaPrune,.rustRemove: true; default: false }
    }
}
public struct CleanupToolOutput: Sendable {
    public let text: String
    public let executableIdentity: String
    public init(text: String, executableIdentity: String) { self.text=text; self.executableIdentity=executableIdentity }
}
public enum CleanupToolPlatform: String, Sendable { case macOS, windows, unsupported }
public protocol CleanupToolRunning: Sendable {
    var platform: CleanupToolPlatform { get }
    func run(_ command: CleanupToolCommand, timeoutSeconds: Double, expectedExecutableIdentity: String?) throws -> CleanupToolOutput
}
public extension CleanupToolRunning {
    var platform: CleanupToolPlatform { .macOS }
    func run(_ command: CleanupToolCommand, timeoutSeconds: Double) throws -> CleanupToolOutput {
        try run(command, timeoutSeconds: timeoutSeconds, expectedExecutableIdentity: nil)
    }
}
public struct ToolCleanupTarget: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let tool: String
    public let title: String
    public let estimatedBytes: Int64?
    public let fingerprint: String
    public let impact: String
    public let toolchain: String?
    public let executableIdentity: String?
}
public struct ToolCleanupIssue: Codable, Sendable { public let tool: String; public let code: String }
public struct ToolCleanupScan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let targets: [ToolCleanupTarget]
    public let issues: [ToolCleanupIssue]
}
public struct ToolCleanupPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let target: ToolCleanupTarget
    public let expiresAt: Date
    public var state: String
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.digest=""; copy.state="ready"; return try Digest.of(copy) }
}
public struct ToolCleanupReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let planId: String
    public let createdAt: Date
    public let target: ToolCleanupTarget
    public var state: String
    public var remainingBytesEstimate: Int64?
    public var error: String?
}

public actor ToolCleanupService {
    private let runner: any CleanupToolRunning
    private let store: any RecordStore
    private let now: @Sendable () -> Date
    public init(runner: any CleanupToolRunning, store: any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner=runner; self.store=store; self.now=now
    }
    public func scan() throws -> ToolCleanupScan {
        var targets=[ToolCleanupTarget](), issues=[ToolCleanupIssue]()
        let tools=runner.platform == .windows ? ["docker","conda","rustup"] : runner.platform == .macOS ? ["docker","brew","conda","rustup"] : []
        for tool in tools {
            if Task.isCancelled { throw ShouError("cancelled", "Tool scan cancelled.") }
            do { targets += try preview(tool) }
            catch {
                if Task.isCancelled { throw ShouError("cancelled", "Tool scan cancelled.") }
                issues.append(.init(tool: tool, code: (error as? ShouError)?.code ?? "tool_unavailable"))
            }
        }
        let scan=ToolCleanupScan(id: Codec.id("toolscan"), createdAt: now(), targets: targets, issues: issues)
        try store.write("tool-scans", id: scan.id, data: Codec.encode(scan))
        return scan
    }
    public func createPlan(scanId: String, targetId: String) throws -> ToolCleanupPlan {
        guard let data=try store.read("tool-scans", id: scanId) else { throw ShouError("invalid_argument", "Unknown tool scan.") }
        let scan=try Codec.decode(ToolCleanupScan.self, from: data)
        guard scan.id == scanId, now().timeIntervalSince(scan.createdAt) < 600,
              let target=scan.targets.first(where: { $0.id == targetId }) else { throw ShouError("plan_stale", "Scan this tool again before cleaning.") }
        var plan=ToolCleanupPlan(id: Codec.id("toolplan"), target: target, expiresAt: now().addingTimeInterval(120), state: "ready", digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("tool-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    public func plan(_ id: String) throws -> ToolCleanupPlan {
        guard let data=try store.read("tool-plans", id: id) else { throw ShouError("invalid_argument", "Unknown tool plan.") }
        let plan=try Codec.decode(ToolCleanupPlan.self, from: data)
        guard plan.id == id, try plan.calculatedDigest() == plan.digest else { throw ShouError("store_corrupt", "Tool plan is invalid.") }
        return plan
    }
    public func execute(planId: String, confirmedDigest: String) throws -> ToolCleanupReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try plan(planId)
        guard plan.state == "ready", plan.expiresAt > now(), plan.digest == confirmedDigest else { throw ShouError("confirmation_required", "Tool cleanup confirmation expired or was already used.") }
        guard try preview(plan.target.tool).contains(plan.target) else { throw ShouError("plan_stale", "Tool data or executable changed. Scan again.") }
        guard plan.expiresAt > now(), let executableIdentity=plan.target.executableIdentity else { throw ShouError("confirmation_required", "Tool cleanup review expired or needs a fresh executable identity.") }
        let command: CleanupToolCommand
        switch plan.target.tool {
        case "docker": command = .dockerPrune
        case "brew": command = .brewPrune
        case "conda": command = .condaPrune
        case "rustup":
            guard let name=plan.target.toolchain, Self.validToolchain(name) else { throw ShouError("store_corrupt", "Invalid toolchain selection.") }
            command = .rustRemove(name)
        default: throw ShouError("capability_unavailable", "Unknown cleanup tool.")
        }
        if Task.isCancelled { throw ShouError("cancelled", "Tool cleanup cancelled before execution.") }
        var receipt=ToolCleanupReceipt(id: Codec.id("toolrun"), planId: plan.id, createdAt: now(), target: plan.target, state: "executing")
        try store.write("tool-history", id: receipt.id, data: Codec.encode(receipt))
        plan.state="executing"; try store.write("tool-plans", id: plan.id, data: Codec.encode(plan))
        do {
            _ = try runner.run(command, timeoutSeconds: 300, expectedExecutableIdentity: executableIdentity)
            let remaining=try preview(plan.target.tool).first { $0.id == plan.target.id }
            receipt.remainingBytesEstimate=remaining?.estimatedBytes
            // A successful owner command plus a fresh preview is the available
            // verification signal. Estimates are never reported as physical freed bytes.
            receipt.state=remaining != nil ? "partial" : "completed"
        } catch {
            receipt.state="unknown"; receipt.error=(error as? ShouError)?.code ?? (Task.isCancelled ? "cancelled" : "tool_failed")
        }
        try store.write("tool-history", id: receipt.id, data: Codec.encode(receipt))
        plan.state=receipt.state; try store.write("tool-plans", id: plan.id, data: Codec.encode(plan))
        return receipt
    }
    public func history() throws -> [ToolCleanupReceipt] {
        try store.ids("tool-history").map { id in
            guard let data=try store.read("tool-history", id: id) else { throw ShouError("store_corrupt", "Missing tool receipt.") }
            return try Codec.decode(ToolCleanupReceipt.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private func output(_ command: CleanupToolCommand) throws -> CleanupToolOutput {
        // Homebrew's Ruby startup and catalog reads can exceed a short generic
        // process deadline. These previews run separately from filesystem scans.
        let timeout: Double = command.tool == "brew" ? 30 : command.tool == "conda" ? 15 : command.tool == "docker" ? 10 : 5
        return try runner.run(command, timeoutSeconds: timeout)
    }
    private func target(id: String, tool: String, title: String, bytes: Int64?, outputs: [CleanupToolOutput], impact: String, toolchain: String? = nil) throws -> ToolCleanupTarget {
        guard let identity=outputs.first?.executableIdentity, !identity.isEmpty, outputs.allSatisfy({ $0.executableIdentity == identity }) else { throw ShouError("tool_changed", "The cleanup tool changed during preview.") }
        let evidence=outputs.map { $0.executableIdentity + "\0" + $0.text }.joined(separator: "\0")
        return .init(id: id, tool: tool, title: title, estimatedBytes: bytes, fingerprint: Digest.sha256(Data(evidence.utf8)), impact: impact, toolchain: toolchain, executableIdentity: identity)
    }
    private func preview(_ tool: String) throws -> [ToolCleanupTarget] {
        switch tool {
        case "docker":
            let context=try output(.dockerContext)
            let endpoint=try JSONDecoder().decode(String.self, from: Data(context.text.utf8))
            let local=runner.platform == .windows ? endpoint == "npipe:////./pipe/docker_engine" : endpoint.hasPrefix("unix:///")
            guard local, !endpoint.contains("\n"), !endpoint.contains("\0") else { throw ShouError("remote_context", "Only the supported local Docker default context is supported.") }
            let value=try output(.dockerPreview)
            var bytes: Int64?
            for line in value.text.split(separator: "\n") {
                guard let row=try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw ShouError("unsupported_schema", "Docker returned an unsupported disk report.") }
                if row["Type"] as? String == "Build Cache", let size=row["Reclaimable"] as? String { bytes=Self.bytes(String(size.split(separator: " ").first ?? "")) }
            }
            guard let bytes else { throw ShouError("unsupported_schema", "Docker build-cache estimate is unavailable.") }
            return bytes > 0 ? [try target(id: "docker.build-cache", tool: tool, title: "Docker build cache", bytes: bytes, outputs: [context,value], impact: "Unused build cache is removed permanently. Images, containers and volumes are retained; later builds may download or rebuild layers.")] : []
        case "brew":
            let value=try output(.brewPreview)
            guard value.text.contains("Would remove:") || value.text.contains("Would free") else { return [] }
            return [try target(id: "brew.cleanup", tool: tool, title: "Homebrew old versions and downloads", bytes: nil, outputs: [value], impact: "Homebrew removes its obsolete versions and downloads with a 30-day prune policy. Reinstalling older versions may require a download.")]
        case "conda":
            let value=try output(.condaPreview)
            guard let json=try JSONSerialization.jsonObject(with: Data(value.text.utf8)) as? [String: Any], json["success"] as? Bool != false else { throw ShouError("unsupported_schema", "Conda returned an unsupported cleanup preview.") }
            let sizes=["tarballs","packages","index_cache","logfiles"].compactMap { (json[$0] as? [String: Any])?["total_size"] as? NSNumber }.map(\.int64Value)
            guard sizes.allSatisfy({ $0 >= 0 }) else { throw ShouError("unsupported_schema", "Conda returned an invalid size.") }
            var bytes: Int64=0
            for size in sizes {
                let sum=bytes.addingReportingOverflow(size)
                guard !sum.overflow else { throw ShouError("unsupported_schema", "Conda size exceeds supported limits.") }
                bytes=sum.partialValue
            }
            return bytes > 0 ? [try target(id: "conda.cache", tool: tool, title: "Conda package caches", bytes: bytes, outputs: [value], impact: "Conda removes unused packages, archives, index and logs. Environments using symlinks into package caches can be affected. Review your environments before cleaning.")] : []
        case "rustup":
            let list=try output(.rustList), overrides=try output(.rustOverrides), active=try output(.rustDefault)
            let protected=Set(overrides.text.split(whereSeparator: \.isWhitespace).map(String.init) + active.text.split(whereSeparator: \.isWhitespace).prefix(1).map(String.init))
            return try list.text.split(separator: "\n").compactMap { line in
                guard let name=line.split(whereSeparator: \.isWhitespace).first.map(String.init), Self.validToolchain(name),
                      !line.contains("(default"), !line.contains("default)"), !line.contains("active"), !protected.contains(name) else { return nil }
                return try target(id: "rustup." + name, tool: tool, title: name, bytes: nil, outputs: [list,overrides,active], impact: "This toolchain is not the current/default toolchain or a rustup directory override. Projects that pin it in rust-toolchain files may need it again; removal requires a later download.", toolchain: name)
            }
        default: throw ShouError("capability_unavailable", "Unsupported cleanup tool.")
        }
    }
    private static func validToolchain(_ name: String) -> Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.+-]{1,160}$", options: .regularExpression) != nil }
    private static func bytes(_ value: String) -> Int64? {
        let pattern="^([0-9]+(?:\\.[0-9]+)?)(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)$"
        guard let regex=try? NSRegularExpression(pattern: pattern), let match=regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let n=Range(match.range(at: 1), in: value), let u=Range(match.range(at: 2), in: value), let count=Double(value[n]) else { return nil }
        let unit=String(value[u]), power=["B":0,"kB":1,"KB":1,"MB":2,"GB":3,"TB":4,"KiB":1,"MiB":2,"GiB":3,"TiB":4][unit]!
        let amount=count * pow(unit.contains("i") ? 1024 : 1000, Double(power))
        return amount.isFinite && amount >= 0 && amount < Double(Int64.max) ? Int64(amount) : nil
    }
}
