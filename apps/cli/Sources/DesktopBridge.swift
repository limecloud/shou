import Foundation
import ShouCore
import ShouPlatform
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
                    try session.send(kind: "result", value: .from(ResultEnvelope(data: data)))
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
        func strings(_ key: String) throws -> [String] {
            guard let array=input[key]?.array, (1...500).contains(array.count), array.allSatisfy({ $0.string != nil }) else { throw ShouError("invalid_argument", "Select explicit items.", details: ["field": key]) }
            return array.compactMap(\.string)
        }
        if request.operation == "capabilities" {
            return .object(["application_version": .string(ShouCLI.version), "api_version": .string("1.0"), "platform": .string(fs.platform),
                "features": .object(["scan": .bool(true), "rules": .bool(true), "space_analysis": .bool(true), "trash": .bool(fs.supportsTrash), "restore": .bool(fs.supportsTrash), "permanent": .bool(true), "applications": .bool(false), "startup": .bool(false), "privacy": .bool(false)]),
                "confirmation": .string("request_scoped_challenge"), "bridge_version": .integer(1)])
        }
        let engine=ShouEngine(store: try LocalRecordStore(), filesystem: fs, applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence())
        @Sendable func scanProgress(_ progress: ScanProgress) {
            try? session.send(kind: "progress", value: .object(["stage": .string(progress.stage), "entry_count": .integer(Int64(progress.entryCount)), "path": .string(progress.currentPath)]))
        }
        @Sendable func executionProgress(_ progress: ExecutionProgress) {
            try? session.send(kind: "progress", value: .object(["stage": .string(progress.stage), "processed_count": .integer(Int64(progress.processedCount)), "item_count": .integer(Int64(progress.itemCount)), "path": .string(progress.path)]))
        }
        switch request.operation {
        case "configuration":
            return .object(["configuration": try .from(await engine.configuration()), "templates": try .from(BuiltinCatalog.templates().filter { $0.supportedPlatforms.contains(fs.platform) })])
        case "workspace.add": return try .from(await engine.addWorkspace(path: string("path"), rootRef: string("root_ref")))
        case "scan":
            let snapshot=try await engine.scan(workspaceId: string("workspace_id"), scope: .full, progress: scanProgress)
            return try scanPage(snapshot, offset: 0)
        case "scan.results":
            let offset=Int(input["offset"]?.numeric ?? 0)
            guard offset >= 0, offset <= 1_000_000 else { throw ShouError("invalid_argument", "Invalid results offset.") }
            return try scanPage(await engine.scanSnapshot(string("scan_id")), offset: offset)
        case "plan":
            return try planReview(await engine.createPlan(scanId: string("scan_id"), candidateIds: strings("candidate_ids"), action: input["action"]?.string ?? "trash"))
        case "plan.execute":
            let plan=try await engine.plan(string("plan_id"))
            guard plan.action == "permanent" || (plan.action == "trash" && fs.supportsTrash) else { throw ShouError("capability_unavailable", "The selected cleanup mode is unavailable.") }
            try await session.confirm(digest: plan.digest, review: planReview(plan), operation: plan.action)
            try Task.checkCancellation()
            let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "windows-desktop", progress: executionProgress)
            return try receiptSummary(receipt, followUps: [])
        case "history":
            let followUps=try await engine.followUps()
            return try .from(await engine.history().map { try receiptSummary($0, followUps: followUps) })
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
        case "exclusions.set":
            guard case .bool(let remove)=input["remove"] else { throw ShouError("invalid_argument", "An exclusion action is required.") }
            return try .from(await engine.setGlobalExclusion(pattern: string("pattern"), remove: remove))
        case "storage.scan":
            let scan=try await engine.scanStorage(path: string("path"), budget: ScanBudget(), progress: scanProgress)
            return .object(["scan_id": .string(scan.id), "root_path": .string(scan.rootPath), "status": .string(scan.status), "entry_count": .integer(Int64(scan.entryCount)), "issues": try .from(scan.tree.issues), "directory": try directoryValue(await engine.storageDirectory(scanId: scan.id))])
        case "storage.directory": return try directoryValue(await engine.storageDirectory(scanId: string("scan_id"), path: input["path"]?.string ?? "."))
        default: throw ShouError("capability_unavailable", "This desktop operation is not available.")
        }
    }
    private static func directoryValue(_ directory: StorageDirectory) throws -> JSONValue {
        .object(["path": .string(directory.item.entry.path), "children": try .from(directory.children.map(\.node)), "total_count": .integer(Int64(directory.children.count))])
    }
    private static func scanPage(_ scan: ScanSnapshot, offset: Int) throws -> JSONValue {
        let candidates=scan.candidates.filter { !$0.ruleIds.isEmpty }
        let page=Array(candidates.dropFirst(offset).prefix(100))
        return .object(["scan_id": .string(scan.id), "workspace_id": .string(scan.workspace.id), "status": .string(scan.status), "issues": try .from(scan.issues), "entry_count": .integer(Int64(scan.entries.count)), "candidates": try .from(page), "total_count": .integer(Int64(candidates.count)), "next_offset": offset+page.count<candidates.count ? .integer(Int64(offset+page.count)) : .null])
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
