import Foundation
import ShouCore
import ShouPlatform
import ShouAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A request-scoped desktop channel. It does not replace terminal confirmation
/// or expose an unattended mutation switch on the public CLI.
enum DesktopBridge {
    private struct Request: Decodable {
        let bridgeVersion: Int
        let requestId: String
        let operation: String
        let input: JSONValue
    }
    private struct Control: Decodable {
        let bridgeVersion: Int
        let requestId: String
        let kind: String
        let challenge: String?
        let digest: String?
    }
    static func run() async {
        do {
            let reader=LineReader()
            guard let line=try reader.next() else { return }
            let request=try Codec.decode(Request.self, from: line)
            guard request.bridgeVersion == 1,
                  request.requestId.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
                  request.input.object != nil else { throw ShouError("invalid_argument", "Unsupported desktop request.") }
            let session=Session(id: request.requestId)
            let task=Task {
                do {
                    let data=try await perform(request, session: session)
                    var envelope=try ResultEnvelope(data: data)
                    if request.operation.hasPrefix("ai."), request.operation != "ai.cancel", ["failed", "cancelled", "limited"].contains(data["status"]?.string ?? "") {
                        envelope.ok=false; envelope.status="partial"
                    }
                    try session.send(kind: "result", value: .from(envelope))
                } catch {
                    let failure=error as? ShouError ?? ShouError(error is CancellationError ? "cancelled" : "io_error", error.localizedDescription)
                    try? session.send(kind: "result", value: .from(ResultEnvelope(error: failure)))
                }
            }
            Task.detached {
                do {
                    while let line=try reader.next() {
                        let control=try Codec.decode(Control.self, from: line)
                        guard control.bridgeVersion == 1, control.requestId == request.requestId else { break }
                        if control.kind == "confirm" { session.accept(challenge: control.challenge, digest: control.digest) }
                        else if control.kind == "cancel" { task.cancel(); session.cancel() }
                        else { break }
                    }
                } catch { }
                // EOF means the parent no longer owns a live review. Mutations
                // cooperate with cancellation and persist their item journal.
                task.cancel(); session.cancel()
            }
            await task.value
        } catch {
            let failure=error as? ShouError ?? ShouError("invalid_argument", "Invalid desktop request.")
            try? ShouCLI.output(ResultEnvelope(error: failure), json: true)
        }
    }
    private static func perform(_ request: Request, session: Session) async throws -> JSONValue {
        let fs=NativeFileSystem()
        let input=request.input
        func string(_ key: String) throws -> String {
            guard let value=input[key]?.string, !value.isEmpty, value.utf8.count <= 262144 else { throw ShouError("invalid_argument", "Missing or invalid desktop input.", details: ["field": key]) }
            return value
        }
        func strings(_ key: String, maximum: Int = 500) throws -> [String] {
            guard let array=input[key]?.array, (1...maximum).contains(array.count), array.allSatisfy({ $0.string != nil }) else { throw ShouError("invalid_argument", "Select explicit items.", details: ["field": key]) }
            return array.compactMap(\.string)
        }
        func scanBudget(defaults: ScanBudget = ScanBudget()) throws -> ScanBudget {
            guard let value=input["budget"] else { return defaults }
            guard let fields=value.object, Set(fields.keys).isSubset(of: ["max_entries", "max_seconds", "max_depth"]) else { throw ShouError("invalid_argument", "Invalid scan budget fields.") }
            func integer(_ key: String, default fallback: Int, range: ClosedRange<Int64>) throws -> Int {
                guard let value=fields[key] else { return fallback }
                guard case .integer(let count)=value, range.contains(count) else { throw ShouError("invalid_argument", "Invalid scan budget.") }
                return Int(count)
            }
            return try ScanBudget(maxEntries: integer("max_entries", default: defaults.maxEntries, range: 1...1_000_000),
                                  maxSeconds: Double(integer("max_seconds", default: Int(defaults.maxSeconds), range: 1...600)),
                                  maxDepth: integer("max_depth", default: defaults.maxDepth, range: 1...128))
        }
        if request.operation == "capabilities" {
            return .object(["application_version": .string(ShouCLI.version), "api_version": .string("1.0"), "platform": .string(fs.platform),
                "features": .object(["scan": .bool(true), "rules": .bool(true), "space_analysis": .bool(true), "ai_investigation": .bool(AIInvestigationService.isAvailable), "trash": .bool(fs.supportsTrash), "restore": .bool(fs.supportsTrash), "permanent": .bool(true), "applications": .bool(false), "startup": .bool(false), "privacy": .bool(false)]),
                "confirmation": .string("request_scoped_challenge"), "bridge_version": .integer(1)])
        }
        let store=try LocalRecordStore()
        let engine=ShouEngine(store: store, filesystem: fs, applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence())
        if request.operation.hasPrefix("ai.") {
            let connections=AIConnectionStore(store: store)
            let credentials=SystemAICredentials()
            let service=AIInvestigationService(engine: engine, store: store, credentials: credentials)
            func connection() throws -> AIConnection {
                guard let value=try connections.connections().first(where: { $0.id == input["connection_id"]?.string }) else { throw ShouError("not_found", "AI connection not found.") }
                return value
            }
            @Sendable func update(_ state: AIInvestigation) async { try? session.send(kind: "progress", value: .from(state)) }
            switch request.operation {
            case "ai.providers": return AICLI.decisionProviders()
            case "ai.list": return try .from(await service.list())
            case "ai.cancel":
                try await service.cancel(string("investigation_id")); return try .from(await service.read(string("investigation_id")))
            case "ai.connections.save":
                guard let profile=input["profile"], try Codec.encode(profile).count <= 16_384 else { throw ShouError("invalid_ai_connection", "Provide a bounded connection profile.") }
                let value=try AIConnectionStore.profile(profile)
                for (field, decision) in [("model_key", false), ("decision_key", true)] {
                    if let key=input[field]?.string, !key.isEmpty {
                        guard (decision ? value.decision?.authentication : value.authentication) == .keychain else { throw ShouError("invalid_ai_connection", "Keys must use the system credential store.") }
                        try credentials.save(key, for: value, decision: decision)
                    }
                }
                try connections.save(value); return try .from(value)
            case "ai.connections": return try .from(connections.connections())
            case "ai.test":
                try await AIConnectionTest.run(connection: connection(), credentials: credentials)
                return .object(["status": .string("verified"), "tool_round_trip": .bool(true)])
            case "ai.decision.test":
                return try .from(await StructuredDecisionService().test(connection: connection(), credentials: credentials))
            case "ai.investigate":
                guard let goal=AIInvestigationGoal(rawValue: input["goal"]?.string ?? "investigate") else { throw ShouError("invalid_argument", "Choose investigate, space or rules as the AI goal.") }
                return try .from(await service.start(scanId: string("scan_id"), scope: input["path"]?.string ?? ".", connection: connection(),
                    request: input["request"]?.string ?? "", locale: input["locale"]?.string ?? "en", goal: goal, progress: update))
            case "ai.show": return try .from(await service.read(string("investigation_id")))
            case "ai.resume":
                guard let fields=input["answers"]?.object, fields.values.allSatisfy({ $0.string != nil }) else { throw ShouError("invalid_ai_answer", "Provide answers for the current questions.") }
                return try .from(await service.resume(string("investigation_id"), answers: fields.compactMapValues(\.string), progress: update))
            case "ai.advice.import": return try .from(await service.importAdvice(investigationId: string("investigation_id"), adviceId: string("advice_id")))
            default: throw ShouError("invalid_argument", "Unknown AI desktop operation.")
            }
        }
        @Sendable func scanProgress(_ progress: ScanProgress) {
            var fields: [String: JSONValue]=["stage": .string(progress.stage), "entry_count": .integer(Int64(progress.entryCount)), "path": .string(progress.currentPath)]
            if progress.fractionCompleted != nil, let completed=progress.completedUnitCount, let total=progress.totalUnitCount {
                fields["completed_unit_count"] = .integer(Int64(completed))
                fields["total_unit_count"] = .integer(Int64(total))
            }
            try? session.send(kind: "progress", value: .object(fields))
        }
        @Sendable func executionProgress(_ progress: ExecutionProgress) {
            var fields: [String: JSONValue]=["stage": .string(progress.stage), "processed_count": .integer(Int64(progress.processedCount)), "item_count": .integer(Int64(progress.itemCount)), "path": .string(progress.path)]
            if let completed=progress.currentItemProcessedCount, let total=progress.currentItemCount {
                fields["current_item_processed_count"] = .integer(Int64(completed))
                fields["current_item_count"] = .integer(Int64(total))
            }
            try? session.send(kind: "progress", value: .object(fields))
        }
        switch request.operation {
        case "history.cleanup-preview", "history.clear":
            let ids=input["execution_ids"] == nil ? nil : try strings("execution_ids")
            let include: Bool
            if case .bool(let value)? = input["include_recoverable"] { include=value }
            else if input["include_recoverable"] == nil { include=false }
            else { throw ShouError("invalid_argument", "include_recoverable must be a boolean.") }
            let preview=try await engine.historyCleanupPreview(executionIds: ids, includeRecoverable: include)
            if request.operation == "history.clear", !preview.executionIds.isEmpty {
                let review: JSONValue = .object(["action": .string("history.clear"), "items": .array(preview.executionIds.map { .object(["path": .string($0)]) })])
                try await session.confirm(digest: try Digest.of(preview), review: review, operation: "history.clear")
                return try .from(await engine.clearHistory(executionIds: preview.executionIds, includeRecoverable: include))
            }
            return try .from(preview)
        case "configuration":
            return .object(["configuration": try .from(await engine.configuration()), "templates": try .from(BuiltinCatalog.templates().filter { $0.supportedPlatforms.contains(fs.platform) }), "locations": try .from(await engine.knownLocations())])
        case "workspace.add": return try .from(await engine.addWorkspace(path: string("path"), rootRef: string("root_ref")))
        case "system.scan":
            let result=try await engine.scanKnownLocations(includeProjects: true, progress: { _, update in scanProgress(update) })
            return .object(["status": .string(result.status), "scans": try .from(result.snapshots.map { try scanPage($0, offset: 0) }), "issues": try .from(result.issues)])
        case "system.clean":
            guard let selections=input["selections"]?.array, (1...200).contains(selections.count) else { throw ShouError("invalid_argument", "Select current scan results.") }
            let action=input["action"]?.string ?? "permanent"
            var plans=[CleanupPlan]()
            for selection in selections {
                guard let fields=selection.object, let scan=fields["scan_id"]?.string, let ids=fields["candidate_ids"]?.array,
                      !ids.isEmpty, ids.allSatisfy({ $0.string != nil }) else { throw ShouError("invalid_argument", "Select explicit candidates from each scan.") }
                plans.append(try await engine.createPlan(scanId: scan, candidateIds: ids.compactMap(\.string), action: action))
            }
            let paths=plans.flatMap { plan in plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath } }.map { fs.platform == "windows" ? $0.lowercased() : $0 }.sorted()
            for pair in zip(paths, paths.dropFirst()) where pair.1 == pair.0 || pair.1.hasPrefix(pair.0 + "/") { throw ShouError("invalid_argument", "Selected cleanup paths overlap.") }
            let digest=try Digest.of(plans)
            let review: JSONValue = .object(["action": .string(action), "items": .array(try plans.flatMap { try planReview($0).object?["items"]?.array ?? [] })])
            try await session.confirm(digest: digest, review: review, operation: action)
            let total=plans.reduce(0) { $0 + $1.items.count }
            var rows=[JSONValue](), processed=0, state="completed", executionIds=[String]()
            for plan in plans {
                let offset=processed
                do {
                    try Task.checkCancellation()
                    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "windows-desktop", progress: { executionProgress($0.inBatch(processedBefore: offset, itemCount: total)) })
                    executionIds.append(receipt.id)
                    rows += try receiptSummary(receipt, followUps: []).object?["items"]?.array ?? []
                    if receipt.state != "completed" { state=receipt.state == "cancelled" ? "cancelled" : "partial" }
                } catch {
                    let cancelled=Task.isCancelled
                    state=cancelled ? "cancelled" : "partial"
                    if let receipt=try? await engine.historySummaries(limit: 500).receipts.first(where: { $0.planId == plan.id }) {
                        executionIds.append(receipt.id)
                        rows += try receiptSummary(receipt, followUps: []).object?["items"]?.array ?? []
                    } else {
                        let verifiedNoMutation=["plan_stale","application_running","application_activity_unavailable","confirmation_required","capability_unavailable"].contains((error as? ShouError)?.code ?? "")
                        rows += plan.items.map { .object(["path": .string(plan.workspace.path + "/" + $0.candidate.relativePath), "state": .string(cancelled ? "skipped" : verifiedNoMutation ? "failed" : "unknown"), "error": .string(error.localizedDescription)]) }
                    }
                }
                processed += plan.items.count
            }
            return .object(["state": .string(state), "items": .array(rows), "execution_ids": try .from(executionIds)])
        case "scan":
            let ruleIds=input["rule_ids"] == nil ? [] : try strings("rule_ids")
            let snapshot=try await engine.scan(workspaceId: string("workspace_id"), ruleIds: ruleIds, scope: .cleanup, budget: scanBudget(), progress: scanProgress)
            return try scanPage(snapshot, offset: 0)
        case "scan.target":
            return try scanPage(await engine.scanCleanupTarget(scanId: string("scan_id"), candidateId: string("candidate_id"),
                budget: scanBudget(defaults: ScanBudget(maxEntries: 1_000_000, maxSeconds: 120)), progress: scanProgress), offset: 0)
        case "scan.results":
            let offset=Int(input["offset"]?.numeric ?? 0)
            guard offset >= 0, offset <= 1_000_000 else { throw ShouError("invalid_argument", "Invalid results offset.") }
            return try scanPage(await engine.scanSnapshot(string("scan_id")), offset: offset)
        case "cleanup.review":
            return try await DesktopCleanupReview.page(input: input, engine: engine)
        case "plan":
            return try planReview(await engine.createPlan(scanId: string("scan_id"), candidateIds: strings("candidate_ids"), action: input["action"]?.string ?? "trash"))
        case "plan.execute":
            let plan=try await engine.plan(string("plan_id"))
            guard plan.action == "permanent" || (plan.action == "trash" && fs.supportsTrash) else { throw ShouError("capability_unavailable", "The selected cleanup mode is unavailable.") }
            try await session.confirm(digest: plan.digest, review: planReview(plan), operation: plan.action)
            try Task.checkCancellation()
            let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "windows-desktop", progress: executionProgress)
            return try receiptSummary(receipt, followUps: [])
        case "history", "history.page":
            let followUps=try await engine.followUps()
            let page=try await engine.historySummaries(offset: Int(input["offset"]?.numeric ?? 0), limit: 50)
            let summaries=try page.receipts.map { try receiptSummary($0, followUps: followUps) }
            if request.operation == "history" { return .array(summaries) }
            return .object(["receipts": .array(summaries), "total_count": .integer(Int64(page.totalCount)), "next_offset": page.nextOffset.map { .integer(Int64($0)) } ?? .null])
        case "records.preview": return try .from(await engine.recordRetentionPreview())
        case "records.collect": return try .from(await engine.collectRecords())
        case "history.restore", "history.purge":
            let action=request.operation == "history.restore" ? "restore" : "purge"
            let id=try string("execution_id"), itemIds=try strings("item_ids")
            let receipt=try await engine.history(id)
            let digest=try await engine.followUpDigest(executionId: id, itemIds: itemIds, action: action)
            let review: JSONValue = .object(["execution_id": .string(id), "action": .string(action), "items": .array(receipt.items.filter { itemIds.contains($0.id) }.map { item in
                .object(["id": .string(item.id), "path": .string(action == "restore" ? item.originalPath : item.trashPath ?? item.originalPath), "original_path": .string(item.originalPath), "bytes": .integer(item.allocatedBytesEstimate)])
            })])
            try await session.confirm(digest: digest, review: review, operation: action)
            try Task.checkCancellation()
            return try .from(await engine.followUp(executionId: id, itemIds: itemIds, action: action, confirmedDigest: digest, progress: executionProgress))
        case "rules.import":
            let json=try string("json")
            guard json.utf8.count <= 262144 else { throw ShouError("resource_limit", "Rule exceeds the import limit.") }
            return try .from(await engine.importRule(Data(json.utf8)))
        case "rules.set":
            guard case .bool(let enabled)=input["enabled"] else { throw ShouError("invalid_argument", "A rule enablement decision is required.") }
            return try .from(await engine.setRule(ruleId: string("rule_id"), workspaceId: string("workspace_id"), enabled: enabled, version: input["version"]?.string))
        case "rules.location-set":
            guard case .bool(let enabled)=input["enabled"] else { throw ShouError("invalid_argument", "A rule enablement decision is required.") }
            let ruleId=try string("rule_id"), locationId=try string("location_id")
            guard try BuiltinCatalog.templates().contains(where: { $0.id == ruleId && $0.location == locationId && $0.supportedPlatforms.contains(fs.platform) }) else {
                throw ShouError("invalid_argument", "Select a bundled rule for this cache location.")
            }
            let workspace=try await engine.workspaceForKnownLocation(locationId)
            return try .from(await engine.setRule(ruleId: ruleId, workspaceId: workspace.id, enabled: enabled))
        case "rules.preview":
            let config=try await engine.configuration(), id=try string("rule_id"), version=try string("version"), workspace=try string("workspace_id")
            guard let record=config.rules.first(where: { $0.rule.id == id && $0.rule.version == version }),
                  config.workspaces.contains(where: { $0.id == workspace && $0.rootRef == record.rule.scope.rootRef }) else {
                throw ShouError("invalid_argument", "Select a personal rule in its registered workspace.")
            }
            let scan=try await engine.scan(workspaceId: workspace, previewRule: record.rule, scope: .cleanup, progress: scanProgress)
            return .object(["scan_id": .string(scan.id), "status": .string(scan.status), "configuration_revision": .string(config.revision),
                "rule": try .from(record.rule), "rows": try .from(PersonalRulePreview.rows(snapshot: scan, rule: record.rule)),
                "benefits": try .from(await engine.rulePreviewBenefits(scanId: scan.id)), "issues": try .from(scan.issues)])
        case "exclusions.set":
            guard case .bool(let remove)=input["remove"] else { throw ShouError("invalid_argument", "An exclusion action is required.") }
            return try .from(await engine.setGlobalExclusion(pattern: string("pattern"), remove: remove))
        case "storage.scan":
            let scan=try await engine.scanStorage(path: string("path"), progress: scanProgress)
            let notes=scan.tree.issues.map { StorageCoverageNote(issue: $0, root: scan.rootPath) }
            return .object(["scan_id": .string(scan.id), "root_path": .string(scan.rootPath), "status": .string(scan.status), "entry_count": .integer(Int64(scan.entryCount)), "issues": try .from(scan.tree.issues), "coverage_notes": .array(notes.map { .object(["code": .string($0.code), "path": .string($0.path), "system_managed": .bool($0.systemManaged)]) }), "directory": try directoryValue(await engine.storageDirectory(scanId: scan.id))])
        case "storage.show":
            let scan=try await engine.storageScan(string("scan_id"))
            return .object(["scan_id": .string(scan.id), "root_path": .string(scan.rootPath), "status": .string(scan.status)])
        case "storage.map":
            let result=try await engine.storagePresentation(scanId: string("scan_id"), path: input["path"]?.string ?? ".")
            let tiles=SpaceMap.nested(result.items.map(\.node), scope: result.scope.node, width: 1000, height: 600, aggregates: result.aggregates)
            let suffixes=Set(result.extensions.items.map(\.suffix) + result.items.filter { $0.node.kind == "file" }.map { StorageExtensionStat.suffix($0.node.name) } + result.aggregates.map(\.suffix))
            let colors=Dictionary(uniqueKeysWithValues: suffixes.map { ($0, JSONValue.string(StorageMapPalette.hex(forExtension: $0))) })
            return .object(["presentation": try .from(result), "colors": .object(colors), "tiles": .array(tiles.map { .object(["path": .string($0.tile.id), "inspect_path": .string($0.aggregate?.parentPath ?? $0.id), "aggregate": $0.aggregate.map { .object(["parent_path": .string($0.parentPath), "suffix": .string($0.suffix), "allocated_bytes": .integer($0.allocatedBytes), "file_count": .integer(Int64($0.fileCount))]) } ?? .null, "depth": .integer(Int64($0.depth)), "x": .number($0.tile.x), "y": .number($0.tile.y), "width": .number($0.tile.width), "height": .number($0.tile.height), "remainder": .bool($0.remainder)]) })])
        case "storage.large-files":
            if let value=input["type"], value.string == nil { throw ShouError("invalid_argument", "Select a supported filename type.") }
            if let value=input["cursor"], value != .null, value.string == nil { throw ShouError("invalid_argument", "Invalid large-file cursor.") }
            let minimum: Int64
            if let value=input["minimum_bytes"] {
                guard case .integer(let count)=value, count >= 0 else { throw ShouError("invalid_argument", "Use a nonnegative integer minimum size.") }
                minimum=count
            } else { minimum=50 * 1024 * 1024 }
            guard let type=StorageFileType(rawValue: input["type"]?.string ?? "all") else { throw ShouError("invalid_argument", "Select a supported filename type.") }
            let scan=try await engine.storageScan(string("scan_id"))
            let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: minimum, type: type, limit: 500, cursor: input["cursor"]?.string)
            var entries=[JSONValue]()
            for item in page.items {
                entries.append(.object(["entry": try .from(item.entry), "node": try .from(item.node), "removal_block_reason": try .from(await engine.storageRemovalReason(scan: scan, path: item.entry.path))]))
            }
            return .object(["scan_id": .string(scan.id), "root_path": .string(scan.rootPath), "status": .string(scan.status), "entries": .array(entries),
                "total_count": .integer(Int64(page.totalCount)), "total_allocated_bytes": .integer(page.totalAllocatedBytes), "next_cursor": try .from(page.nextCursor), "issues": try .from(scan.tree.issues)])
        case "storage.remove":
            let plan=try await engine.createStorageRemovalPlan(scanId: string("scan_id"), paths: strings("paths", maximum: 5000), action: input["action"]?.string ?? "permanent")
            let review: JSONValue = .object(["action": .string(plan.action), "items": .array(plan.items.map { .object(["path": .string(StorageRemovalPolicy.absolute(root: plan.rootPath, relative: $0.path)), "bytes": .integer($0.allocatedBytesEstimate)]) })])
            try await session.confirm(digest: plan.digest, review: review, operation: plan.action)
            let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "windows-desktop", progress: executionProgress)
            return try receiptSummary(receipt, followUps: [])

        case "storage.page":
            let value=input["offset"]?.numeric ?? 0
            guard value.isFinite, value.rounded() == value, (0...1_000_000_000).contains(value) else { throw ShouError("invalid_argument", "Invalid directory offset.") }
            return try .from(await engine.storageDirectoryPage(scanId: string("scan_id"), path: input["path"]?.string ?? ".", offset: Int(value), limit: 200))
        case "storage.context":
            let context=try await engine.storageAnalysisContext(scanId: string("scan_id"), path: input["path"]?.string ?? ".", focusedPath: input["focused_path"]?.string, selectedPaths: input["selected_paths"]?.array?.compactMap(\.string) ?? [], removedPaths: input["removed_paths"]?.array?.compactMap(\.string) ?? [],
                cliPath: CommandLine.arguments[0])
            return .object(["context": try .from(context), "text": .string(try context.text(locale: input["locale"]?.string ?? "zh-CN"))])
        case "storage.directory": return try directoryValue(await engine.storageDirectory(scanId: string("scan_id"), path: input["path"]?.string ?? "."))
        default: throw ShouError("capability_unavailable", "This desktop operation is not available.")
        }
    }
    private static func directoryValue(_ directory: StorageDirectory) throws -> JSONValue {
        .object(["path": .string(directory.item.entry.path), "complete": .bool(directory.item.node.isComplete == true), "children": try .from(directory.children.map(\.node)), "total_count": .integer(Int64(directory.children.count))])
    }
    private static func scanPage(_ scan: ScanSnapshot, offset: Int) throws -> JSONValue {
        let candidates=scan.candidates.filter { !$0.ruleIds.isEmpty }
        let page=Array(candidates.dropFirst(offset).prefix(100))
        return .object(["scan_id": .string(scan.id), "workspace_id": .string(scan.workspace.id), "root_path": .string(scan.workspace.path), "root_ref": .string(scan.workspace.rootRef), "status": .string(scan.status), "issues": try .from(scan.issues), "entry_count": .integer(Int64(scan.entries.count)), "candidates": try .from(page), "total_count": .integer(Int64(candidates.count)), "next_offset": offset+page.count<candidates.count ? .integer(Int64(offset+page.count)) : .null])
    }
    private static func planReview(_ plan: CleanupPlan) throws -> JSONValue {
        .object(["id": .string(plan.id), "digest": .string(plan.digest), "action": .string(plan.action), "root_path": .string(plan.workspace.path), "expires_at": try .from(plan.expiresAt),
            "items": .array(plan.items.map { .object(["id": .string($0.id), "path": .string(plan.workspace.path + "/" + $0.candidate.relativePath), "bytes": .integer($0.candidate.allocatedBytesEstimate), "risk": .string($0.candidate.risk), "rebuild_notes": .array($0.candidate.rebuildNotes.map(JSONValue.string)), "limitations": .array($0.candidate.limitations.map(JSONValue.string))]) })])
    }
    private static func receiptSummary(_ receipt: ExecutionReceipt, followUps: [FollowUpReceipt]) throws -> JSONValue {
        .object(["id": .string(receipt.id), "created_at": try .from(receipt.createdAt), "state": .string(receipt.state), "root_path": .string(receipt.workspace.path),
            "items": .array(receipt.items.map { item in
                let followUp=followUps.filter { $0.executionId == receipt.id && $0.itemId == item.id }.max { $0.createdAt < $1.createdAt }
                let followed=followUps.contains { $0.executionId == receipt.id && $0.itemId == item.id && ($0.state == "completed" || $0.state == "pending") }
                let state: String
                if let followUp, followUp.state == "pending" { state="needs_verification" }
                else if let followUp, followUp.state == "completed" { state=followUp.action == "restore" ? "restored" : "purged" }
                else { state=item.state }
                let purgeAllowed = !["application_uninstall", "application_batch_uninstall"].contains(receipt.operation ?? "")
                let resultingPath=followUp?.state == "completed" && followUp?.action == "purge" ? nil : followUp?.resultingPath ?? item.trashPath
                return .object(["id": .string(item.id), "path": .string(item.originalPath), "state": .string(state), "bytes": .integer(item.allocatedBytesEstimate), "error": (followUp?.error ?? item.error).map(JSONValue.string) ?? .null, "resulting_path": resultingPath.map(JSONValue.string) ?? .null, "can_restore": .bool(item.state == "trashed" && !followed), "can_purge": .bool(item.state == "trashed" && !followed && purgeAllowed)])
            })])
    }
    private final class LineReader: @unchecked Sendable {
        private var buffer=Data()
        func next() throws -> Data? {
            while true {
                if let newline=buffer.firstIndex(of: 10) {
                    guard buffer.distance(from: buffer.startIndex, to: newline) <= 1_048_576 else { throw ShouError("resource_limit", "Desktop input exceeds 1 MiB.") }
                    let line=Data(buffer[..<newline]); buffer.removeSubrange(...newline); return line
                }
                guard buffer.count <= 1_048_576 else { throw ShouError("resource_limit", "Desktop input exceeds 1 MiB.") }
                // Foundation's read(upToCount:) can wait to fill a pipe read.
                // One native read returns the currently available protocol bytes.
                var bytes=[UInt8](repeating: 0, count: 4096)
                #if os(Windows)
                let count=try WindowsConsole.readInput(&bytes)
                #else
                let count=bytes.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw ShouError("io_error", "Desktop input could not be read.") }
                #endif
                guard count > 0 else {
                    if buffer.isEmpty { return nil }; throw ShouError("invalid_argument", "Desktop input must end with a newline.")
                }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
    }
    private final class Session: @unchecked Sendable {
        private let id: String
        private let mutex=NSLock(), output=NSLock()
        private var pending: (nonce: String, digest: String, expiry: Date, continuation: CheckedContinuation<Void, any Error>)?
        private var cancelled=false
        init(id: String) { self.id=id }
        func send(kind: String, value: JSONValue) throws {
            let data=try Codec.encode(JSONValue.object(["bridge_version": .integer(1), "request_id": .string(id), "kind": .string(kind), "value": value]))
            guard data.count <= 8_388_608 else { throw ShouError("resource_limit", "Desktop result exceeds 8 MiB; narrow the query.") }
            try output.withLock { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
        }
        func confirm(digest: String, review: JSONValue, operation: String) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                mutex.lock()
                if cancelled { mutex.unlock(); continuation.resume(throwing: ShouError("cancelled", "The desktop review was cancelled.")); return }
                let nonce=UUID().uuidString, expiry=Date().addingTimeInterval(120)
                pending=(nonce,digest,expiry,continuation); mutex.unlock()
                do { try send(kind: "confirmation", value: .object(["challenge": .string(nonce), "digest": .string(digest), "operation": .string(operation), "expires_at": try .from(expiry), "review": review])) }
                catch { cancel(); return }
                Task { try? await Task.sleep(for: .seconds(120)); self.expire(nonce) }
            }
        }
        func accept(challenge: String?, digest: String?) {
            let value=mutex.withLock { let value=pending; pending=nil; return value }
            guard let value else { return }
            if value.nonce == challenge && value.digest == digest && Date() < value.expiry && !mutex.withLock({ cancelled }) { value.continuation.resume() }
            else { value.continuation.resume(throwing: ShouError("confirmation_required", "Desktop confirmation does not match the current review.")) }
        }
        func expire(_ nonce: String) {
            let value=mutex.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard pending?.nonce == nonce else { return nil }; let value=pending?.continuation; pending=nil; return value
            }
            value?.resume(throwing: ShouError("confirmation_required", "The desktop review expired."))
        }
        func cancel() {
            let value=mutex.withLock { cancelled=true; let value=pending?.continuation; pending=nil; return value }
            value?.resume(throwing: ShouError("cancelled", "The desktop request was cancelled."))
        }
    }
}
